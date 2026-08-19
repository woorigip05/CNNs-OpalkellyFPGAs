"""
Dump bit-exact reference vectors for the RTL testbench (ABACUS-11).

Selects a stratified sample of the Fashion-MNIST test set (fixed count
per class, deterministic seed) and runs it through the golden model,
capturing every intermediate stage -- not just the final prediction --
so the testbench can check each pipeline stage (quantized input,
per-layer accumulator, per-layer requantized activation, final logits)
independently.

Two outputs:
  model/ref_vectors.npz   -- everything, for Python-side tooling/tests.
  tb/ref_vectors/*.hex    -- one file per tensor, flattened row-major
                             (sample-major) with one two's-complement
                             hex value per line, for $readmemh.

Run from the model/ directory: python3 dump_reference_vectors.py
"""

import numpy as np

import golden_model as gm

PER_CLASS = 75  # 75 * 10 classes = 750 vectors
SEED = 0
NUM_CLASSES = 10

REF_NPZ_PATH = "ref_vectors.npz"
HEX_DIR = "../tb/ref_vectors"


def stratified_sample(y_all, per_class, seed):
    """`per_class` indices per label, shuffled within class, seed-fixed."""
    rng = np.random.default_rng(seed)
    chosen = []
    for label in range(NUM_CLASSES):
        idx = np.flatnonzero(y_all == label)
        rng.shuffle(idx)
        chosen.append(idx[:per_class])
    chosen = np.concatenate(chosen)
    rng.shuffle(chosen)  # interleave classes instead of grouping them
    return chosen


def to_hex_lines(arr, nibbles):
    """Flatten row-major (sample-major) to one two's-complement hex value
    per line, `nibbles` hex digits wide (2 for int8, 8 for int32)."""
    flat = arr.reshape(-1).astype(np.int64)
    mask = (1 << (nibbles * 4)) - 1
    return [format(int(v) & mask, f"0{nibbles}x") for v in flat]


def write_hex(path, arr, nibbles, header):
    lines = to_hex_lines(arr, nibbles)
    with open(path, "w") as f:
        f.write(f"// {header}\n")
        f.write(f"// shape={list(arr.shape)} dtype={arr.dtype} hex_width={nibbles}\n")
        f.write("\n".join(lines) + "\n")


def main():
    from torchvision import datasets, transforms

    MEAN, STD = 0.2860, 0.3530
    tfm = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((MEAN,), (STD,)),
        transforms.Lambda(lambda x: x.view(-1)),
    ])
    test_set = datasets.FashionMNIST("./data", train=False, download=False, transform=tfm)

    x_all = np.stack([np.asarray(img) for img, _ in test_set]).astype(np.float32)
    y_all = np.array([label for _, label in test_set])

    idx = stratified_sample(y_all, PER_CLASS, SEED)
    x = x_all[idx]
    y = y_all[idx].astype(np.int64)

    params = gm.load_params()
    stages = gm.forward_debug(x, params)
    preds = stages["acc3"].argmax(axis=1)
    acc = (preds == y).mean()

    n = len(idx)
    print(f"reference set: {n} vectors ({PER_CLASS}/class, seed={SEED}), "
          f"acc on this subset: {acc*100:.2f}%")

    np.savez(
        REF_NPZ_PATH,
        indices=idx,
        labels=y,
        preds=preds,
        pixels_float=x,
        q0=stages["q0"], acc1=stages["acc1"], q1=stages["q1"],
        acc2=stages["acc2"], q2=stages["q2"], acc3_logits=stages["acc3"],
        per_class=PER_CLASS, seed=SEED,
    )
    print(f"wrote {REF_NPZ_PATH}")

    import os
    os.makedirs(HEX_DIR, exist_ok=True)
    write_hex(f"{HEX_DIR}/q0.hex", stages["q0"], 2,
              f"fc1 input, int8, {n}x784, sample-major")
    write_hex(f"{HEX_DIR}/acc1.hex", stages["acc1"], 8,
              f"fc1 accumulator, int32, {n}x512, sample-major")
    write_hex(f"{HEX_DIR}/q1.hex", stages["q1"], 2,
              f"fc1 requantized+ReLU output, int8, {n}x512, sample-major")
    write_hex(f"{HEX_DIR}/acc2.hex", stages["acc2"], 8,
              f"fc2 accumulator, int32, {n}x512, sample-major")
    write_hex(f"{HEX_DIR}/q2.hex", stages["q2"], 2,
              f"fc2 requantized+ReLU output, int8, {n}x512, sample-major")
    write_hex(f"{HEX_DIR}/acc3_logits.hex", stages["acc3"], 8,
              f"fc3 logits (unrequantized), int32, {n}x10, sample-major")
    write_hex(f"{HEX_DIR}/labels.hex", y.reshape(-1, 1), 2,
              f"true labels, uint8, {n}x1")
    write_hex(f"{HEX_DIR}/preds.hex", preds.reshape(-1, 1), 2,
              f"golden model predictions, uint8, {n}x1")
    print(f"wrote {HEX_DIR}/*.hex")


if __name__ == "__main__":
    main()
