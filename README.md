# Multi-cycle RV32I SoC on the Digilent Genesys 2

A small RISC-V system on chip written in plain Verilog-2001 and built with Vivado for the
Digilent Genesys 2 board (Kintex-7 `xc7k325tffg900-2`). The core is a multi-cycle RV32I
processor: each instruction walks through a few FSM states, one per clock. Around it sit 6 KB
of block RAM, a memory-mapped LED register, a UART transmitter and an SPI-flash read
controller that lets programs larger than the RAM execute in place from the board's flash.

Undergraduate project by Amit Malach, supervised by Prof. Avi Mendelson, Technion.

## Contents

- [Purpose](#purpose)
- [Board and tools](#board-and-tools)
- [Block diagram](#block-diagram)
- [Memory map](#memory-map)
- [Repository layout](#repository-layout)
- [Building the firmware](#building-the-firmware)
- [Building the bitstream](#building-the-bitstream)
- [Running the demos](#running-the-demos)
- [Simulation and checks](#simulation-and-checks)
- [Final report](#final-report)
- [Results](#results)
- [License](#license)

## Purpose

The project exists to build a complete, working computer from the gate level up and to
understand every piece of it: the instruction set, the bus between core and memory, how
peripherals appear as addresses, how a C toolchain targets bare metal, and how a program can
boot from serial flash. The design is deliberately small so that every module fits in one
screen and the whole system can be read in an afternoon. It is not a performance design.

What it does, concretely:

- executes the RV32I base integer instruction set (no multiply or divide, no CSRs;
  `ebreak` and `ecall` halt the core);
- boots either from the on-chip RAM, with the program baked into the bitstream, or from
  the on-board SPI flash;
- talks to the outside world through eight LEDs and a 115200 baud UART;
- runs a handful of demo programs written in C and assembly, from a blinker to a ray tracer.

## Board and tools

| Item | Value |
|---|---|
| Board | Digilent Genesys 2 (Kintex-7 `xc7k325tffg900-2`, 200 MHz differential system clock) |
| On-board flash | 32 MB SPI NOR (S25FL256S), shared between the bitstream, demo data and program code |
| UART | On-board USB-UART bridge, 115200 baud, 8N1, transmit only |
| FPGA tools | Vivado, version TODO (the scripts were written against 2025.2; confirm the version used for the final bitstream) |
| RISC-V toolchain | `riscv64-unknown-elf-gcc` with `-march=rv32i -mabi=ilp32` (a 64-bit-named toolchain builds RV32I code); the committed firmware image reproduces with GCC 13.2.0 |
| Host tools | GNU make, a C++ compiler for the ELF-to-hex converter, `pdflatex` for the final report |
| Simulators | xsim (installed with Vivado) and Icarus Verilog; the root `Makefile` header says which gate needs which |

## Block diagram

Everything lives in one clock domain, the 200 MHz system clock. Derived from `rtl/SOC.v`.

```
  sysclk_p/n --> IBUFDS --> BUFG --> clk (every block)
  RESET (button, active-low) --> Clockworks --> clk_enable (core, bus, RAM)
                                                 reset_n    (core, bus, UART)

  +-----------------------------+   mem_addr   mem_rdata   mem_rstrb
  | Processor (RV32I,           |   mem_wdata  mem_wmask   mem_rbusy
  | multi-cycle)                |<===================================+
  |   Decoder  ALU              |                                    |
  |   RegisterFile  Control     |                                    |
  +-----------------------------+                                    v
                                                     +-------------------+
                                                     | IOBus             |
                                                     | address decode    |
                                                     | LED register -----+--> LEDS[7:0]
                                                     | read-data mux     |
                                                     +---+------+------+-+
                             RAM region                  |      |      |   flash region
                 +---------------------------------------+      |      +--------------+
                 v                                    IO region |                     v
     +------------------+                          +------------v-----+   +-------------------+
     | Memory           |                          | UartTx           |   | SPIFlash          |
     | 6 KB block RAM   |                          | 8N1, 115200 baud |   | 03h read, 32 bit  |
     | loads            |                          +--------+---------+   | SPI clk = clk / 6 |
     | firmware.hex     |                                   |             +----+---------+----+
     +------------------+                             uart_rx_out              |         |
                                                    (the PC's RX)     csn, mosi, miso    |
                                                                                STARTUPE2 --> CCLK
```

The core sees one bus. A read is requested with `mem_rstrb` and answered on `mem_rdata` the
next cycle; a write happens on the edge where `mem_wmask` is non-zero, one bit per byte lane.
Only the flash controller stalls the core, by raising `mem_rbusy` for the length of an SPI
transaction. RAM and IO never stall. The bus has no acknowledge, and every address falls in
some region: RAM is the default when neither region bit is set.

The SPI clock cannot be driven from user logic on a 7-series part: the CCLK pin is a dedicated
configuration pin, so the flash controller's clock passes through the `STARTUPE2` primitive.

## Memory map

Defined once, in `rtl/defines.vh`; the firmware and the addresses in the tables below carry
copies that a lint rule holds equal.
A region is selected by a single address bit, so no address comparator is needed.

| Byte address | Region | Select | Access |
|---|---|---|---|
| `0x0000_0000` to `0x0000_17FF` | RAM, 6 KB (1536 words), holds code, data and stack in BRAM boot | no region bit set | read, write, fetch |
| `0x0040_0004` | `IO_LEDS`: LED register | bit 22 | write |
| `0x0040_0008` | `IO_UART_DAT`: send one byte | bit 22 | write |
| `0x0040_0010` | `IO_UART_CNTL`: UART status, bit 9 = transmitter busy | bit 22 | read |
| `0x0100_0000` to `0x01FF_FFFF` | SPI flash, a 16 MB window onto the chip | bit 24 | read, fetch |

Inside the IO region each register also owns one address bit (bits 2, 3 and 4), so a store to
`IO_BASE + 4` lights the LEDs and a store to `IO_BASE + 8` sends a byte. Firmware waits on
bit 9 of the status word before sending the next byte. The LED and UART data registers read
as zero.

Reset vector:

| Boot mode | Reset vector | Program location |
|---|---|---|
| BRAM boot | `0x0000_0000` | `rtl/firmware.hex`, loaded into the RAM when the bitstream is built |
| Flash boot (default) | `0x01D0_0000` | SPI flash, 13 MB into the chip (`SPIFLASH_CODE_OFFSET`), 3 MB available |

The flash code offset is forced by what already occupies the chip: the FPGA bitstream from
`0x000000` (about 10.9 MB on this part), the ST-NICCC scene data at `0xC00000` (640 KB), then
the program code at `0xD00000`, 64 KB sector aligned. The window ends at 16 MB because the
controller sends a 24-bit address.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Synthesizable Verilog, one module per file: `SOC.v` (top), `Processor.v` with `Decoder.v`, `ALU.v`, `RegisterFile.v`, `Control.v`; `IOBus.v`, `Memory.v`, `UartTx.v`, `SPIFlash.v`, `Clockworks.v`; `defines.vh` (memory map, widths); `firmware.hex` (the one committed firmware image) |
| `fw/` | Demo programs, startup code, linker scripts, `Makefile`, the ELF-to-hex converter and `write_mcs.tcl` |
| `sim/` | SoC-level testbench, golden trace, regression script; `ALUBench.v`, the ALU unit bench, and `run_unit.sh`; `sim/asm/` is a Verilog-macro assembler for test programs |
| `constraints/` | `Genesys-2-Master.xdc`: pins and the 200 MHz clock |
| `vivado/` | Tcl scripts: regenerate the project, build the bitstream, run the non-project baseline, with `common.tcl` shared by all three; `rtl_sources.txt` is the file list every script shares |
| `docs/` | `CONTRIBUTING.md` (coding conventions), `baseline.md` (baseline trace and synthesis numbers), `design/` (final report sources, figures and their scripts, design notes, and `scripts/flashregs/`, a small FPGA design that reads and sets the flash's Quad Enable bit) |
| `scripts/` | `lint.sh`, the pre-commit hook that runs it, the commit-msg hook that checks cited gate logs, and `quote_comment.sh` for moving RTL comments into the design notes |
| `build/` | Everything generated: the Vivado project, run directories, `SOC.bit`, gate logs. Not tracked |

The Vivado project is never committed. `vivado/create_project.tcl` regenerates it into
`build/vivado/` from the plain source tree, referencing the files in place.

## Building the firmware

```sh
make -C fw                                 # mandelbrot, BRAM boot: rewrites rtl/firmware.hex
make -C fw PROG=sieve                      # another demo, BRAM boot
make -C fw PROG=ST_NICCC TARGET=flash      # flash boot: fw/build/ST_NICCC.spiflash.{elf,bin,mcs}
make -C fw check                           # the committed image is reproducible from source
make -C fw clean
```

`TARGET=bram` links the program into the 6 KB RAM and writes `rtl/firmware.hex`, the only
firmware image in the tree; the RAM module reads it when the design is synthesized or
simulated. `TARGET=flash` links the program against the flash window, writes a flat binary
and wraps it in a `.mcs` file placed at the code offset; this last step runs Vivado's
`write_cfgmem`. The committed image is always the mandelbrot demo. After building another
demo for BRAM boot, run `make -C fw` again before committing, or `make -C fw check` will fail.

The flash-boot startup code copies `.data`, the libgcc multiply and divide routines and the
UART output path from flash into RAM before `main`, because every instruction fetched from
flash costs a 64-clock SPI transaction (about 2 µs) against one 5 ns cycle from BRAM.

Demos and where they fit:

| Demo | Source | Output | Boot modes | Run on the board |
|---|---|---|---|---|
| `blinker` | `fw/blinker.S` | LED pattern | BRAM, flash | BRAM boot |
| `sieve` | `fw/sieve.c` | prime numbers on the UART | BRAM, flash | BRAM boot |
| `mandelbrot` | `fw/mandelbrot.c` | 46 by 46 Mandelbrot set in ANSI colour on the UART; frame counter on the LEDs | BRAM, flash | BRAM boot |
| `riscv_logo` | `fw/riscv_logo.c` | rotating RISC-V logo on the UART | BRAM, flash | BRAM boot |
| `ST_NICCC` | `fw/ST_NICCC.c` | the ST-NICCC polygon demo, rendered as ANSI characters; needs the scene data in flash | BRAM, flash | not yet |
| `tinyraytracer` | `fw/tinyraytracer.c` | ray-traced scene on the UART | flash only (29 KB of code) | flash boot, started with the reset button |

"Run on the board" is what has run on the owner's Genesys 2 so far, with the bitstream loaded
over JTAG; the final report shows the results (`docs/design/design.tex`, "Results on the
board").

`tinyraytracer` needs `<math.h>` and `libm`, which the distribution toolchain does not ship;
the firmware Makefile takes them from the RISC-V newlib bundled with Vivado (`XILINX_RV32_ROOT`).
Every other demo builds without Vivado installed.

## Building the bitstream

```sh
source <vivado-install>/settings64.sh
make bitstream          # synth, impl, bitstream -> build/SOC.bit; prints WNS/WHS, timing=MET|FAILED
make check-synth        # stop after synthesis
make baseline           # non-project synth/impl, utilization and timing reports in build/baseline/
```

`make bitstream` regenerates the project with `vivado/create_project.tcl`, runs `synth_1`
and `impl_1` through `write_bitstream`, and copies the result to `build/SOC.bit`. Every
tool-running target also writes its log to `build/logs/<target>-<timestamp>.log`. The root
Makefile launches Vivado from `build/` so its by-products stay out of the source tree.

To open the design in the Vivado GUI, generate the project first and open
`build/vivado/soc.xpr`:

```sh
mkdir -p build && cd build
vivado -mode batch -nojournal -nolog -source ../vivado/create_project.tcl
```

The bitstream's boot mode is the `BOOT_ADDR` parameter of `SOC` in `rtl/SOC.v`. Its default
is flash boot, and `make bitstream` builds that. A BRAM-boot bitstream overrides the parameter
at synthesis instead of editing the source: `docs/design/scripts/board_bitstream.tcl` sets
`BOOT_ADDR` to `BOOT_ADDR_BRAM`, 0, as the testbench does, because simulation has no SPI-flash
model. "Running the demos" below runs it.

## Running the demos

Open a serial terminal on the board's USB-UART port at 115200 baud, 8N1, for example:

```sh
picocom -b 115200 --imap lfcrlf /dev/ttyUSB0
```

The demos end their lines with a bare LF; `--imap lfcrlf` starts each line at the left margin.
The demos that draw in colour use ANSI escape sequences: `mandelbrot` sets 24-bit
backgrounds, `riscv_logo` the 16-colour SGR codes, `ST_NICCC` and `tinyraytracer` 256-colour
codes. Use a terminal emulator that supports all three.

![riscv_logo turning, as the board drew it](docs/design/figures/board_riscv_logo.gif)

`riscv_logo` on the board, in BRAM boot: one turn of 64 frames, each shown for as long as the
board took to send it (to 10 ms), rendered from the UART capture in xterm's colours. The final
report shows this and the other board results (`docs/design/design.tex`, "Results on the
board").

Both boot modes below load the bitstream over JTAG: it lasts until the board is switched off,
and the next power-on boots whatever bitstream the flash holds at offset `0x0` (on a board as
shipped, Digilent's factory demo). Nothing here writes offset `0x0`. Every command needs
Vivado's `settings64.sh` sourced, and runs from the repository root. The scripts are described
in their headers and in `docs/design/figures/README.md`, "Board captures".

### BRAM boot

The program is part of the bitstream, so each demo is a rebuild. One script builds both and
loads them, leaving `rtl/SOC.v` and `rtl/firmware.hex` as they are:

```sh
docs/design/scripts/board_capture.sh <demo> bram <seconds> /tmp/<demo>
```

It builds the demo's firmware image and a BRAM-boot bitstream with `board_bitstream.tcl` in
`docs/design/build/board/<demo>/` (`blinker`, `sieve`, `mandelbrot`, `riscv_logo` or
`ST_NICCC`; `tinyraytracer` does not fit), loads it over JTAG, and records the UART for
`<seconds>` into `/tmp/<demo>.bin`. The core starts as soon as configuration ends and keeps
running after the script: open the terminal and press the reset button to watch the demo from
its start. Output appears on the UART or the LEDs.

### Flash boot

The program is written to the flash's code window; the bitstream, built once with the default
`BOOT_ADDR`, is loaded over JTAG:

1. `make -C fw PROG=<demo> TARGET=flash` produces `fw/build/<demo>.spiflash.mcs`, an image
   that places the code at `0xD00000` in the chip. Any demo in the table above can run this
   way; `tinyraytracer` only runs in this mode.
2. Write it to the flash:

   ```sh
   mkdir -p docs/design/build && cd docs/design/build
   vivado -mode batch -nojournal -nolog -source ../scripts/board_flash.tcl \
       -tclargs write ../../../fw/build/<demo>.spiflash.mcs
   cd -
   ```

   This is Hardware Manager's *Program Configuration Memory Device* with the address range
   *Configuration File Only* (flash part `s25fl256sxxxxxx0-spi-x1_x2_x4`): only the bytes the
   image covers change. The script refuses an image with a byte below `0xC00000`. It also
   keeps the flash's Quad Enable bit: Vivado clears that non-volatile bit on every write
   unless `PROGRAM.SKIP_QE_BIT_ERASE` is set, and the factory bitstream reads the flash four
   bits wide and needs it, so a write without the property leaves the board unable to boot at
   power-on, with no error shown. `docs/design/scripts/flashregs/` holds a small design that
   reads the bit over the flash pins, and sets it again (`docs/design/figures/README.md`,
   "The Quad Enable bit").
3. Load the flash-boot bitstream and record the UART:

   ```sh
   docs/design/scripts/board_capture.sh <demo> flash <seconds> /tmp/<demo>
   ```

   It first reads the code window back and stops unless it holds the demo just built. It then
   builds the bitstream in `docs/design/build/board/flash/` (or program `build/SOC.bit` from
   `make bitstream` with Hardware Manager instead). The core fetches its first instruction
   from `0x01D0_0000`.
4. Press the reset button once the load has ended. Straight after configuration the core
   prints nothing and the LEDs stay dark, most likely because its first fetch from the flash
   is lost (the final report, "Results on the board"). From the reset on, the demo runs, and
   the reset button restarts it.

`ST_NICCC` additionally needs the scene file (`scene1.dat`, the 640 KB polygon stream of the
original demo, not included in this repository) written to the flash at `0xC00000`. The same
Tcl helper wraps it: pass the file, the output name and the offset to `fw/tools/write_mcs.tcl`
as the firmware Makefile does for the code image, then write it as in step 2.

A board as shipped is not blank above its factory bitstream: on the owner's board, Digilent's
factory demo also holds data from `0x600000` to `0x69FFFF` and from `0x800000` to `0xDEFFFF`,
which the scene data and the code window overwrite in part. Back the whole flash up before the
first write, with `-tclargs read 0x0 0x2000000 <file>.bin` in step 2's place (about two
minutes). To restore the region from `0xC00000`, wrap that slice of the file with
`fw/tools/write_mcs.tcl` and write it as in step 2.

TODO: add a photo of the board with a terminal showing a demo.

## Simulation and checks

```sh
make lint
make smoke
make -j2 check
```

The header of the root `Makefile` lists every gate with what it runs and how long it takes;
`docs/CONTRIBUTING.md`, "Gates and evidence", says when each one runs.

The testbench in `sim/bench.v` instantiates `SOC` with BRAM boot, loads the committed firmware
image and records what an outside observer sees: every UART byte and every LED change. The
trace of one complete mandelbrot frame is committed as `sim/golden/mandelbrot_bram.txt`, and
the regression passes only when a new run is byte-identical to it, cycle count included. See
`sim/README.md`. Coding conventions and the rules the lint enforces are in
`docs/CONTRIBUTING.md`.

## Final report

The final report is a LaTeX project under `docs/design/`. It explains the design choices
and how the core, memory subsystem, SoC and firmware fit together.

The built PDF is committed: [`docs/design/design.pdf`](docs/design/design.pdf).

```sh
make -C docs/design           # pdflatex -> docs/design/build/design.pdf from the committed figures
make -C docs/design publish   # the same, then copied to docs/design/design.pdf, the committed copy
make -C docs/design figures   # regenerate the scriptable figures: Vivado, xvfb-run, Ghostscript
make -C docs/design captures  # record the board captures again: the board, Vivado, RISC-V gcc
```

The sources are [`docs/design/design.tex`](docs/design/design.tex) and
`docs/design/figures/`, whose README lists every figure, the script behind it, the recipes
for the manual ones, and what each target needs.

## Results

TODO: fill in from the post-implementation reports (`make baseline`, reports in
`build/baseline/`) once confirmed:

| Metric | Value |
|---|---|
| Vivado version | TODO |
| Slice LUTs | TODO |
| Slice registers | TODO |
| Block RAM tiles | TODO |
| Fmax (post-route, 1 / (period minus WNS)) | TODO |
| Timing at 200 MHz | TODO |

## License

BSD-3-Clause, see `LICENSE`.
