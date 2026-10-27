#!/usr/bin/env bash
# Capture a demo's UART output on the board, in BRAM boot, for the final report.
#
#   docs/design/scripts/board_capture.sh <demo> <seconds> <out_base>
#   (make captures runs it for mandelbrot and riscv_logo)
#
# Builds the demo's firmware image and a BRAM-boot bitstream in docs/design/build/board/<demo>/
# (fw/Makefile with HEX_OUT there, then board_bitstream.tcl; the bitstream only when the image,
# the RTL, the constraints or board_bitstream.tcl changed). Then loads the bitstream over JTAG
# with board_program.tcl, recording the UART meanwhile and <seconds> after it with
# uart_capture.py, into <out_base>.bin and <out_base>.times. rtl/firmware.hex and the flash are
# never written.
#
# UART_PORT (default: the one FT232R in /dev/serial/by-id, the board's USB-UART bridge) and
# JTAG_TARGET (default *, the one JTAG cable) pick the board. Needs Vivado's settings64.sh
# sourced, riscv64-unknown-elf-gcc and pyserial.
set -euo pipefail

[ $# = 3 ] || { echo "usage: board_capture.sh <demo> <seconds> <out_base>" >&2; exit 2; }
demo=$1 seconds=$2 out_base=$(realpath -m "$3")
scripts=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$scripts/../../.." && pwd)
work=$root/docs/design/build/board/$demo
VIVADO=${VIVADO:-vivado}

command -v "$VIVADO" >/dev/null || { echo "board_capture.sh: $VIVADO not on PATH; source Vivado's settings64.sh" >&2; exit 1; }
if [ -z "${UART_PORT:-}" ]; then
    ports=(/dev/serial/by-id/usb-FTDI_FT232R_*)
    [ ${#ports[@]} = 1 ] && [ -e "${ports[0]}" ] \
        || { echo "board_capture.sh: want one FT232R in /dev/serial/by-id; set UART_PORT" >&2; exit 1; }
    UART_PORT=${ports[0]}
fi

# The image is replaced only when its contents change, so that an unchanged one keeps the
# bitstream built from it.
mkdir -p "$work"
rm -f "$work/firmware.new.hex"
make -s -C "$root/fw" PROG="$demo" HEX_OUT="$work/firmware.new.hex" > "$work/fw.out" 2>&1 \
    || { cat "$work/fw.out" >&2; exit 1; }
cmp -s "$work/firmware.new.hex" "$work/firmware.hex" 2>/dev/null \
    || mv "$work/firmware.new.hex" "$work/firmware.hex"
rm -f "$work/firmware.new.hex"

mapfile -t rtl < <(grep -vE '^\s*(#|$)' "$root/vivado/rtl_sources.txt" | sed "s|^|$root/|")
inputs=("$work/firmware.hex" "${rtl[@]}" "$root/constraints/Genesys-2-Master.xdc"
        "$scripts/board_bitstream.tcl")
if [ ! -e "$work/SOC.bit" ] || [ -n "$(find "${inputs[@]}" -newer "$work/SOC.bit")" ]; then
    echo "board_capture.sh: building the $demo bitstream, log in $work/build.out"
    (cd "$work" && "$VIVADO" -mode batch -nojournal -nolog \
        -source "$scripts/board_bitstream.tcl" -tclargs "$work") > "$work/build.out" \
        || { tail -n 20 "$work/build.out" >&2; exit 1; }
    grep '^BOARD' "$work/build.out"
fi

echo "board_capture.sh: loading $demo over JTAG and recording $UART_PORT, log in $work/program.out"
mkdir -p "$(dirname "$out_base")"
(cd "$work" && python3 "$scripts/uart_capture.py" "$UART_PORT" "$seconds" "$out_base" -- \
    "$VIVADO" -mode batch -nojournal -nolog -source "$scripts/board_program.tcl" \
    -tclargs "$work/SOC.bit" "${JTAG_TARGET:-*}") > "$work/program.out" 2>&1 \
    || { tail -n 20 "$work/program.out" >&2; exit 1; }
grep -E '^(BOARD|CAPTURE)' "$work/program.out"
