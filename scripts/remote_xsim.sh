#!/usr/bin/env bash
# ABACUS - remote XSIM smoke test (ABACUS-15)
#
#   ./scripts/remote_xsim.sh
#
# Syncs the tree to the same server used for synthesis (.synthrc) and runs
# sim/xsim/run.sh there, so the vendor-simulator signoff path is proven
# before it's actually needed for something only XSIM can simulate
# (encrypted Opal Kelly IP, etc). No tmux here on purpose -- this is a
# seconds-long smoke test, not a build worth surviving a dropped connection.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/.synthrc" ]] && source "$REPO_ROOT/.synthrc"

SYNTH_HOST="${SYNTH_HOST:?set SYNTH_HOST=user@server in .synthrc}"
SYNTH_REMOTE_DIR="${SYNTH_REMOTE_DIR:-~/abacus-build}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Syncing tree -> $SYNTH_HOST:$SYNTH_REMOTE_DIR"
ssh "$SYNTH_HOST" "mkdir -p '$SYNTH_REMOTE_DIR'"
rsync -az --delete --info=stats1 \
  --exclude '.git/' --exclude '.venv/' --exclude '__pycache__/' \
  --exclude 'sim_build/' --exclude 'sim/xsim/work/' \
  --exclude '*.dcp' --exclude '*.jou' --exclude 'build/*/vivado.log' \
  ./ "$SYNTH_HOST:$SYNTH_REMOTE_DIR/"

say "Running XSIM smoke test on $SYNTH_HOST"
RC=0
ssh "$SYNTH_HOST" "
  source '$VIVADO_SETTINGS' >/dev/null &&
  cd '$SYNTH_REMOTE_DIR' &&
  ./sim/xsim/run.sh
" || RC=$?

mkdir -p "$REPO_ROOT/sim/xsim/work"
rsync -az "$SYNTH_HOST:$SYNTH_REMOTE_DIR/sim/xsim/work/xsim_run.log" \
  "$REPO_ROOT/sim/xsim/work/xsim_run.log" 2>/dev/null || true

if [[ "$RC" -eq 0 ]]; then
  say "PASS"
else
  say "FAIL (exit $RC) -- see sim/xsim/work/xsim_run.log"
fi
exit "$RC"
