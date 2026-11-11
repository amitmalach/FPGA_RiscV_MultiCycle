# Baseline

The reference numbers of the design: the golden simulation trace and the synthesis and
implementation results, so a later change can show that behaviour, timing closure and
resource use are unchanged.

## Simulation golden trace

`sim/golden/mandelbrot_bram.txt`, produced by `make golden` with the committed mandelbrot
image in BRAM boot (`sim/README.md`). The testbench sets `SOC`'s `BOOT_ADDR` to 0; nothing
else differs from the synthesized design.

| | |
|---|---|
| Stop reason | `stop_leds`: LED register became 1, the mandelbrot frame counter after the first full frame |
| Cycles simulated | 206 292 808 (1.031 s at 200 MHz; 333 s wall time in xsim) |
| UART bytes | 11 014 (46 rows of 46 pixels, ANSI colour escapes) |
| LED changes | 1 (`LEDS 1031464038 01`) |

## Synthesis and implementation

`make baseline` (`vivado/baseline.tcl`, launched from `build/`), run on 2026-10-28 with
Vivado 2025.2 (build 6299465); since then the RTL, `rtl/firmware.hex` and the constraints have
changed only in comments. Part `xc7k325tffg900-2`, constraints `Genesys-2-Master.xdc` (200 MHz
`sys_clk_p`, 5.000 ns period). The script sets no parameter, so this is the flash-boot design
(`BOOT_ADDR_FLASH`) with `rtl/firmware.hex` in the RAM. Reports in `build/baseline/` (not
committed). Numbers from another run are only comparable when produced by the same script; a
project-mode run with different synthesis settings will not match.

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

This comparison is what exposed the arithmetic-shift bug behind an earlier golden trace
(`docs/design/notes.md`, "SRL versus SRA: both shift arms are signed").
