# Load a bitstream into the FPGA over JTAG, for the board captures of the final report.
#
#   cd <scratch_dir> && vivado -mode batch -nojournal -nolog -source <this script> \
#       -tclargs <bit> [<target>]
#   (docs/design/scripts/board_capture.sh runs it this way)
#
# The configuration flash is never touched: the design lives in the FPGA until the board is
# power-cycled, which boots whatever the flash holds. <target> picks the JTAG cable by name, a
# glob (default *); exactly one hardware target must match.

source [file join [file dirname [info script]] .. .. .. vivado common.tcl]
set bit [file normalize [lindex $argv 0]]
set pattern [arg_or 1 *]
if {![file exists $bit]} { error "BOARD no bitstream at $bit" }

open_hw_manager
connect_hw_server
set targets [get_hw_targets -quiet $pattern]
if {[llength $targets] != 1} { error "BOARD want one JTAG target matching '$pattern', found '$targets'" }
open_hw_target $targets

# Hardware devices are named after the part without package and speed grade: xc7k325t_0.
regexp {^xc7[a-z]\d+t} $part chip
set device [get_hw_devices -quiet ${chip}_*]
if {[llength $device] != 1} { error "BOARD want one $chip on the JTAG chain, found '$device'" }
current_hw_device $device
set_property PROGRAM.FILE $bit $device
# uart_capture.py starts recording at this line.
puts "BOARD loading $bit"
flush stdout
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
if {[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device] != 1} {
    error "BOARD DONE is low after programming"
}
puts "BOARD programmed $device over [get_property NAME $targets] with $bit"

close_hw_target
disconnect_hw_server
close_hw_manager
