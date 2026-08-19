# Integer-Only Quantized MLP -- Design Spec

**Status: FROZEN v1.0** (2026-08-19). Covers ABACUS-6 through ABACUS-11.
Changing any value here (scales, M0/shift, layer sizes) invalidates the
reference vectors in `model/ref_vectors.npz` / `tb/ref_vectors/*.hex` --
bump to v1.1 and regenerate them instead of editing in place.

## 1. Model

Fully-connected MLP, Fashion-MNIST (28x28 grayscale, 10 classes), trained
in fp32, frozen, then post-training quantized (no QAT in this path).

```
784 --fc1--> 512 --ReLU--> 512 --fc2--> 512 --ReLU--> 512 --fc3--> 10 (logits)
```

Weight shapes: fc1 (512,784), fc2 (512,512), fc3 (10,512). All biases int32.

## 2. Quantization scheme (ABACUS-6)

Symmetric, per-tensor, int8. No zero-point (zero float maps to zero code).

- **Weights**: `s_w = max(|W|) / 127`, `q_w = clamp(round(W / s_w), -127, 127)`.
- **Activations**: `s_x = act_bound / 127`, where `act_bound` is a per-layer
  input calibration bound measured over 1,000 fixed training images.
  Two candidate bounds were compared -- plain max\|x\| vs. 99.9th-percentile
  \|x\| -- and the one giving higher simulated int8 accuracy was kept.
  **Selected: p999** for all three layers.
- **Bias**: folded to int32 as `b_int32 = round(b_fp32 / (s_w * s_x_in))`,
  added directly to the int32 matmul accumulator (no separate float add).
- **Input quantization** (`golden_model.quantize_input`) clips to the full
  signed int8 range `[-128, 127]`; weights clip to `[-127, 127]` (symmetric,
  excludes -128 so `-max_code == +max_code`). This asymmetry is intentional
  and only affects weights.

## 3. Requantization -- M decomposition (ABACUS-7)

Between fc1->fc2 and fc2->fc3, the int32 accumulator must be rescaled by
`M = s_w[src] * s_x[src] / s_x[dst]` before the next layer's int8 matmul.
No float multiplier exists on-device, so `M` is decomposed offline
(gemmlowp/TFLite "quantized multiplier" scheme):

```
M = significand * 2**exponent          (via frexp, significand in [0.5, 1))
M0 = round(significand * 2**31)        # Q0.31 fixed-point mantissa, 0 < M0 < 2**31
shift = exponent                       # M ~= M0 * 2**(shift - 31)
```

On-device / in the golden model (`golden_model.requantize`):

```
total_shift = 31 - shift
rescaled    = (acc_int64 * M0 + 2**(total_shift-1)) >> total_shift   # total_shift > 0
q_out       = clamp(rescaled, relu ? 0 : -128, 127)                  # ReLU fused into clamp
```

The `acc * M0` product is widened to int64 (up to ~55 bits for a ~24-bit
accumulator times a 31-bit M0) -- mirrors a wide MAC register in hardware
(e.g. DSP48E2's 48-bit output), not a NumPy convenience.

**fc3 is never requantized.** Argmax over a single positive per-tensor
scale is scale-invariant, so raw int32 logits go straight to argmax.

| transition | M0 | shift | total right-shift |
|---|---:|---:|---:|
| fc1 -> fc2 | 1,495,187,284 | -9 | 40 |
| fc2 -> fc3 | 2,115,194,159 | -8 | 39 |

## 4. Per-layer scales

| layer | s_w | s_x (input) |
|---|---:|---:|
| fc1 | 1.158645e-02 | 1.592648e-02 |
| fc2 | 5.852339e-03 | 1.356983e-01 |
| fc3 | 8.686239e-03 | 2.064065e-01 |

## 5. Integer-only pipeline (ABACUS-8, `golden_model.forward_debug`)

```
x_float --quantize_input(s_x[fc1])--> q0 (int8, 784)
q0 --fc1 int8x int8 matmul + int32 bias--> acc1 (int32, 512)
acc1 --requantize(M0,shift; ReLU fused)--> q1 (int8, 512)
q1 --fc2 matmul + bias--> acc2 (int32, 512)
acc2 --requantize(M0,shift; ReLU fused)--> q2 (int8, 512)
q2 --fc3 matmul + bias--> acc3 (int32, 10)   # final logits, no requant
argmax(acc3) --> predicted class
```

Only one float operation exists in the entire path: dividing the raw
pixel by `s_x[fc1]` at the very first step. Everything after is
integer add / multiply / shift.

## 6. Reference artifacts

| file | produced by | contents |
|---|---|---|
| `model/quant_params_ptq.npz` | ABACUS-6 | int8 weights, int32 biases, `s_w`/`s_x` per layer |
| `model/requant_constants.npz` | ABACUS-7 | `M0`/`shift` for fc1->fc2, fc2->fc3 |
| `model/golden_model.py` | ABACUS-8 | pure-NumPy integer-only forward pass (reference impl) |
| `model/test_golden_model.py` | ABACUS-9 | unit tests, esp. `requantize()` rounding/saturation/branches |
| `model/ref_vectors.npz` | ABACUS-11 | 750 stratified samples (75/class, seed=0), every pipeline stage |
| `tb/ref_vectors/*.hex` | ABACUS-11 | same 750 samples, `$readmemh`-ready, sample-major, two's-complement |

## 7. Accuracy (full 10,000-image test set unless noted)

| path | accuracy |
|---|---:|
| fp32 baseline | 89.51% |
| PTQ int8, float dequant/requant (sim) | 89.43% |
| PTQ int8, integer-only M decomp (notebook sim, ABACUS-7) | 89.43% |
| Golden model, pure NumPy integer-only (ABACUS-8/10) | **89.43%** (bit-exact match to above) |
| ABACUS-11 reference subset (750 stratified images) | 87.60% |

The three independent integer-only computations (PyTorch notebook sim,
NumPy golden model, this doc's own re-derivation) agree bit-for-bit,
which is the primary evidence this spec is ready to freeze: there is
exactly one integer semantics in play, not three slightly different ones.

## 8. Out of scope / next

RTL implementation (`rtl/`, `tb/`, `synth/`, `scripts/` are currently
empty scaffolding) is not started. This spec is the contract the RTL
testbench checks against: given `tb/ref_vectors/q0.hex` as input, every
downstream `.hex` file is the required bit-exact output at that stage.
