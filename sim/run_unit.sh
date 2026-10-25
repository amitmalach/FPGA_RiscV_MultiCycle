#!/usr/bin/env bash
# ALU unit bench. Simulates sim/ALUBench.v against rtl/ALU.v under iverilog
# and passes only when the bench prints its PASS line, so a bench that never
# reached the end fails too.
#
#   sim/run_unit.sh
#
# Exit status 0 on a pass, 1 on a mismatch or compile error, 2 when iverilog
# is missing. Needs no Vivado.
set -euo pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SIM_DIR/.." && pwd)"
# Not sim/build/: run_regression.sh deletes it, and make -j2 check runs both.
BUILD="$ROOT/build/unit"

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH" >&2; exit 2; }
done

mkdir -p "$BUILD"
echo "== ALUBench"
# iverilog exits with its error count, which could read as 2 (tool missing).
iverilog -g2001 -Wall -I "$ROOT/rtl" -o "$BUILD/ALUBench.vvp" \
    "$SIM_DIR/ALUBench.v" "$ROOT/rtl/ALU.v" \
    || { echo "FAIL: iverilog"; exit 1; }
vvp -n "$BUILD/ALUBench.vvp" | tee "$BUILD/ALUBench.out"
grep -q '^PASS: ALUBench' "$BUILD/ALUBench.out"
