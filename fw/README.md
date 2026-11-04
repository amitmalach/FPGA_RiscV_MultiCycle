# Firmware

The demo programs and everything that builds them for the SoC, with
`riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32`.

| Path | What it is |
|---|---|
| `blinker.S`, `sieve.c`, `mandelbrot.c`, `riscv_logo.c`, `ST_NICCC.c`, `tinyraytracer.c` | The demos |
| `start.S`, `start_spiflash.S` | Start-up code, for BRAM boot and for flash boot |
| `bram.ld`, `spiflash.ld`, `memory.ld` | Linker scripts: one per boot mode, and the memory regions they share |
| `io.h`, `putchar.S`, `print.c`, `wait.S`, `memcpy.c`, `errno.c`, `stdio.h` | The small runtime the demos link against: the IO addresses, `putchar` and `printf`, a delay loop, `memcpy` and an `errno` stub |
| `tools/firmware_words_src/` | The ELF-to-hex converter that writes `rtl/firmware.hex` |
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

`make bram` and `make flash` are the two halves of the default target, which `TARGET` picks.
Other variables: `BUILD` (the output directory, default `build/`), `HEX_OUT` (where a BRAM-boot
image goes, default `../rtl/firmware.hex`), `RAM_SIZE`, `CROSS` (the toolchain prefix) and
`XILINX_RV32_ROOT` (the RISC-V newlib bundled with Vivado, for tinyraytracer's `libm`). The
header of `Makefile` explains each.

Demos: `blinker`, `sieve`, `mandelbrot`, `riscv_logo` and `ST_NICCC` build for either boot
mode, `tinyraytracer` for flash boot only (about 29 KB of code; the RAM holds 6 KB). A flash
build runs `write_cfgmem`, so it needs Vivado's `settings64.sh` sourced. The committed image is
always mandelbrot: after building another demo for BRAM boot, run `make` again before
committing, or `make check` fails.
