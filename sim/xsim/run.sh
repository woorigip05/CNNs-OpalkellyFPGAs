#!/usr/bin/env bash
# sim/xsim/run.sh -- batch-mode XSIM smoke test (ABACUS-15).
#
# Needs Vivado's settings64.sh sourced first (xvlog/xelab/xsim on PATH).
# Runs locally; scripts/remote_xsim.sh wraps this over SSH for the server.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$REPO_ROOT/sim/xsim/work"
DUT="$REPO_ROOT/rtl/adder.sv"
TB="$REPO_ROOT/sim/xsim/tb_adder.sv"

command -v xvlog >/dev/null || { echo "xvlog not on PATH -- source Vivado's settings64.sh first" >&2; exit 2; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "==> xvlog"
xvlog --sv "$DUT" "$TB"

echo "==> xelab"
xelab tb_adder -s tb_adder_sim

echo "==> xsim -runall"
# xsim's own process exit code does not reliably reflect $fatal, so the log
# text is the actual pass/fail signal -- grep it rather than trust $?.
xsim tb_adder_sim -runall -log xsim_run.log || true

if grep -q "ALL TESTS PASSED" xsim_run.log && ! grep -qi "^FAIL\|Fatal:" xsim_run.log; then
    echo "PASS"
    exit 0
else
    echo "FAIL -- see $WORK_DIR/xsim_run.log"
    exit 1
fi
