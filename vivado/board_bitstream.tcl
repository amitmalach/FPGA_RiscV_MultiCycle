# Build a bitstream for the board in either boot mode, BRAM boot by default.
#
#   cd <out_dir> && vivado -mode batch -nojournal -nolog -source <this script> \
#       -tclargs <out_dir> [bram|flash]
#   (the root README, "Running the demos", gives the whole sequence)
#
# <out_dir> must hold a firmware image as firmware.hex: Memory.v reads it by bare name, against
# the working directory. Writes <out_dir>/SOC.bit, and errors out unless timing is met.
#
# Synthesis and implementation as in vivado/baseline.tcl, non-project. bram, the default, sets
# the SOC parameter BOOT_ADDR to BOOT_ADDR_BRAM, 0, as sim/bench.v sets it, so the core starts
# from the image in the RAM. flash keeps the SOC default, BOOT_ADDR_FLASH: the core starts from
# the flash's code offset, and the image in the RAM is never run. rtl/SOC.v and rtl/firmware.hex
# stay as they are.

source [file join [file dirname [info script]] common.tcl]
set out [file normalize [arg_or 0 [pwd]]]
set boot [arg_or 1 bram]
if {![file exists [file join $out firmware.hex]]} { error "BOARD no firmware.hex in $out" }

read_verilog $rtl_files
read_xdc $xdc
cd $out
switch -- $boot {
    bram  { synth_design -top SOC -part $part -generic BOOT_ADDR=32'h00000000 }
    flash { synth_design -top SOC -part $part }
    default { error "BOARD boot mode '$boot', want bram or flash" }
}
opt_design
place_design
route_design

lassign [timing_line BOARD] wns whs
if {$wns < 0 || $whs < 0} { error "BOARD timing not met" }
write_bitstream -force [file join $out SOC.bit]
puts "BOARD $boot-boot bitstream [file join $out SOC.bit]"
