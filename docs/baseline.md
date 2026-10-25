# Baseline

The reference the gates compare against: the golden simulation trace and the synthesis
and implementation numbers of the design, so any later change can show that behavior,
timing closure and resource use are unchanged.

## Simulation golden trace

`sim/golden/mandelbrot_bram.txt`, produced by `make golden`
with the committed mandelbrot firmware image in BRAM boot. See `sim/README.md`.

The testbench overrides the `BOOT_ADDR` parameter of `rtl/SOC.v` with 0 to select BRAM
boot; nothing else differs from the synthesized design.

| | |
|---|---|
| Stop reason | `stop_leds`: LED register became 1, the mandelbrot frame counter after the first full frame |
| Cycles simulated | 206 292 808 (1.031 s at 200 MHz; 333 s wall time in xsim) |
| UART bytes | 11 014 (46 rows of 46 pixels, ANSI colour escapes) |
| LED changes | 1 (`LEDS 1031464038 01`) |

## Synthesis and implementation

`make baseline` (`vivado/baseline.tcl`, launched from `build/`), Vivado 2025.2,
part `xc7k325tffg900-2`, constraints `Genesys-2-Master.xdc` (200 MHz `sys_clk_p`,
5.000 ns period). Reports in `build/baseline/` (not committed). Numbers from another
run are only comparable when produced by the same script; a project-mode run with
different synthesis settings will not match.

| | |
|---|---|
| Timing | met (0 failing endpoints of 1229 setup / 1229 hold) |
| WNS | 0.219 ns |
| WHS | 0.113 ns |
| Fmax (1 / (period - WNS)) | 209.2 MHz |
| Slice LUTs | 984 of 203800 (0.48 %) |
| Slice registers | 244 of 407600 (0.06 %) |
| Block RAM tiles | 2 of 445 (0.45 %) |
| DSPs | 0 |
| Bonded IOBs | 15 |

## The golden frame against the C source

The golden frame is also what the C source means: `fw/mandelbrot.c` compiled natively
emits a first frame byte-identical to the UART bytes of the golden trace.
The native program draws frames forever, so the golden bytes are a prefix of its output,
and the next native bytes, `ESC [ H`, start the second frame:

```sh
gcc -O2 -w '-DIO_OUT(a,b)=' -o /tmp/mandel fw/mandelbrot.c
grep '^UART' sim/golden/mandelbrot_bram.txt | cut -d' ' -f2 | xxd -r -p > /tmp/sim.bin
n=$(stat -c %s /tmp/sim.bin)
timeout 1 /tmp/mandel | head -c $((n + 3)) | cmp /tmp/sim.bin -  # EOF on sim.bin after byte $n
```

An earlier golden trace recorded 8368 bytes, diverging at row 8, pixel 36: `srai` behaved
as `srli` (`-1544416 >> 9` yielded `0x007FF437`, expected `0xFFFFF437`), because the
unsigned else-arm of the ALU's shift expression made `>>>` shift logically (issue #10;
`docs/design/notes.md`, "SRL versus SRA, as the comment described it"). The trace was
re-captured with the fix, and `sim/ALUBench.v` now checks the shifts directly. The fix
also gave the shifter its sign fill: Slice LUTs went from 930 to 984, and timing stayed met.
