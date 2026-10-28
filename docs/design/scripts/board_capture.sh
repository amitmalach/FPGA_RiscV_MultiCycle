#!/usr/bin/env bash
# Capture a demo's UART output on the board, for the final report.
#
#   docs/design/scripts/board_capture.sh <demo> bram|flash <seconds> <out_base>
#   (make captures runs it for the demos in BRAM boot)
#
# bram: builds the demo's firmware image and a BRAM-boot bitstream in
# docs/design/build/board/<demo>/ (fw/Makefile with HEX_OUT there, then board_bitstream.tcl).
# flash: builds the demo's flash binary, fw/build/<demo>.spiflash.bin, reads as many bytes back
# from the flash's code offset (board_flash.tcl read) and stops unless they are equal, then builds
# a flash-boot bitstream in docs/design/build/board/flash/, with a copy of rtl/firmware.hex for
# Memory.v to read and the core never to run. The flash must already hold the demo:
# board_flash.tcl write puts it there, and this script never does. In flash boot the core prints
# nothing after configuration, most likely losing its first fetches: press the board's CPU
# RESET button once the load has ended, within <seconds> (docs/design/figures/README.md, "Board
# captures").
#
# Either way the bitstream is built only when the image, the RTL, the constraints or
# board_bitstream.tcl changed. Then loads it over JTAG with board_program.tcl, recording the UART
# meanwhile and <seconds> after it with uart_capture.py, into <out_base>.bin and <out_base>.times.
# rtl/firmware.hex is never written.
#
# UART_PORT (default: the one FT232R in /dev/serial/by-id, the board's USB-UART bridge) and
# JTAG_TARGET (default *, the one JTAG cable) pick the board. Needs Vivado's settings64.sh
# sourced, riscv64-unknown-elf-gcc and pyserial.
set -euo pipefail

[ $# = 4 ] && [[ $2 =~ ^(bram|flash)$ ]] \
    || { echo "usage: board_capture.sh <demo> bram|flash <seconds> <out_base>" >&2; exit 2; }
demo=$1 boot=$2 seconds=$3 out_base=$(realpath -m "$4")
scripts=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$scripts/../../.." && pwd)
VIVADO=${VIVADO:-vivado}
vivado_batch() { "$VIVADO" -mode batch -nojournal -nolog -source "$@"; }

command -v "$VIVADO" >/dev/null || { echo "board_capture.sh: $VIVADO not on PATH; source Vivado's settings64.sh" >&2; exit 1; }
if [ -z "${UART_PORT:-}" ]; then
    ports=(/dev/serial/by-id/usb-FTDI_FT232R_*)
    [ ${#ports[@]} = 1 ] && [ -e "${ports[0]}" ] \
        || { echo "board_capture.sh: want one FT232R in /dev/serial/by-id; set UART_PORT" >&2; exit 1; }
    UART_PORT=${ports[0]}
fi

# The image is replaced only when its contents change, so that an unchanged one keeps the
# bitstream built from it.
if [ "$boot" = bram ]; then
    work=$root/docs/design/build/board/$demo
    mkdir -p "$work"
    rm -f "$work/firmware.new.hex"
    make -s -C "$root/fw" PROG="$demo" HEX_OUT="$work/firmware.new.hex" > "$work/fw.out" 2>&1 \
        || { cat "$work/fw.out" >&2; exit 1; }
else
    work=$root/docs/design/build/board/flash
    mkdir -p "$work"
    cp "$root/rtl/firmware.hex" "$work/firmware.new.hex"
fi
cmp -s "$work/firmware.new.hex" "$work/firmware.hex" 2>/dev/null \
    || mv "$work/firmware.new.hex" "$work/firmware.hex"
rm -f "$work/firmware.new.hex"

if [ "$boot" = flash ]; then
    bin=$root/fw/build/$demo.spiflash.bin
    make -s -C "$root/fw" PROG="$demo" TARGET=flash "build/$demo.spiflash.bin" > "$work/fw.out" 2>&1 \
        || { cat "$work/fw.out" >&2; exit 1; }
    offset=$(sed -n "s/^\`define SPIFLASH_CODE_OFFSET *32'h\([0-9A-Fa-f]*\).*/0x\1/p" \
        "$root/rtl/defines.vh")
    echo "board_capture.sh: reading back the flash at $offset, log in $work/readback.out"
    (cd "$work" && vivado_batch "$scripts/board_flash.tcl" -tclargs read "$offset" \
        "$(stat -c %s "$bin")" "$work/readback.bin" "${JTAG_TARGET:-*}") > "$work/readback.out" \
        || { tail -n 20 "$work/readback.out" >&2; exit 1; }
    cmp -s "$bin" "$work/readback.bin" \
        || { echo "board_capture.sh: the flash at $offset does not hold $bin; write" \
                  "fw/build/$demo.spiflash.mcs with board_flash.tcl first" >&2; exit 1; }
    echo "board_capture.sh: the flash at $offset holds $bin"
    echo "board_capture.sh: once the load has ended, press CPU RESET to start $demo"
fi

mapfile -t rtl < <(grep -vE '^\s*(#|$)' "$root/vivado/rtl_sources.txt" | sed "s|^|$root/|")
inputs=("$work/firmware.hex" "${rtl[@]}" "$root/constraints/Genesys-2-Master.xdc"
        "$scripts/board_bitstream.tcl")
if [ ! -e "$work/SOC.bit" ] || [ -n "$(find "${inputs[@]}" -newer "$work/SOC.bit")" ]; then
    echo "board_capture.sh: building the $boot-boot bitstream, log in $work/build.out"
    (cd "$work" && vivado_batch "$scripts/board_bitstream.tcl" -tclargs "$work" "$boot") \
        > "$work/build.out" || { tail -n 20 "$work/build.out" >&2; exit 1; }
    grep '^BOARD' "$work/build.out"
fi

echo "board_capture.sh: loading $demo over JTAG and recording $UART_PORT, log in $work/program.out"
mkdir -p "$(dirname "$out_base")"
(cd "$work" && python3 "$scripts/uart_capture.py" "$UART_PORT" "$seconds" "$out_base" -- \
    "$VIVADO" -mode batch -nojournal -nolog -source "$scripts/board_program.tcl" \
    -tclargs "$work/SOC.bit" "${JTAG_TARGET:-*}") > "$work/program.out" 2>&1 \
    || { tail -n 20 "$work/program.out" >&2; exit 1; }
grep -E '^(BOARD|CAPTURE)' "$work/program.out"
