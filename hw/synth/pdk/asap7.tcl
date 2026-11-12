# asap7.tcl -- PDK configuration for synthesis.tcl: ASAP7 7.5-track cells.
#
# ASAP7 is a predictive 7 nm FinFET PDK (ASU / ARM, BSD-3-Clause), not a real
# foundry process -- numbers are realistic for teaching, not for tape-out.
# Libraries are fetched and compiled by asap7_setup.sh (`make asap7`).
#
# Inputs (environment): ASAP7_DIR, ASAP7_CORNER (TT|FF|SS), ASAP7_VT (RVT|LVT|SLVT)
# Defines: pdk_name pdk_target_libs pdk_time_scale pdk_output_load
#          pdk_driving_cell pdk_dont_use pdk_alib_dir
#          pdk_sram_libs (generated SRAM macros, `make sram`; may be empty)

set asap7_dir    [env_or ASAP7_DIR [file normalize [file dirname [info script]]/../../../pdk/asap7]]
set asap7_corner [env_or ASAP7_CORNER TT]
set asap7_vt     [env_or ASAP7_VT RVT]
set asap7_db_dir [file join $asap7_dir db ${asap7_corner}_${asap7_vt}]

set pdk_target_libs [lsort [glob -nocomplain [file join $asap7_db_dir *.db]]]
if {[llength $pdk_target_libs] != 5} {
  puts "ERROR: expected 5 ASAP7 .db files in $asap7_db_dir, found [llength $pdk_target_libs]."
  puts "ERROR: run `make asap7` (or hw/synth/pdk/asap7_setup.sh) first."
  exit 1
}

# Cell-name suffix by threshold voltage: _R (RVT), _L (LVT), _SL (SLVT)
set asap7_suffix [dict get {RVT R LVT L SLVT SL} $asap7_vt]

set pdk_name         "ASAP7 ${asap7_vt} ${asap7_corner} (0.7 V)"
set pdk_time_scale   1000.0                 ;# library time unit is 1 ps
set pdk_output_load  3.898                  ;# fF, same default as OpenROAD-flow-scripts
set pdk_driving_cell BUFx2_ASAP7_75t_${asap7_suffix}

# Same exclusions as OpenROAD-flow-scripts: fractional-drive cells (x1p*, xp*)
# are hard to place/route; scan flops and clock gaters are not used here.
set pdk_dont_use {*/*x1p*_ASAP7* */*xp*_ASAP7* */SDF* */ICG*}

# SRAM macro models from hw/sram/sram_gen.py (link-only libraries: DC never
# maps logic to them, the RTL instantiates them in accel_sram_1rw.sv).
set pdk_sram_libs [lsort [glob -nocomplain [file join $asap7_dir sram db $asap7_corner *.db]]]

# Shared, writable alib cache: built once by the first compile, then reused.
set pdk_alib_dir [file join $asap7_dir alib]
file mkdir $pdk_alib_dir
