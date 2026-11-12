#!/bin/bash
#------------------------------------------------------------------------------
# asap7_setup.sh -- fetch the ASAP7 7.5-track standard-cell libraries and
# compile them into Synopsys .db files for Design Compiler.
#
#   hw/synth/pdk/asap7_setup.sh            (normally run by `make asap7`)
#
# ASAP7 is a predictive 7 nm FinFET PDK from Arizona State University / ARM
# (BSD-3-Clause). We take the NLDM Liberty files that OpenROAD-flow-scripts
# redistributes (gzip-compressed), pinned to one commit for reproducibility.
#
# Environment:
#   ASAP7_DIR     install directory   (default: <repo>/pdk/asap7)
#   ASAP7_CORNER  TT | FF | SS        (default: TT)
#   ASAP7_VT      RVT | LVT | SLVT    (default: RVT)
#
# Result: $ASAP7_DIR/db/<CORNER>_<VT>/*.db  (+ the .lib sources in lib/)
#------------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
ASAP7_DIR="${ASAP7_DIR:-$REPO/pdk/asap7}"
CORNER="${ASAP7_CORNER:-TT}"
VT="${ASAP7_VT:-RVT}"

ORFS_COMMIT="bfcc1895a7a1d9ff6e677066825812e549b72421"
BASE_URL="https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/$ORFS_COMMIT/flow/platforms/asap7/lib/NLDM"

# Cell families and their library date stamps.
FILES=(
  "asap7sc7p5t_AO_${VT}_${CORNER}_nldm_211120.lib.gz"
  "asap7sc7p5t_INVBUF_${VT}_${CORNER}_nldm_220122.lib.gz"
  "asap7sc7p5t_OA_${VT}_${CORNER}_nldm_211120.lib.gz"
  "asap7sc7p5t_SIMPLE_${VT}_${CORNER}_nldm_211120.lib.gz"
  "asap7sc7p5t_SEQ_${VT}_${CORNER}_nldm_220123.lib"
)

LIB_DIR="$ASAP7_DIR/lib/${CORNER}_${VT}"
DB_DIR="$ASAP7_DIR/db/${CORNER}_${VT}"
mkdir -p "$LIB_DIR" "$DB_DIR" "$ASAP7_DIR/alib"

command -v lc_shell >/dev/null || { echo "asap7_setup: lc_shell not found -- source setup_env.sh"; exit 1; }
command -v curl     >/dev/null || { echo "asap7_setup: curl not found"; exit 1; }

# ---- download ----
for f in "${FILES[@]}"; do
  lib="${f%.gz}"
  if [ -s "$LIB_DIR/$lib" ]; then continue; fi
  echo "asap7_setup: downloading $f"
  curl -sSfL --retry 3 -o "$LIB_DIR/$f.part" "$BASE_URL/$f"
  mv "$LIB_DIR/$f.part" "$LIB_DIR/$f"
  if [[ "$f" == *.gz ]]; then gunzip -f "$LIB_DIR/$f"; fi
done

# ---- compile .lib -> .db with Library Compiler ----
todo=()
for f in "${FILES[@]}"; do
  lib="${f%.gz}"
  db="${lib%.lib}.db"
  [ -s "$DB_DIR/$db" ] || todo+=("$LIB_DIR/$lib")
done

if [ ${#todo[@]} -gt 0 ]; then
  echo "asap7_setup: compiling ${#todo[@]} libraries with lc_shell (a few minutes)"
  work="$ASAP7_DIR/lc_work"
  mkdir -p "$work"
  # On EWS (RHEL 9) the W-2024.09 lc_shell bundles an old libk5crypto/libtinfo
  # that clash with the system libkrb5/libncurses ("symbol lookup error").
  # Preloading the system copies fixes it. Override with LC_PRELOAD="" if your
  # install does not need it.
  if [ -z "${LC_PRELOAD+x}" ]; then
    LC_PRELOAD=""
    for l in /lib64/libk5crypto.so.3 /lib64/libtinfo.so.5; do
      [ -e "$l" ] && LC_PRELOAD="$LC_PRELOAD $l"
    done
  fi
  ( cd "$work" &&
    LD_PRELOAD="${LC_PRELOAD# }" LC_LIBS="${todo[*]}" LC_OUT_DIR="$DB_DIR" \
      lc_shell -f "$HERE/asap7_lib2db.tcl" > "$ASAP7_DIR/lc_${CORNER}_${VT}.log" 2>&1 ) || {
    echo "asap7_setup: lc_shell failed, see $ASAP7_DIR/lc_${CORNER}_${VT}.log"; exit 1; }
fi

for f in "${FILES[@]}"; do
  db="${f%.gz}"; db="${db%.lib}.db"
  [ -s "$DB_DIR/$db" ] || { echo "asap7_setup: missing $DB_DIR/$db (see lc log)"; exit 1; }
done
echo "asap7_setup: ready: $DB_DIR"
