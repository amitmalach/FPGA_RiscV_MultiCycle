# Write the RTL schematics of the SoC top level and of the ALU, for the final report.
#
#   docs/design/scripts/vivado_xvfb.sh <scratch_dir> <this script> <out_dir>
#   (make figures runs it this way, then crops both PDFs with crop_pdf.sh)
#
# Writes <out_dir>/rtl_soc.pdf and <out_dir>/rtl_alu.pdf, uncropped, then exits Vivado.
#
# Runs in the GUI: write_schematic exports the open schematic window and writes nothing in
# batch mode. The schematics come from the elaborated RTL (synth_design -rtl), not the
# synthesized netlist, where the ALU's logic is absorbed into the register file. The ALU is
# elaborated as its own top so that its ports frame the drawing. Each step returns to the
# event loop for a moment so the window is drawn before it is written.

source [file join [file dirname [info script]] .. .. .. vivado common.tcl]
set out [file normalize [arg_or 0 [pwd]]]

# Run each step in turn from the event loop, two seconds apart; any error ends the session
# with exit 1.
proc run_steps {steps} {
    if {![llength $steps]} { exit 0 }
    if {[catch {uplevel #0 [lindex $steps 0]} err]} {
        puts "FIGURE ERROR: $err"
        exit 1
    }
    after 2000 [list run_steps [lrange $steps 1 end]]
}

proc elaborate {top} {
    global part root
    if {[llength [get_designs -quiet]]} { close_design }
    synth_design -rtl -top $top -part $part -include_dirs [file join $root rtl]
    show_schematic [concat [get_cells] [get_ports]]
}

proc write_pdf {name} {
    global out
    set pdf [file join $out $name.pdf]
    file delete -force $pdf
    write_schematic -force -format pdf -orientation portrait -scope all $pdf
    if {![file exists $pdf]} { error "write_schematic wrote nothing to $pdf" }
    puts "FIGURE $pdf"
}

# Memory.v reads the firmware image by bare name, relative to the working directory, which
# vivado_xvfb.sh made the scratch directory.
file copy -force $hex [pwd]
file mkdir $out
read_verilog $rtl_files
after 1000 [list run_steps {
    {elaborate SOC}
    {write_pdf rtl_soc}
    {elaborate ALU}
    {write_pdf rtl_alu}
}]
