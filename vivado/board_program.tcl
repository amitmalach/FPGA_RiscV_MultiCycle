# Load a bitstream into the FPGA over JTAG.
#
#   cd <scratch_dir> && vivado -mode batch -nojournal -nolog -source <this script> \
#       -tclargs <bit> [<target>]
#
# The configuration flash is never touched: the design lives in the FPGA until the board is
# power-cycled, which boots whatever the flash holds. <target> picks the JTAG cable by name, a
# glob (default *); exactly one hardware target must match.

source [file join [file dirname [info script]] board_jtag.tcl]
set bit [file normalize [lindex $argv 0]]
if {![file exists $bit]} { error "BOARD no bitstream at $bit" }

set device [board_open [arg_or 1 *]]
set_property PROGRAM.FILE $bit $device
# Printed and flushed before the load, so a tool reading this output knows when it starts.
puts "BOARD loading $bit"
flush stdout
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
if {[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device] != 1} {
    error "BOARD DONE is low after programming"
}
puts "BOARD programmed $device over [get_property NAME [current_hw_target]] with $bit"
board_close
