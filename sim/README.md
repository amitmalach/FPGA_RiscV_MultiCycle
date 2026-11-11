# Simulation

How the design is checked in simulation, before it reaches the board.

| Path | What it is |
|---|---|
| `bench.v` | The SoC testbench: runs `SOC` in BRAM boot and writes what an outside observer sees to a trace |
| `golden/mandelbrot_bram.txt` | The golden trace: the UART bytes and LED changes of one mandelbrot frame |
| `run_regression.sh` | Simulates the SoC in xsim and passes only when the trace equals the golden one |
| `ALUBench.v`, `run_unit.sh` | The ALU unit bench and the script that runs it under iverilog |
| `WaveBench.v`, `FlashImage.v`, `run_waves.sh` | The waveform bench behind the final report's waveforms, with a model of the flash's read command, and the script that runs it |
| `tests/check_golden_mirror.sh` | Holds `docs/baseline.md`'s trace numbers equal to the golden trace; `make lint` runs it |
| `build/` | Simulation outputs; not tracked |

The root `Makefile` runs the scripts as gates: `make unit`, `make smoke` (a short run after an
RTL edit), `make check-sim` (part of `make check`) and `make golden`. The final report, chapter
"Verification", gives the whole picture. To run the regression by hand:

```sh
source <vivado-install>/settings64.sh   # xvlog, xelab and xsim on PATH
sim/run_regression.sh                   # PASS / FAIL, exit 0 / 1
```

A full run simulates one mandelbrot frame; `docs/baseline.md` gives its cycle count and wall
time.

## What is compared

`bench.v` writes one line per event to a trace file:

| Line | Meaning |
|---|---|
| `UART <hex>` | one byte decoded from the FPGA-to-PC UART line (115200 8N1) |
| `LEDS <time_ns> <hex>` | the LED register changed, with the simulation time in ns |
| `END <reason> cycles=<n> uart_bytes=<n> leds=<hex>` | why and when the run stopped |

Pass means the new trace is byte-identical to the golden one: the same UART bytes in the same
order, the same LED changes at the same times, the same total cycle count. The cycle count
makes the gate stricter than "same bytes": a change that alters instruction timing fails even
when the visible output does not. The testbench reads no internal signals, so the RTL can be
restructured without touching it.

To read the UART output as text:

```sh
grep '^UART' sim/golden/mandelbrot_bram.txt | cut -d' ' -f2 | xxd -r -p
```

## Boot mode and firmware

There is no SPI-flash model, so the testbench instantiates `SOC #(.BOOT_ADDR(0))`, BRAM boot.
`run_regression.sh` links the committed image, `rtl/firmware.hex`, into `sim/build/` and runs
xsim there, where the RAM's `$readmemh` finds it.

## Stop conditions

The run ends at whichever comes first:

- the LED register becomes `STOP_LEDS` (default 1; negative disables this condition).
  mandelbrot writes its frame counter to the LEDs at the top of every frame, so this marks the
  end of the first complete frame. A UART byte still in flight at that instant is not
  recorded; in the golden run the last byte finishes before the LED write;
- `MAX_CYCLES` clock cycles (default 400 M, 2 s simulated).

Both are testbench parameters, overridden with plusargs (`+out=`, `+max_cycles=`,
`+stop_leds=`; in xsim `-testplusarg "max_cycles=4000000"`). `run_regression.sh --max-cycles N`
passes a budget through, and `make smoke` passes `SMOKE_CYCLES` from the root `Makefile`. A
truncated trace cannot equal the golden file, so a smoke run checks instead that every event it
recorded is a prefix of the golden event list.

## Updating the golden file

Only when a behaviour change is intended. `make golden` runs
`sim/run_regression.sh --update-golden`, which overwrites the golden trace with the new run,
and logs it like the other gates. Commit the trace with the RTL change and the reason for it,
and update the trace numbers in `docs/baseline.md`, which lint rule 9 holds to the golden file.

## ALU unit bench

`ALUBench.v` drives the ports of `rtl/ALU.v` directly and checks the right shifts (SRL, SRA,
SRLI, SRAI; shift amounts 0, 4, 9 and 31; upper operand bits ignored) against results worked
out by hand from the RV32I specification. `run_unit.sh`, or `make unit`, compiles it under
iverilog into `build/unit/` and passes only when the bench prints its final `PASS` line. It
covers what the golden trace cannot: the golden file records what the RTL did when it was
captured, right or wrong.

## Waveforms

`WaveBench.v` drives the SoC as `bench.v` does and dumps the signals the final report's
waveforms draw to a VCD file. Nothing is checked and no gate runs it. Unlike `bench.v` it also
runs flash boot: `FlashImage.v` answers the flash's Read command from a flash-boot image, and
Vivado's `STARTUPE2` model drives the flash clock, so the first transaction after configuration
loses clock edges (the report's section "CCLK and STARTUPE2"). `run_waves.sh` runs it under
iverilog with Vivado's unisim models:

```sh
sim/run_waves.sh sim/build/waves/bram                       # BRAM boot, 3000 ns
make -C fw build/mandelbrot.spiflash.bin
sim/run_waves.sh sim/build/waves/flash --flash fw/build/mandelbrot.spiflash.bin +ns=6000
```

Each run writes `wave.vcd` into the given directory; GTKWave opens it.
