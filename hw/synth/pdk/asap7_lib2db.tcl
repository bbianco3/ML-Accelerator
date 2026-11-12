# asap7_lib2db.tcl -- Library Compiler script used by asap7_setup.sh.
# Compiles every Liberty file in $LC_LIBS (space separated) into
# $LC_OUT_DIR/<file>.db.
set out_dir $::env(LC_OUT_DIR)
foreach lib_file $::env(LC_LIBS) {
  # The library name is the argument of the top-level `library (...)` group.
  set fh [open $lib_file r]
  set head [read $fh 20000]
  close $fh
  if {![regexp {library\s*\(\s*"?([^")\s]+)"?\s*\)} $head -> lib_name]} {
    puts "ERROR: no library() header in $lib_file"
    exit 1
  }
  set db_file [file join $out_dir "[file rootname [file tail $lib_file]].db"]
  puts "INFO: $lib_file -> $db_file ($lib_name)"
  read_lib $lib_file
  write_lib $lib_name -format db -output $db_file
  remove_lib $lib_name
}
exit
