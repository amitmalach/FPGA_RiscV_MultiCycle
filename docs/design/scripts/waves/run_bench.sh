#!/usr/bin/env bash
# Simulate WaveBench.v, the SoC with the committed firmware image, under iverilog and write
# <out_dir>/wave.vcd: the signals the final report's waveforms draw. Vivado's unisim models of
# IBUFDS, BUFG and STARTUPE2 come from the Vivado install, XILINX_VIVADO (set by settings64.sh)
# or else ~/Xilinx/2025.2/Vivado; nothing else of Vivado is needed.
#
#   docs/design/scripts/waves/run_bench.sh <out_dir> [+plusarg...]
#
# Runs in <out_dir> with a link to rtl/firmware.hex, which Memory.v reads by bare name, so
# nothing lands beside the sources. Plusargs go to the bench (+ns=<n>, +vcd=<file>).
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: run_bench.sh <out_dir> [+plusarg...]" >&2; exit 2; }
out=$1
shift
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
iverilog -g2005 -I "$root/rtl" -o "$out/WaveBench.vvp" "$here/WaveBench.v" "${rtl[@]}" \
    "$unisims/unisims/IBUFDS.v" "$unisims/unisims/BUFG.v" "$unisims/unisims/STARTUPE2.v" \
    "$unisims/glbl.v"
cd "$out"
vvp -n WaveBench.vvp "$@" > vvp.out
grep -v '^VCD info' vvp.out || true
