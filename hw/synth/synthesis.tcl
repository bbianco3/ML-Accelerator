#------------------------------------------------------------------------------
# synthesis.tcl -- Synopsys Design Compiler script for accel_top
#
# Normally run through `make synth` (hw/synth/synth.mk), which sets these
# environment variables and runs dc_shell inside build/synth/<config>/:
#
#   ACCEL_RTL_DIR   path to hw/rtl (contains filelist.f)
#   ACCEL_GEN_SRCS  generated RTL files to read before filelist.f (the SRAM wrapper)
#   PDK             asap7 (default) | freepdk45 -> sources pdk/<PDK>.tcl
#                   (ASAP7_DIR/ASAP7_CORNER/ASAP7_VT or STD_CELL_LIB, see there)
#   CLK_PERIOD      clock period in ns, whatever the library unit (default 2.5)
#   VLEN MAT_DIM NUM_TREGS NUM_ACCS MXU_ROWS HBM_DATA_W ICACHE_LINES
#   NUM_CORES SPAD_KB NUM_VPUS NUM_MXUS FP_PIPE
#                   RTL parameters                           (RTL defaults)
#   SRAM            macro (default): scratchpads use the PDK's SRAM macros
#                   flops: scratchpads are flip-flop arrays
#   SYNTH_ELAB_ONLY 1 = stop after elaborate + check_design (fast syntax check)
#
# Outputs (current directory): reports/*.rpt, accel_top.ddc, accel_top.v,
# accel_top.sdc. See docs/synthesis.md.
#------------------------------------------------------------------------------

proc env_or {name default} {
  if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
  return $default
}

set rtl_dir    [env_or ACCEL_RTL_DIR [file normalize [file dirname [info script]]/../rtl]]
set pdk        [env_or PDK asap7]
set clk_ns     [env_or CLK_PERIOD 2.5]
set elab_only  [env_or SYNTH_ELAB_ONLY 0]
set sram_mode  [env_or SRAM macro]

# RTL parameters (only the ones that are set are passed to elaborate)
set param_list {}
foreach p {VLEN MAT_DIM NUM_TREGS NUM_ACCS MXU_ROWS HBM_DATA_W ICACHE_LINES NUM_CORES SPAD_KB
           NUM_VPUS NUM_MXUS FP_PIPE} {
  if {[info exists ::env($p)] && $::env($p) ne ""} { lappend param_list "$p=$::env($p)" }
}
set params [join $param_list ","]

#------------------------------------------------------------------------------
# Libraries
#------------------------------------------------------------------------------
set pdk_file [file join [file dirname [file normalize [info script]]] pdk $pdk.tcl]
if {![file exists $pdk_file]} {
  puts "ERROR: unknown PDK '$pdk' (no $pdk_file)"
  exit 1
}
source $pdk_file
puts "INFO: PDK $pdk_name, clock period $clk_ns ns"

set target_library    $pdk_target_libs
set synthetic_library [list dw_foundation.sldb]
set link_library      [concat "*" $target_library $synthetic_library]

# SRAM macros: link-only libraries + the RTL define that instantiates them.
set rtl_defines {SYNTHESIS}
if {$sram_mode eq "macro"} {
  if {[llength $pdk_sram_libs] == 0} {
    puts "ERROR: SRAM=macro but no SRAM macro libraries for PDK $pdk (run `make sram`, or use SRAM=flops)"
    exit 1
  }
  set link_library [concat $link_library $pdk_sram_libs]
  lappend rtl_defines ACCEL_SRAM_MACROS
  puts "INFO: scratchpads use [llength $pdk_sram_libs] SRAM macro libraries"
} else {
  puts "INFO: scratchpads are flip-flop arrays (SRAM=flops)"
}

# alib = DC's library analysis cache. Reuse the PDK's if it has one; otherwise
# the first compile builds ./alib-52 in the run directory (slow, once).
if {$pdk_alib_dir ne ""} { set_app_var alib_library_analysis_path $pdk_alib_dir }

set_app_var hdlin_check_no_latch true
set_app_var compile_seqmap_propagate_constants false
define_design_lib WORK -path ./work

# Quiet a few lint messages that are expected in parameterised RTL.
suppress_message {LINT-1 LINT-2 LINT-28 LINT-29 LINT-31 LINT-32 LINT-33 LINT-52 LINT-99}
suppress_message {VER-130 VER-318 ELAB-311}

#------------------------------------------------------------------------------
# Read RTL (same file list as simulation)
#------------------------------------------------------------------------------
# generated sources first (the SRAM wrapper), then the design's file list
set files [split [string trim [env_or ACCEL_GEN_SRCS ""]]]
set fh [open $rtl_dir/filelist.f r]
foreach line [split [read $fh] "\n"] {
  set l [string trim $line]
  if {$l eq "" || [string index $l 0] eq "#"} { continue }
  lappend files [file join $rtl_dir $l]
}
close $fh

puts "INFO: analyzing [llength $files] files from $rtl_dir"
analyze -library WORK -format sverilog -define $rtl_defines $files

if {$params ne ""} {
  puts "INFO: elaborating accel_top with $params"
  elaborate accel_top -library WORK -parameters $params
} else {
  elaborate accel_top -library WORK
}
# Elaborating with parameters renames the design (accel_top_VLEN256...);
# give it back its plain name so outputs are predictable.
set elab_name [get_object_name [current_design]]
if {$elab_name ne "accel_top"} { rename_design $elab_name accel_top }
current_design accel_top
link

file mkdir reports
check_design > reports/check_design.rpt
if {$elab_only} {
  puts "INFO: SYNTH_ELAB_ONLY set -- stopping after elaboration"
  exit
}

#------------------------------------------------------------------------------
# Constraints
#------------------------------------------------------------------------------
# CLK_PERIOD is in ns; libraries use their own time unit (ASAP7: ps).
set clk_period [expr {$clk_ns * $pdk_time_scale}]
create_clock -name clk -period $clk_period [get_ports clk]
# Setup-only uncertainty: with an ideal (pre-CTS) clock, hold is checked but
# not fixed here -- hold buffers are inserted after clock-tree synthesis in
# place & route, where real clock skew is known.
set_clock_uncertainty -setup [expr {0.02 * $clk_period}] [get_clocks clk]

set non_clk_inputs [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  [expr {0.2 * $clk_period}] -clock clk $non_clk_inputs
set_output_delay [expr {0.2 * $clk_period}] -clock clk [all_outputs]
set_load $pdk_output_load [all_outputs]
if {$pdk_driving_cell ne ""} {
  set_driving_cell -lib_cell $pdk_driving_cell $non_clk_inputs
}

foreach pat $pdk_dont_use {
  set cells [get_lib_cells -quiet $pat]
  if {[sizeof_collection $cells] > 0} { set_dont_use $cells }
}

# Reset is a synchronous, high-fanout net: treat it as ideal here and let
# physical design build the tree.
set_ideal_network [get_ports rst_n]

write_sdc accel_top.sdc

#------------------------------------------------------------------------------
# Compile
#------------------------------------------------------------------------------
compile_ultra -no_autoungroup

#------------------------------------------------------------------------------
# Reports and outputs
#------------------------------------------------------------------------------
report_qor                                  > reports/qor.rpt
report_area -hierarchy                      > reports/area.rpt
report_timing -max_paths 10 -nworst 1       > reports/timing.rpt
report_constraint -all_violators            > reports/violators.rpt
report_power -hierarchy                     > reports/power.rpt
report_reference -hierarchy                 > reports/reference.rpt
# Every SRAM macro instance with its area (empty with SRAM=flops)
set sram_cells [get_cells -quiet -hierarchical -filter "ref_name =~ sram1rw_*"]
if {[sizeof_collection $sram_cells] > 0} {
  report_cell -nosplit $sram_cells          > reports/sram.rpt
} else {
  echo "No SRAM macros (SRAM=$sram_mode)"  > reports/sram.rpt
}
check_design                                > reports/check_design_post.rpt

write -format ddc     -hierarchy -output accel_top.ddc
write -format verilog -hierarchy -output accel_top.v

puts "INFO: synthesis finished. Worst slack:"
report_timing -max_paths 1 -nworst 1 -significant_digits 3
exit
