#!/bin/bash
#------------------------------------------------------------------------------
# setup_env.sh -- put Synopsys VCS/Verdi/DC and a RISC-V GCC on your PATH.
#
#   source setup_env.sh
#
# Defaults are for UIUC EWS machines. On another machine, export the
# variables below yourself (or edit this file) before sourcing:
#   SYNOPSYS_MODULE   environment module providing vcs/verdi/dc_shell
#   RISCV_ROOT        RISC-V GNU toolchain install (has bin/riscv64-unknown-elf-gcc)
#   STD_CELL_LIB      FreePDK45 .db, only for `make synth PDK=freepdk45`
#                     (the default ASAP7 PDK is fetched by `make asap7`)
#------------------------------------------------------------------------------

# ---- Synopsys tools ----
SYNOPSYS_MODULE="${SYNOPSYS_MODULE:-Synopsys_x86-64/2024}"
if ! command -v vcs >/dev/null 2>&1; then
  if type module >/dev/null 2>&1; then
    module load "$SYNOPSYS_MODULE" || echo "setup_env: could not load module $SYNOPSYS_MODULE"
  else
    echo "setup_env: 'module' command not available; put vcs/verdi/dc_shell on PATH yourself"
  fi
fi

# The Synopsys module puts an ancient GNU make 3.80 (mvtools) first on PATH,
# which cannot parse our Makefiles. Drop that directory; nothing we use is in it.
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/mvtools/' | paste -sd: -)"
export PATH

# ---- RISC-V cross compiler ----
RISCV_ROOT="${RISCV_ROOT:-/class/ece411/riscv}"
if ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && [ -d "$RISCV_ROOT/bin" ]; then
  export PATH="$PATH:$RISCV_ROOT/bin"
  # The EWS toolchain needs a few shared libraries that live next to it.
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$RISCV_ROOT/compat:$RISCV_ROOT/lib:$RISCV_ROOT/lib64"
fi

# ---- FreePDK45 cells (optional PDK; ASAP7 is the default, see docs/synthesis.md) ----
export FREEPDK45="${FREEPDK45:-/class/ece411/freepdk-45nm}"
export STD_CELL_LIB="${STD_CELL_LIB:-$FREEPDK45/stdcells.db}"

# ---- report ----
for t in vcs verdi dc_shell lc_shell riscv64-unknown-elf-gcc; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  %-24s %s\n" "$t" "$(command -v "$t")"
  else
    printf "  %-24s MISSING\n" "$t"
  fi
done
[ -f "$STD_CELL_LIB" ] && printf "  %-24s %s\n" "STD_CELL_LIB" "$STD_CELL_LIB" \
                       || printf "  %-24s MISSING (%s)\n" "STD_CELL_LIB" "$STD_CELL_LIB"
