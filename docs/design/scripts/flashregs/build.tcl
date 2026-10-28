# Build FlashRegs, the flash register tool, for the board.
#
#   cd <out_dir> && vivado -mode batch -nojournal -nolog -source <this script> -tclargs [0|1]
#
# 0 (the default) builds the read-only tool, 1 the one that also writes the registers once
# (FlashRegs.v, WRITE_REGS). Writes <out_dir>/FlashRegs_w<0|1>.bit. Synthesis and
# implementation as in vivado/baseline.tcl, with the SoC's constraints: the tool uses the
# SoC's clock, reset, LED, UART and flash pins, under the same port names.

source [file join [file dirname [info script]] .. .. .. .. vivado common.tcl]
set src [file dirname [file normalize [info script]]]
set out [pwd]
set write_regs [arg_or 0 0]
read_verilog [list [file join $src FlashRegs.v] [file join $root rtl Clockworks.v] \
                   [file join $root rtl UartTx.v]]
read_xdc $xdc
synth_design -top FlashRegs -part $part -generic WRITE_REGS=$write_regs
opt_design
place_design
route_design
if {[timing_line BOARD] < 0} { error "BOARD timing not met" }
write_bitstream -force [file join $out FlashRegs_w$write_regs.bit]
puts "BOARD FlashRegs WRITE_REGS=$write_regs bitstream [file join $out FlashRegs_w$write_regs.bit]"
