# Build a BRAM-boot bitstream for one demo, for the board captures of the final report.
#
#   cd <out_dir> && vivado -mode batch -nojournal -nolog -source <this script> -tclargs <out_dir>
#   (docs/design/scripts/board_capture.sh runs it this way)
#
# <out_dir> must hold the demo's firmware image as firmware.hex: Memory.v reads it by bare
# name, against the working directory. Writes <out_dir>/SOC.bit, and errors out unless timing
# is met.
#
# Synthesis and implementation as in vivado/baseline.tcl, non-project, but with the SOC
# parameter BOOT_ADDR set to BOOT_ADDR_BRAM, 0, as sim/bench.v sets it, so the core starts from
# the image in the RAM. rtl/SOC.v and rtl/firmware.hex stay as they are.

source [file join [file dirname [info script]] .. .. .. vivado common.tcl]
set out [file normalize [arg_or 0 [pwd]]]
if {![file exists [file join $out firmware.hex]]} { error "BOARD no firmware.hex in $out" }

read_verilog $rtl_files
read_xdc $xdc
cd $out
synth_design -top SOC -part $part -generic BOOT_ADDR=32'h00000000
opt_design
place_design
route_design

if {[timing_line BOARD] < 0} { error "BOARD timing not met" }
write_bitstream -force [file join $out SOC.bit]
puts "BOARD bitstream [file join $out SOC.bit]"
