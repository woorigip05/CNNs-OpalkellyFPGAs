# XSIM signoff smoke test (ABACUS-15)

## Why this exists, and why it isn't cocotb

Day-to-day verification is cocotb + Verilator (`tb/`, `make test`). This is
different: a plain SystemVerilog, self-checking testbench run through
Xilinx's own simulator (`xvlog`/`xelab`/`xsim`), because **cocotb has no
XSIM backend** — check `cocotb_tools/makefiles/simulators/` in your venv
and there's a `Makefile.xcelium` (Cadence's simulator, a different tool
despite the similar name) but no `Makefile.xsim`. XSIM's VPI was never
upstreamed into cocotb, so `SIM=xsim` on the existing `tb/adder` testbench
just fails with "Couldn't find makefile for simulator: xsim". Confirmed by
trying it, not assumed.

The point of proving this now, on the trivial `adder` DUT, is that some
future IP (encrypted Opal Kelly `okHost`/`okLibrary` sources, most likely)
will only be simulatable with a vendor-approved simulator at all — you want
the signoff path already working before that's the thing blocking you.

## What's here

| file | what it's for |
|---|---|
| `tb_adder.sv` | Self-checking testbench. Same directed cases as `tb/adder/test_adder.py`'s directed test (not the 100-case random one — this is a smoke test, kept small and deterministic on purpose). |
| `run.sh` | `xvlog` -> `xelab` -> `xsim -runall`, batch mode. Needs Vivado's `settings64.sh` sourced first (`xvlog`/`xelab`/`xsim` on `PATH`). |
| `work/` | Scratch output (`xsim_run.log`, `xsim.dir/`, the compiled snapshot). Gitignored, wiped at the start of every `run.sh`. |

## Running it

```bash
make sim-xsim                  # syncs to $SYNTH_HOST (.synthrc) and runs it there
./scripts/remote_xsim.sh       # same thing, directly

# or locally, if this machine has Vivado:
source /path/to/Vivado/settings64.sh
./sim/xsim/run.sh
```

## The one non-obvious thing: XSIM's exit code lies

`xsim -runall`'s own process exit code is **0 even when the testbench calls
`$fatal`** — confirmed by deliberately breaking the testbench and checking
`$?` directly, not assumed from docs. So `run.sh` doesn't trust `$?` at
all; it greps `xsim_run.log` for `ALL TESTS PASSED` (and the absence of
`FAIL`/`Fatal:`) and sets its own exit code from that. If you ever rework
this testbench, keep that in mind — a testbench that hangs, crashes, or
silently produces no `ALL TESTS PASSED` line will look like a pass to
anything watching `$?` alone.
