# Write the report data behind chapter 10 of the final report, from a routed checkpoint.
#
#   cd <scratch_dir> && vivado -mode batch -nojournal -nolog \
#       -source docs/design/scripts/impl_reports.tcl -tclargs <post_route.dcp> <out_dir>
#   (make impl runs it this way, on the checkpoint vivado/baseline.tcl writes, then
#   impl_results.py turns the data into figures/impl_results.tex)
#
# Opens a copy of the checkpoint, so the original is never written, and writes to <out_dir>:
#   utilization.rpt  report_utilization -hierarchical, every instance (small modules are
#                    hidden unless -hierarchical_min_primitive_count is 0)
#   power.rpt        report_power, vectorless, at Vivado's default toggle rates
#   worst_path.txt   the worst setup path's properties, one "<name> <value>" line each
#   endpoints.txt    the worst setup slack of every timed endpoint, one "<ns> <levels>" line each
#   summary.txt      WNS, WHS and the setup and hold endpoint counts, as worst_path.txt

lassign $argv dcp out
set out [file normalize $out]
file mkdir $out

set copy [file join [pwd] [file tail $dcp]]
file copy -force $dcp $copy
open_checkpoint $copy

report_utilization -hierarchical -hierarchical_min_primitive_count 0 \
    -file [file join $out utilization.rpt]
report_power -file [file join $out power.rpt]

proc write_lines {file lines} {
    set fh [open $file w]
    puts $fh [join $lines "\n"]
    close $fh
}

# One path per endpoint, worst first: -nworst 1 keeps the worst path to each, and -max_paths
# is far above the design's endpoint count. The first setup path is the worst of the design.
set setup [get_timing_paths -setup -max_paths 100000 -nworst 1]
set hold  [get_timing_paths -hold  -max_paths 100000 -nworst 1]
set path  [lindex $setup 0]
set lines {}
foreach prop {SLACK REQUIREMENT DATAPATH_DELAY DATAPATH_LOGIC_DELAY DATAPATH_NET_DELAY
              LOGIC_LEVELS SKEW STARTPOINT_PIN ENDPOINT_PIN} {
    lappend lines "$prop [get_property $prop $path]"
}
# The cells along the path, startpoint to endpoint, each with its library cell: taken from the
# path's pins, which come in path order, each cell once.
set cells {}
foreach pin [get_pins -of_objects $path] {
    set cell [get_cells -of_objects $pin]
    if {$cell ne [lindex $cells end]} { lappend cells $cell }
}
foreach cell $cells {
    lappend lines "CELL $cell [get_property REF_NAME $cell]"
}
write_lines [file join $out worst_path.txt] $lines

set lines {}
foreach p $setup {
    lappend lines "[get_property SLACK $p] [get_property LOGIC_LEVELS $p]"
}
write_lines [file join $out endpoints.txt] $lines

write_lines [file join $out summary.txt] [list \
    "WNS [get_property SLACK [lindex $setup 0]]" \
    "WHS [get_property SLACK [lindex $hold 0]]" \
    "SETUP_ENDPOINTS [llength $setup]" \
    "HOLD_ENDPOINTS [llength $hold]" \
    "PERIOD [get_property PERIOD [get_clocks sys_clk_p]]" \
    "VIVADO [version -short]"]
puts "IMPL reports in $out"
