# freepdk45.tcl -- PDK configuration for synthesis.tcl: FreePDK45 /
# Nangate Open Cell Library (45 nm). On EWS: /class/ece411/freepdk-45nm.
#
# Inputs (environment): STD_CELL_LIB (path to stdcells.db)
# Defines: pdk_name pdk_target_libs pdk_time_scale pdk_output_load
#          pdk_driving_cell pdk_dont_use pdk_alib_dir

set lib [env_or STD_CELL_LIB ""]
if {$lib eq "" || ![file exists $lib]} {
  puts "ERROR: STD_CELL_LIB is not set or missing ('$lib') -- source setup_env.sh"
  exit 1
}

set pdk_name         "FreePDK45 (Nangate typical)"
set pdk_target_libs  [list $lib]
set pdk_time_scale   1.0                    ;# library time unit is 1 ns
set pdk_output_load  4.0                    ;# fF
set pdk_driving_cell BUF_X2
set pdk_dont_use     {}
# EWS ships a pre-built alib next to the .db (read-only); else build locally.
set pdk_alib_dir     [file join [file dirname $lib] alib]
if {![file isdirectory $pdk_alib_dir]} { set pdk_alib_dir "" }

# No SRAM macros for this PDK: scratchpads are built from flip-flops.
set pdk_sram_libs {}
