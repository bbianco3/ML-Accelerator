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
#   MAX_AREA_UM2    area target for set_max_area (0 = as small as possible)
#   SYNTH_TIME_LIMIT_MIN, SYNTH_EXTRA_PASSES, SYNTH_RETIME, SYNTH_CLOCK_GATING,
#   SYNTH_MAX_FANOUT, SYNTH_BUFFER_PORTS
#                   synthesis settings, see docs/synthesis.md
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

# Synthesis settings (competition.json "design" / "synth", or make variables)
set max_area       [env_or MAX_AREA_UM2 0]          ;# area target in um^2, 0 = as small as possible
set time_limit_min [env_or SYNTH_TIME_LIMIT_MIN 0]  ;# 0 = no limit
set extra_passes   [env_or SYNTH_EXTRA_PASSES 0]    ;# incremental compiles while timing is violated
set opt_retime     [env_or SYNTH_RETIME 0]          ;# move registers across logic to balance stages
set opt_gating     [env_or SYNTH_CLOCK_GATING 0]    ;# insert clock gates on enabled registers
set max_fanout     [env_or SYNTH_MAX_FANOUT 0]      ;# buffer nets with more loads than this, 0 = off
set buffer_ports   [env_or SYNTH_BUFFER_PORTS 0]    ;# buffer feedthroughs / multiply-driven ports
set t_start        [clock seconds]
proc elapsed_min {} { return [expr {([clock seconds] - $::t_start) / 60.0}] }

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
  # clock gating needs the integrated clock-gating cells
  if {$opt_gating && [string match "*ICG*" $pat]} { continue }
  set cells [get_lib_cells -quiet $pat]
  if {[sizeof_collection $cells] > 0} { set_dont_use $cells }
}

# Reset is a synchronous, high-fanout net: treat it as ideal here and let
# physical design build the tree.
set_ideal_network [get_ports rst_n]

# ---- area target and buffering ----
# Area: after timing is met DC recovers area until the design is below the
# target (0 = keep going as far as it can).
set_max_area $max_area
# Buffering. DC always sizes and buffers for timing; these add design rules
# that force buffer trees on high-fanout nets and isolate ports.
if {$max_fanout > 0} { set_max_fanout $max_fanout [current_design] }
if {$buffer_ports}   { set_fix_multiple_port_nets -all -buffer_constants }

write_sdc accel_top.sdc

# What this run was asked to do (read by tools/competition.py)
set fh [open reports/settings.rpt w]
puts $fh "clk_period_ns=$clk_ns"
puts $fh "max_area_um2=$max_area"
puts $fh "time_limit_min=$time_limit_min extra_passes=$extra_passes retime=$opt_retime\
 clock_gating=$opt_gating max_fanout=$max_fanout buffer_ports=$buffer_ports"
close $fh

#------------------------------------------------------------------------------
# Reports and outputs (written after every pass, so that a run that is stopped
# by the time limit still leaves the results of the last finished pass)
#------------------------------------------------------------------------------
proc write_results {sram_mode gating} {
  report_qor                                  > reports/qor.rpt
  report_area -hierarchy                      > reports/area.rpt
  report_timing -max_paths 10 -nworst 1       > reports/timing.rpt
  report_constraint -all_violators            > reports/violators.rpt
  report_power -hierarchy                     > reports/power.rpt
  report_reference -hierarchy                 > reports/reference.rpt
  if {$gating} { report_clock_gating          > reports/clock_gating.rpt }
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
}

proc worst_slack {} {
  set p [get_timing_paths -max_paths 1]
  if {[sizeof_collection $p] == 0} { return 0.0 }
  return [get_attribute $p slack]
}

#------------------------------------------------------------------------------
# Compile
#------------------------------------------------------------------------------
set compile_opts {-no_autoungroup}
if {$opt_retime} { lappend compile_opts -retime }
if {$opt_gating} { lappend compile_opts -gate_clock }

puts "INFO: compile_ultra $compile_opts"
eval compile_ultra $compile_opts
write_results $sram_mode $opt_gating
puts [format "INFO: first compile done after %.1f min, worst slack %s" [elapsed_min] [worst_slack]]

# Extra passes: only while timing is violated and there is time left.
for {set pass 1} {$pass <= $extra_passes} {incr pass} {
  if {[worst_slack] >= 0} {
    puts "INFO: timing is met, no extra pass needed"
    break
  }
  if {$time_limit_min > 0 && [elapsed_min] >= $time_limit_min} {
    puts [format "INFO: time limit of %s min reached after %.1f min, skipping extra pass %d" \
            $time_limit_min [elapsed_min] $pass]
    break
  }
  puts "INFO: extra pass $pass of $extra_passes: compile_ultra -incremental $compile_opts"
  eval compile_ultra -incremental $compile_opts
  write_results $sram_mode $opt_gating
  puts [format "INFO: extra pass %d done after %.1f min, worst slack %s" $pass [elapsed_min] [worst_slack]]
}

puts [format "INFO: synthesis finished after %.1f min. Worst slack:" [elapsed_min]]
report_timing -max_paths 1 -nworst 1 -significant_digits 3
exit
