# Read or write the board's SPI flash over JTAG, for the flash-boot captures of the final report.
#
#   cd <scratch_dir> && vivado -mode batch -nojournal -nolog -source <this script> \
#       -tclargs read <offset> <bytes> <out.bin> [<target>]
#   cd <scratch_dir> && vivado -mode batch -nojournal -nolog -source <this script> \
#       -tclargs write <flash_image.mcs> [<target>]
#   (docs/design/scripts/board_capture.sh runs read this way)
#
# Both first load Vivado's SPI programming core into the FPGA, which replaces the design running
# there until the next load or power cycle.
#
# read copies <bytes> bytes of the flash, from byte <offset>, into <out.bin>.
#
# write programs and verifies the bytes a flash image covers and nothing else, Hardware
# Manager's "Configuration File Only": on the owner's board, a readback of the whole chip after
# a write differed from the one before only in the image's bytes. It refuses an image with any
# byte outside FLASH_LO to FLASH_HI: below lies the configuration bitstream the board boots at
# power-on (on the owner's board, Digilent's factory demo), which no script here writes, and
# above, the SoC's flash window has ended (SPIFLASH_ADDR_W in rtl/defines.vh). The images it is
# meant for are the scene data at 0xC00000 and a demo at the code offset, 0xD00000, both built
# by fw/tools/write_mcs.tcl.
#
# write keeps the flash's non-volatile Quad Enable bit (S25FL256S configuration register 1,
# bit 1) with PROGRAM.SKIP_QE_BIT_ERASE. At that property's default, 0, a write cleared the
# bit, and a write with an SPIx4 .prm did not set it back. The bitstream the board
# boots at power-on reads the flash four bits wide (opcode 0x6C, Quad Output Read with a
# four-byte address, in its BSPI register) and needs the bit: without it the FPGA stalls in
# configuration, with no error flagged. On the owner's board one such write left the board
# unable to boot until docs/design/scripts/flashregs/FlashRegs.v set the bit again; that tool
# also reads the bit, which Vivado's Tcl has no command for.
#
# <target> picks the JTAG cable as in board_program.tcl. The part is the Genesys 2's S25FL256S
# as Digilent names it for Vivado; Vivado's width-specific names for this chip are for Zynq only.

source [file join [file dirname [info script]] board_jtag.tcl]
set FLASH_PART s25fl256sxxxxxx0-spi-x1_x2_x4
set FLASH_LO 0xC00000
set fh [open [file join $root rtl defines.vh]]
regexp -line {^`define\s+SPIFLASH_ADDR_W\s+(\d+)} [read $fh] -> addr_w
close $fh
set FLASH_HI [expr {(1 << $addr_w) - 1}]

# The lowest and highest byte address of the data records of an Intel HEX (.mcs) file.
proc mcs_range {mcs} {
    set lo -1
    set hi -1
    set upper 0
    set fh [open $mcs]
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line eq ""} continue
        if {![regexp {^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)$} \
                  $line -> count addr type data]} {
            close $fh
            error "BOARD $mcs: not an Intel HEX record: $line"
        }
        scan $count %x count
        scan $addr %x addr
        switch -- $type {
            00 {
                set first [expr {($upper << 16) + $addr}]
                set last [expr {$first + $count - 1}]
                if {$lo < 0 || $first < $lo} { set lo $first }
                if {$last > $hi} { set hi $last }
            }
            01 {}
            04 { scan [string range $data 0 3] %x upper }
            default {
                close $fh
                error "BOARD $mcs: record type $type, want 00, 01 or 04"
            }
        }
    }
    close $fh
    if {$lo < 0} { error "BOARD $mcs holds no data" }
    return [list $lo $hi]
}

# The flash as a configuration memory, with Vivado's SPI programming core loaded to reach it.
proc open_flash {device} {
    global FLASH_PART
    set mem [create_hw_cfgmem -hw_device $device [lindex [get_cfgmem_parts $FLASH_PART] 0]]
    create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
    program_hw_devices $device
    refresh_hw_device $device
    return $mem
}

set mode [lindex $argv 0]
switch -- $mode {
    read {
        if {[llength $argv] < 4} { error "BOARD read wants <offset> <bytes> <out.bin>" }
        lassign $argv - offset bytes out
        set out [file normalize $out]
        set mem [open_flash [board_open [arg_or 4 *]]]
        readback_hw_cfgmem -force -format bin -offset $offset -datacount $bytes -file $out $mem
        if {[file size $out] != $bytes} {
            error "BOARD read $bytes bytes from $offset, but $out holds [file size $out]"
        }
        puts [format "BOARD read 0x%06X to 0x%06X into %s" $offset \
                  [expr {$offset + $bytes - 1}] $out]
    }
    write {
        if {[llength $argv] < 2} { error "BOARD write wants <flash_image.mcs>" }
        set mcs [file normalize [lindex $argv 1]]
        lassign [mcs_range $mcs] lo hi
        if {$lo < $FLASH_LO || $hi > $FLASH_HI} {
            error [format "BOARD %s covers 0x%06X to 0x%06X; only 0x%06X to 0x%06X may be written" \
                       $mcs $lo $hi $FLASH_LO $FLASH_HI]
        }
        set mem [open_flash [board_open [arg_or 2 *]]]
        set_property PROGRAM.FILES [list $mcs] $mem
        set_property PROGRAM.ADDRESS_RANGE use_file $mem
        set_property PROGRAM.UNUSED_PIN_TERMINATION pull-none $mem
        set_property PROGRAM.BLANK_CHECK 0 $mem
        set_property PROGRAM.ERASE 1 $mem
        set_property PROGRAM.CFG_PROGRAM 1 $mem
        set_property PROGRAM.VERIFY 1 $mem
        set_property PROGRAM.CHECKSUM 0 $mem
        set_property PROGRAM.SKIP_QE_BIT_ERASE 1 $mem      ;# the header says why
        puts [format "BOARD writing 0x%06X to 0x%06X from %s" $lo $hi $mcs]
        program_hw_cfgmem $mem
        puts [format "BOARD wrote and verified 0x%06X to 0x%06X from %s" $lo $hi $mcs]
    }
    default { error "BOARD mode '$mode', want read or write" }
}
board_close
