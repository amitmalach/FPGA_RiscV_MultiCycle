# Open the board's FPGA over JTAG: sourced by board_program.tcl and board_flash.tcl.
# Sources vivado/common.tcl, so a script that sources this one also has root, part and arg_or.
#
# board_open <target> connects to the local hardware server, opens the one JTAG cable whose name
# matches the glob <target>, makes the FPGA on its chain the current hardware device and returns
# it. board_close undoes it.

source [file join [file dirname [info script]] .. .. .. vivado common.tcl]

proc board_open {pattern} {
    global part
    open_hw_manager
    connect_hw_server
    set targets [get_hw_targets -quiet $pattern]
    if {[llength $targets] != 1} {
        error "BOARD want one JTAG target matching '$pattern', found '$targets'"
    }
    open_hw_target $targets

    # Hardware devices are named after the part without package and speed grade: xc7k325t_0.
    regexp {^xc7[a-z]\d+t} $part chip
    set device [get_hw_devices -quiet ${chip}_*]
    if {[llength $device] != 1} { error "BOARD want one $chip on the JTAG chain, found '$device'" }
    current_hw_device $device
    return $device
}

proc board_close {} {
    close_hw_target
    disconnect_hw_server
    close_hw_manager
}
