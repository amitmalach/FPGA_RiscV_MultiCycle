# Firmware

The demo programs and everything that builds them for the SoC, with
`riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32`.

A program runs in one of two boot modes. In BRAM boot it is built into `rtl/firmware.hex`,
which synthesis bakes into the bitstream, and it runs from the SoC's 6 KB of RAM. In flash
boot it is written to the board's flash and runs from there, which admits programs larger than
the RAM. The same sources build for either; `TARGET` picks the mode. Build outputs go to
`build/`, which is not tracked.

## Where to start reading

1. `io.h`: the IO addresses a program writes to light the LEDs or send a byte.
2. `mandelbrot.c`: the demo in the committed image, plain C over `printf`.
3. `start.S` and `bram.ld`: what runs before `main`, and where the code, data and stack sit
   in the RAM.
4. `start_spiflash.S` and `spiflash.ld`: the same for flash boot.

The root README, "Running the demos", loads a demo on the board.

## Files

| Path | What it is |
|---|---|
| `blinker.S`, `sieve.c`, `mandelbrot.c`, `riscv_logo.c`, `ST_NICCC.c`, `tinyraytracer.c` | The demos |
| `start.S`, `start_spiflash.S` | Start-up code, for BRAM boot and for flash boot |
| `bram.ld`, `spiflash.ld`, `memory.ld` | Linker scripts: one per boot mode, and the memory regions they share |
| `io.h`, `putchar.S`, `print.c`, `wait.S`, `memcpy.c`, `errno.c`, `stdio.h` | The small runtime the demos link against: the IO addresses, `putchar` and `printf`, a delay loop, `memcpy` and an `errno` stub |
| `tools/write_mcs.tcl` | Wraps a binary in an MCS file, the image Vivado writes to the flash, at a given offset |
| `tests/` | `check_memory_map.sh`, the firmware's copies of the memory map against `rtl/defines.vh`, and `check_reproducible.sh`, the committed image rebuilt from clean |

## Make targets

```sh
make                              # mandelbrot, BRAM boot: rewrites rtl/firmware.hex
make PROG=sieve                   # another demo, BRAM boot
make PROG=ST_NICCC TARGET=flash   # flash boot: build/<prog>.spiflash.{elf,bin,mcs}
make build/mandelbrot.s           # a demo's assembly, for the reader
make check                        # the memory-map copies, then the image rebuilt and compared
make clean
```

The header of `Makefile` lists the other targets and every variable.

A flash build runs Vivado's `write_cfgmem`, so it needs Vivado's `settings64.sh` sourced. The
committed image is always mandelbrot: after building another demo for BRAM boot, run `make`
again before committing, or `make check` fails. The root README, "Building the firmware",
lists the demos and the boot modes each builds for.
