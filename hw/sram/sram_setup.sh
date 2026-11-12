#!/bin/bash
#------------------------------------------------------------------------------
# sram_setup.sh -- generate the ASAP7 SRAM macro catalog and compile it for
# Design Compiler.                         (normally run by `make sram`)
#
#   1. hw/sram/sram_gen.py writes Liberty models, Verilog models and a
#      datasheet for every catalog size (see CATALOG in sram_gen.py),
#   2. lc_shell compiles each .lib into a .db.
#
# Environment:
#   ASAP7_DIR      install directory           (default: <repo>/pdk/asap7)
#   ASAP7_CORNER   TT | FF | SS                (default: TT)
#   SRAM_MODELS_ONLY=1   only write the Verilog models (no lc_shell needed;
#                        that is all simulation with SIM_SRAM=macro needs)
#
# Result: $ASAP7_DIR/sram/{verilog/*.v, lib/*.lib, db/<CORNER>/*.db,
#                          datasheet_<CORNER>.md}
#------------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ASAP7_DIR="${ASAP7_DIR:-$REPO/pdk/asap7}"
CORNER="${ASAP7_CORNER:-TT}"
OUT="$ASAP7_DIR/sram"
DB_DIR="$OUT/db/$CORNER"

command -v python3 >/dev/null || { echo "sram_setup: python3 not found"; exit 1; }

# Regenerate whenever the generator is newer than the datasheet.
stamp="$OUT/datasheet_${CORNER}.md"
if [ ! -s "$stamp" ] || [ "$HERE/sram_gen.py" -nt "$stamp" ]; then
  python3 "$HERE/sram_gen.py" --out "$OUT" --corner "$CORNER"
  rm -rf "$DB_DIR"
fi

[ "${SRAM_MODELS_ONLY:-0}" = "1" ] && exit 0

mkdir -p "$DB_DIR"
todo=()
for lib in "$OUT"/lib/*_"$CORNER".lib; do
  db="$DB_DIR/$(basename "${lib%.lib}").db"
  [ -s "$db" ] || todo+=("$lib")
done

if [ ${#todo[@]} -gt 0 ]; then
  command -v lc_shell >/dev/null || { echo "sram_setup: lc_shell not found -- source setup_env.sh"; exit 1; }
  echo "sram_setup: compiling ${#todo[@]} SRAM libraries with lc_shell"
  work="$OUT/lc_work"
  mkdir -p "$work"
  # Same lc_shell library clash workaround as asap7_setup.sh.
  if [ -z "${LC_PRELOAD+x}" ]; then
    LC_PRELOAD=""
    for l in /lib64/libk5crypto.so.3 /lib64/libtinfo.so.5; do
      [ -e "$l" ] && LC_PRELOAD="$LC_PRELOAD $l"
    done
  fi
  ( cd "$work" &&
    LD_PRELOAD="${LC_PRELOAD# }" LC_LIBS="${todo[*]}" LC_OUT_DIR="$DB_DIR" \
      lc_shell -f "$REPO/hw/synth/pdk/asap7_lib2db.tcl" > "$OUT/lc_${CORNER}.log" 2>&1 ) || {
    echo "sram_setup: lc_shell failed, see $OUT/lc_${CORNER}.log"; exit 1; }
fi
echo "sram_setup: ready: $DB_DIR (datasheet: $stamp)"
