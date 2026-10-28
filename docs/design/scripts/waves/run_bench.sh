#!/usr/bin/env bash
# Simulate WaveBench.v, the SoC, under iverilog and write <out_dir>/wave.vcd: the signals the
# final report's waveforms draw. Vivado's unisim models of IBUFDS, BUFG and STARTUPE2 come
# from the Vivado install, XILINX_VIVADO (set by settings64.sh) or else ~/Xilinx/2025.2/Vivado;
# nothing else of Vivado is needed.
#
#   docs/design/scripts/waves/run_bench.sh <out_dir> [--flash <image.bin>] [+plusarg...]
#
# Without --flash, BRAM boot with the committed firmware image; with it, flash boot from the
# image, a .spiflash.bin from make -C fw TARGET=flash, which FlashImage.v holds at the code
# offset. Runs in <out_dir> with a link to rtl/firmware.hex, which Memory.v reads by bare
# name, so nothing lands beside the sources. Plusargs go to the bench (+ns=<n>, +vcd=<file>).
set -euo pipefail

usage() { echo "usage: run_bench.sh <out_dir> [--flash <image.bin>] [+plusarg...]" >&2; exit 2; }
[ $# -ge 1 ] || usage
out=$1
shift
image=
if [ "${1:-}" = --flash ]; then
    [ $# -ge 2 ] || usage
    image=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
    shift 2
fi
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../.." && pwd)
unisims=${XILINX_VIVADO:-$HOME/Xilinx/2025.2/Vivado}/data/verilog/src

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null || { echo "run_bench.sh: $tool not on PATH" >&2; exit 1; }
done
[ -f "$unisims/glbl.v" ] || {
    echo "run_bench.sh: no unisim models at $unisims; source Vivado's settings64.sh" >&2
    exit 1
}

rtl=()
while IFS= read -r line; do
    case "$line" in ''|'#'*|*.vh) continue ;; esac
    rtl+=("$root/$line")
done < "$root/vivado/rtl_sources.txt"

mkdir -p "$out"
ln -sf "$root/rtl/firmware.hex" "$out/firmware.hex"
boot=(-P WaveBench.FLASH_BOOT=0)
flash=()
if [ -n "$image" ]; then
    # One byte per line, as FlashImage reads it.
    od -An -v -tx1 -w1 "$image" | tr -d ' ' > "$out/flash.hex"
    boot=(-P WaveBench.FLASH_BOOT=1)
    flash=(+flash=flash.hex "+flash_bytes=$(stat -c %s "$image")")
fi
iverilog -g2005 -I "$root/rtl" "${boot[@]}" -o "$out/WaveBench.vvp" "$here/WaveBench.v" \
    "$here/FlashImage.v" "${rtl[@]}" "$unisims/unisims/IBUFDS.v" "$unisims/unisims/BUFG.v" \
    "$unisims/unisims/STARTUPE2.v" "$unisims/glbl.v"
cd "$out"
vvp -n WaveBench.vvp "${flash[@]}" "$@" > vvp.out
grep -v '^VCD info' vvp.out || true
