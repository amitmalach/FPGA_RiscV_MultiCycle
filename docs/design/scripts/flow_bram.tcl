# Build the BRAM-boot bitstream and record the block RAMs' contents, for the C-to-board flow
# figure of the final report (chapter 8).
#
#   cd <out_dir> && vivado -mode batch -nojournal -nolog -source <this script> -tclargs <out_dir>
#   (make flow, in docs/design/, runs it this way)
#
# <out_dir> must hold the firmware image as firmware.hex. Runs board_bitstream.tcl in BRAM boot,
# its default, which writes <out_dir>/SOC.bit, then writes <out_dir>/bram_init.txt from the
# routed design: for each block RAM, a CELL line (name, primitive, port A's read width) and its
# INIT_xx properties, one a line. flow_excerpts.py reads it back.

source [file join [file dirname [info script]] board_bitstream.tcl]

set f [open [file join $out bram_init.txt] w]
foreach cell [lsort [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]] {
    puts $f "CELL $cell [get_property REF_NAME $cell] [get_property READ_WIDTH_A $cell]"
    foreach name [lsort [list_property $cell INIT_*]] {
        if {[regexp {^INIT_[0-9A-F]{2}$} $name]} { puts $f "$name [get_property $name $cell]" }
    }
}
close $f
puts "FLOW block RAM contents [file join $out bram_init.txt]"
