#!/bin/bash
#------------------------------------------------------------------------------
# run_on_ews.sh -- run a make target on a remote machine that has the Synopsys
# tools (e.g. UIUC EWS) and copy the results back.
#
#   ./run_on_ews.sh                       # make run TEST=hello
#   ./run_on_ews.sh run TEST=matmul       # any make arguments
#   ./run_on_ews.sh regress
#   ./run_on_ews.sh run TEST=gemm WAVES=1 # waveforms come back too
#
# The repo is rsync'ed to $REMOTE_DIR, `source setup_env.sh && make <args>`
# runs there, and build/runs + build/synth reports are copied back into
# ./ews_run_artifacts/. Set EWS_HOST (or edit the default below) first.
# If you are already logged in on EWS, just run make directly instead.
#------------------------------------------------------------------------------
set -euo pipefail

EWS_HOST="${EWS_HOST:-netid@linux.ews.illinois.edu}"
REMOTE_DIR="${REMOTE_DIR:-~/sigarch-ml-accelerator}"
OUT_DIR="./ews_run_artifacts"

if [[ "$EWS_HOST" == netid@* ]]; then
  echo "run_on_ews.sh: set EWS_HOST=<your-netid>@linux.ews.illinois.edu (or edit this script)" >&2
  exit 1
fi

MAKE_ARGS=("$@")
[ ${#MAKE_ARGS[@]} -eq 0 ] && MAKE_ARGS=(run TEST=hello)

cd "$(dirname "$0")"
mkdir -p "$OUT_DIR"

rsync -az --delete --exclude .git --exclude build --exclude ews_run_artifacts --exclude pdk \
  ./ "$EWS_HOST:$REMOTE_DIR/"

status=0
ssh "$EWS_HOST" "bash -lc 'cd $REMOTE_DIR && source setup_env.sh >/dev/null && make ${MAKE_ARGS[*]}'" || status=$?

# Logs, waveforms and synthesis reports (whatever exists).
rsync -az --prune-empty-dirs \
  --include '*/' --include '*.log' --include '*.fsdb' --include '*.vcd' --include '*.rpt' \
  --include '*.dis' --exclude '*' \
  "$EWS_HOST:$REMOTE_DIR/build/" "$OUT_DIR/" || true

echo "run_on_ews.sh: make exited with $status; artifacts in $OUT_DIR/"
exit $status
