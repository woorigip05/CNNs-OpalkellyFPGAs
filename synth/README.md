# Remote synthesis flow (ABACUS-14)

## Quick reference

Everything below, condensed: what to run, in what order, once `.synthrc`
is filled in.

```bash
./scripts/remote_synth.sh --list-parts                     # find + cross-check your part
# edit .synthrc: SYNTH_PART=<exact string from above>
./scripts/remote_synth.sh --top adder --mode full           # real target today
./scripts/remote_synth.sh --top adder --mode full --detach  # fire and forget
./scripts/remote_synth.sh --attach                          # watch a running build
./scripts/remote_synth.sh --pull                            # fetch reports without rebuilding
make synth-pe                                                # once rtl/pe/pe_mac.sv exists
```

| Piece | Purpose |
|---|---|
| `synth/build.tcl` | The actual Vivado non-project synthesis. Not run by hand -- `remote_synth.sh` generates its `-tclargs`. |
| `synth/sources.f` | Compile-order filelist `build.tcl` reads (`filelist=`) instead of globbing `rtl/`. Add new modules here as they land; keep vendor (`okHost`/`okLibrary`) sources in a separate filelist so OOC block checks stay vendor-code-free. |
| `constr/abacus.xdc` | Board-level constraints. **Hard-required for `full` mode** -- `build.tcl` refuses to run without it. Currently just a placeholder clock; see the file's own header. |
| `synth/list_parts.tcl` | Lists every part Vivado knows, for cross-checking against board docs before setting `SYNTH_PART`. |
| `.synthrc` | Gitignored, machine-specific: `SYNTH_HOST`, `SYNTH_REMOTE_DIR`, `VIVADO_SETTINGS`, `SYNTH_PART`. |
| `scripts/remote_synth.sh` | sync tree -> launch in tmux over SSH -> stream log -> pull reports. |

`make synth` / `synth-pe` / `synth-array` target `abacus_top` / `pe_mac` /
`systolic_array` -- none of those exist in `rtl/` yet, so those targets
aren't runnable today. `adder` (the ABACUS-13 toolchain smoke test) is the
only real target right now; use `--top adder --mode full` or `--mode ooc`
directly until the others land.

## One-time setup

**1. Find your exact part string.** This is the one value you must not guess.
`xcku035` alone is not enough — package and speed grade change the timing
model, so the wrong string gives you Fmax numbers that look real and aren't.

```bash
./scripts/remote_synth.sh --list-parts
```

Cross-check the result against the Opal Kelly board documentation for your
module, then set `SYNTH_PART` in `.synthrc`. If the docs and the Vivado list
disagree, trust the docs and note the discrepancy in the lab notebook.

**2. Create `.synthrc` in the repo root and gitignore it:**

```bash
SYNTH_HOST=you@fpga-server.example.edu
SYNTH_REMOTE_DIR=~/abacus-build
VIVADO_SETTINGS=/path/to/Vivado/settings64.sh
SYNTH_PART=xcku035-fbva676-1-c
```

`SYNTH_PART` is picked up automatically on every run; `--part <string>` on
the CLI overrides it for a one-off without touching the file.
`SYNTH_REMOTE_DIR` should be on local scratch, not NFS home — Vivado does a
lot of small writes and NFS will roughly double your runtime (not a concern
if the remote box's home is a local disk, not NFS-mounted — check with
`findmnt $HOME` on that box).

**3. Set up key-based SSH** (`ssh-copy-id`) so the poll loop isn't prompting.
If the server is behind a bastion, put a `ProxyJump` entry in `~/.ssh/config`
rather than encoding it in the script.

**4. Confirm tmux exists on the server:** `ssh $SYNTH_HOST which tmux`. If it
doesn't, `screen` works with the same structure, or ask for it to be installed.

## Daily use

```bash
make synth                          # full design
make synth-pe                       # OOC synthesis of the PE alone
./scripts/remote_synth.sh --detach  # long run, come back later
./scripts/remote_synth.sh --attach  # watch a running build
./scripts/remote_synth.sh --pull    # fetch reports without rebuilding
```

A `--detach` build that's already finished cleans up its own idle tmux
session automatically on your next launch — you don't need to manually kill
it first.

## Make targets

```make
SYNTH := ./scripts/remote_synth.sh

.PHONY: synth synth-pe synth-array synth-attach synth-pull
synth:
	$(SYNTH) --top abacus_top --mode full
synth-pe:
	$(SYNTH) --top pe_mac --mode ooc --clk 4.0
synth-array:
	$(SYNTH) --top systolic_array --mode ooc --clk 4.0
synth-attach:
	$(SYNTH) --attach
synth-pull:
	$(SYNTH) --pull
```

## What lands in `build/<top>_<mode>/`

| file | what it's for |
|---|---|
| `utilization.rpt` | LUT/FF/DSP/BRAM totals |
| `utilization_hier.rpt` | per-module breakdown — find the module that blew up |
| `timing_summary.rpt` | WNS/TNS plus unconstrained-path warnings |
| `timing_worst.rpt` | worst path per timing group, pin-level detail |
| `methodology.rpt` | Vivado's design-rule checks — latch inference, missing reset synchronizers, etc. |
| `clocks.rpt` | clock network report — sanity-check that your constraint actually created the clock you expect |
| `dsp_audit.rpt` | DSP count + ref name + AREG/BREG/MREG/PREG per DSP |
| `summary.json` | machine-readable — feed to your report-regression CLI |
| `post_synth.dcp` | checkpoint, so implementation can resume without re-synth |
| `ooc_clock.xdc` | (OOC mode only) the synthetic clock constraint that was actually applied — a visible artifact, not just an inline Tcl command you'd have to go find in the log |
| `vivado.log` | the full log |

## Reading `dsp_audit.rpt` (matters for ABACUS-21)

A PE that maps to one DSP48E2 (or DSP48E1 on 7-series parts) is necessary
but not sufficient. You want `AREG=1 BREG=1 MREG=1 PREG=1` — meaning the
input, multiply, and output pipeline registers are all *inside* the DSP. If
you see `MREG=0`, Vivado inferred the multiplier but left the pipeline
registers in fabric outside the block, which is the silent failure mode
that caps Fmax well below what the DSP can do. The fix is usually the
coding pattern, not a synthesis option: registered operands, registered
product, registered accumulate, and no reset on the datapath registers.

This only works if Vivado's timing-driven synthesis actually saw a real
clock target *before* running — that's why OOC mode writes and reads its
synthetic-clock XDC before calling `synth_design`, not after. A clock
applied post-synthesis has no influence on register-packing decisions.

## Caveats worth knowing

- `strict=1` fails the *exit code* on any CRITICAL WARNING, but doesn't
  abort the run to get there — every report still gets written first, so a
  strict failure in CI still leaves something to look at instead of just a
  log. That's aggressive on purpose for a fresh repo — it catches latch
  inference and width mismatches early. Use `--no-strict` if a legitimate
  vendor warning blocks you, but fix the underlying cause rather than
  leaving it off.
- `full` mode hard-requires `constr/abacus.xdc` to exist. `ooc` mode doesn't
  use it at all — it always builds its own synthetic clock from `clk_ns=`/
  `clk_port=` (defaults 5.0ns / `clk`), written to `ooc_clock.xdc`.
- The TNS figure in `summary.json` caps at 5000 paths. If
  `failing_endpoints` reads exactly 5000, treat TNS as a lower bound.
- `rsync --delete` mirrors your local tree onto the server. Anything you
  create *only* on the server inside `SYNTH_REMOTE_DIR` gets removed on the
  next sync — keep server-side scratch outside that directory.
- Post-synthesis timing is optimistic: it uses estimated routing delay. The
  honest Fmax number comes from implementation (ABACUS-22), not this script.
- `build.tcl` validates the part string against the current Vivado install
  before reading any sources — a typo'd `SYNTH_PART` fails in seconds, not
  after a full elaborate.
