# Write the schematic of the worst setup path of a routed checkpoint, for the final report.
#
#   docs/design/scripts/vivado_xvfb.sh <scratch_dir> <this script> <post_route.dcp> <out_dir>
#   (make impl runs it this way, then crops the PDF with crop_pdf.sh)
#
# Writes <out_dir>/timing_worst_path.pdf, uncropped, then exits Vivado. Runs in the GUI, as
# rtl_schematics.tcl does: write_schematic writes nothing in batch mode. The schematic holds
# the path's pins as pin pairs, startpoint to endpoint, so each net shows only its segment on
# the path, not the rest of its fan-out. The checkpoint is opened from a copy in the scratch
# directory, so the original is never written. The steps are chained from the event loop:
# blocking right after open_checkpoint leaves the "Loading device" dialog up.

lassign $argv dcp out
set out [file normalize $out]

# Run each step in turn from the event loop, three seconds apart; any error ends the session
# with exit 1.
proc run_steps {steps} {
    if {![llength $steps]} { exit 0 }
    if {[catch {uplevel #0 [lindex $steps 0]} err]} {
        puts "FIGURE ERROR: $err"
        exit 1
    }
    after 3000 [list run_steps [lrange $steps 1 end]]
}

proc open_copy {} {
    global dcp
    set copy [file join [pwd] [file tail $dcp]]
    file copy -force $dcp $copy
    open_checkpoint $copy
}

proc show_path {} {
    set path [get_timing_paths -setup -max_paths 1 -nworst 1]
    show_schematic -pin_pairs [get_pins -of_objects $path]
    puts [format "FIGURE worst path %s -> %s, slack %s ns" [get_property STARTPOINT_PIN $path] \
          [get_property ENDPOINT_PIN $path] [get_property SLACK $path]]
}

proc write_pdf {} {
    global out
    file mkdir $out
    set pdf [file join $out timing_worst_path.pdf]
    file delete -force $pdf
    write_schematic -force -format pdf -orientation portrait -scope all $pdf
    if {![file exists $pdf]} { error "write_schematic wrote nothing to $pdf" }
    puts "FIGURE $pdf"
}

after 1000 [list run_steps {open_copy show_path write_pdf}]
