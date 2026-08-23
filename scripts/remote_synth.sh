#!/usr/bin/env bash
# =====================================================================
# ABACUS - one-command remote synthesis
#
#   ./scripts/remote_synth.sh                       # full build, wait, pull
#   ./scripts/remote_synth.sh --top pe_mac --mode ooc --clk 4.0
#   ./scripts/remote_synth.sh --detach              # fire and forget
#   ./scripts/remote_synth.sh --attach              # watch a running build
#   ./scripts/remote_synth.sh --pull                # just fetch reports
#   ./scripts/remote_synth.sh --list-parts          # find your part string
#
# Flow: rsync tree up -> launch vivado in a detached tmux session on the
# server -> stream the log locally -> rsync reports back -> exit with the
# remote exit code. The tmux session owns the run, so killing this script
# or losing the network does not kill the synthesis.
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------
# Config. Put real values in .synthrc (gitignored) or export them.
# ---------------------------------------------------------------------
# shellcheck disable=SC1091
[[ -f "$REPO_ROOT/.synthrc" ]] && source "$REPO_ROOT/.synthrc"

SYNTH_HOST="${SYNTH_HOST:?set SYNTH_HOST=user@server in .synthrc}"
SYNTH_REMOTE_DIR="${SYNTH_REMOTE_DIR:-~/abacus-build}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2023.2/settings64.sh}"
TMUX_SESSION="${TMUX_SESSION:-abacus-synth}"
POLL_SECS="${POLL_SECS:-5}"

TOP="abacus_top"; MODE="full"; PART="${SYNTH_PART:-}"; CLK=""; STRICT="1"
WAIT=1; ACTION="build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)        TOP="$2"; shift 2 ;;
    --mode)       MODE="$2"; shift 2 ;;
    --part)       PART="$2"; shift 2 ;;
    --clk)        CLK="$2"; shift 2 ;;
    --no-strict)  STRICT="0"; shift ;;
    --detach)     WAIT=0; shift ;;
    --attach)     ACTION="attach"; shift ;;
    --pull)       ACTION="pull"; shift ;;
    --list-parts) ACTION="list-parts"; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

RUN_DIR="build/${TOP}_${MODE}"
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------
# Reused SSH connection. Without this, the poll loop opens a new TCP+auth
# handshake every few seconds; with it, every ssh after the first rides
# the same socket and is effectively free.
# ---------------------------------------------------------------------
# %C is ssh's own ControlPath token (a hash of user/host/port), substituted
# by ssh itself -- not a mktemp placeholder, so it can't go through mktemp's
# template. mktemp only picks the random per-invocation prefix; %C is
# appended literally afterward.
CTL="$(mktemp -u /tmp/abacus-ssh-XXXXXX)-%C"
SSH=(ssh -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=120)
cleanup() { "${SSH[@]}" -O exit "$SYNTH_HOST" 2>/dev/null || true; }
trap cleanup EXIT

rsh() { "${SSH[@]}" "$SYNTH_HOST" "$@"; }

case "$ACTION" in
  attach)
    exec "${SSH[@]}" -t "$SYNTH_HOST" "tmux attach -t '$TMUX_SESSION'"
    ;;
  pull)
    say "Pulling reports from $SYNTH_HOST:$SYNTH_REMOTE_DIR/build/"
    rsync -az -e "ssh -o ControlPath=$CTL" \
      "$SYNTH_HOST:$SYNTH_REMOTE_DIR/build/" "$REPO_ROOT/build/"
    exit 0
    ;;
  list-parts)
    rsync -az -e "ssh -o ControlPath=$CTL" --relative \
      ./synth/list_parts.tcl "$SYNTH_HOST:$SYNTH_REMOTE_DIR/"
    rsh "source '$VIVADO_SETTINGS' >/dev/null && cd '$SYNTH_REMOTE_DIR' && \
         vivado -mode batch -nolog -nojournal -source synth/list_parts.tcl"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------
# 1. Refuse to clobber a run that is already going. A session that's just
#    sitting at remote_run.sh's PRESS-ENTER prompt is done, not running --
#    clean it up rather than blocking the next launch on a stale window.
# ---------------------------------------------------------------------
if rsh "tmux has-session -t '$TMUX_SESSION' 2>/dev/null"; then
  if rsh "tmux capture-pane -p -t '$TMUX_SESSION' 2>/dev/null" | tail -3 | grep -q "PRESS-ENTER"; then
    say "Previous run finished (session was idling at PRESS-ENTER) -- cleaning it up"
    rsh "tmux kill-session -t '$TMUX_SESSION'" 2>/dev/null || true
  fi
fi
if rsh "tmux has-session -t '$TMUX_SESSION' 2>/dev/null"; then
  echo "A build is already running in tmux session '$TMUX_SESSION'." >&2
  echo "  watch it : $0 --attach" >&2
  echo "  kill it  : ssh $SYNTH_HOST tmux kill-session -t $TMUX_SESSION" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 2. Generate the remote runner. Writing a script and shipping it beats
#    nesting quotes through ssh -> tmux -> bash three levels deep.
# ---------------------------------------------------------------------
mkdir -p "$REPO_ROOT/build"
RUNNER="$REPO_ROOT/build/.remote_run.sh"
TCLARGS="top=$TOP mode=$MODE strict=$STRICT"
[[ -n "$PART" ]] && TCLARGS="$TCLARGS part=$PART"
[[ -n "$CLK"  ]] && TCLARGS="$TCLARGS clk_ns=$CLK"

cat > "$RUNNER" <<RUNNER_EOF
#!/usr/bin/env bash
set -uo pipefail
cd "\$(dirname "\$0")/.."
mkdir -p "$RUN_DIR"
rm -f "$RUN_DIR/.exit"
source "$VIVADO_SETTINGS" >/dev/null
echo "vivado: \$(which vivado)"
vivado -mode batch -nojournal \\
       -log "$RUN_DIR/vivado.log" \\
       -source synth/build.tcl \\
       -tclargs $TCLARGS 2>&1 | tee "$RUN_DIR/run.log"
rc=\${PIPESTATUS[0]}
echo "\$rc" > "$RUN_DIR/.exit"
echo "--- exited \$rc ---"
RUNNER_EOF
chmod +x "$RUNNER"

# ---------------------------------------------------------------------
# 3. Sync the working tree. --delete keeps the server from accumulating
#    files you renamed or removed locally; excludes keep build junk and
#    the Python env out of the transfer.
# ---------------------------------------------------------------------
say "Syncing tree -> $SYNTH_HOST:$SYNTH_REMOTE_DIR"
rsh "mkdir -p '$SYNTH_REMOTE_DIR'"
rsync -az --delete --info=stats1 -e "ssh -o ControlPath=$CTL" \
  --exclude '.git/' --exclude '.venv/' --exclude '__pycache__/' \
  --exclude 'sim_build/' --exclude '*.dcp' --exclude '*.jou' \
  --exclude 'build/*/vivado.log' \
  ./ "$SYNTH_HOST:$SYNTH_REMOTE_DIR/"

# ---------------------------------------------------------------------
# 4. Launch inside tmux, detached.
# ---------------------------------------------------------------------
say "Launching '$TOP' ($MODE) in tmux session '$TMUX_SESSION'"
rsh "tmux new-session -d -s '$TMUX_SESSION' \
     'bash $SYNTH_REMOTE_DIR/build/.remote_run.sh; echo; echo PRESS-ENTER; read'"

if [[ $WAIT -eq 0 ]]; then
  say "Detached. Watch with: $0 --attach   |   fetch with: $0 --pull"
  exit 0
fi

# ---------------------------------------------------------------------
# 5. Stream the log until the exit marker appears.
# ---------------------------------------------------------------------
say "Streaming (Ctrl-C stops watching, NOT the build)"
sleep 2
LINES=0
while true; do
  if rsh "test -f '$SYNTH_REMOTE_DIR/$RUN_DIR/.exit'"; then break; fi
  NEW=$(rsh "wc -l < '$SYNTH_REMOTE_DIR/$RUN_DIR/run.log' 2>/dev/null || echo 0")
  if [[ "$NEW" -gt "$LINES" ]]; then
    rsh "tail -n +$((LINES + 1)) '$SYNTH_REMOTE_DIR/$RUN_DIR/run.log'" || true
    LINES=$NEW
  fi
  sleep "$POLL_SECS"
done
rsh "tail -n +$((LINES + 1)) '$SYNTH_REMOTE_DIR/$RUN_DIR/run.log'" || true

RC=$(rsh "cat '$SYNTH_REMOTE_DIR/$RUN_DIR/.exit'")
rsh "tmux kill-session -t '$TMUX_SESSION' 2>/dev/null" || true

# ---------------------------------------------------------------------
# 6. Pull reports back.
# ---------------------------------------------------------------------
say "Pulling reports"
mkdir -p "$REPO_ROOT/$RUN_DIR"
rsync -az -e "ssh -o ControlPath=$CTL" \
  "$SYNTH_HOST:$SYNTH_REMOTE_DIR/$RUN_DIR/" "$REPO_ROOT/$RUN_DIR/"

echo
if [[ "$RC" == "0" ]]; then
  say "PASS - reports in $RUN_DIR/"
  [[ -f "$RUN_DIR/summary.json" ]] && cat "$RUN_DIR/summary.json"
else
  say "FAIL (exit $RC) - see $RUN_DIR/vivado.log"
fi
exit "$RC"