# Figures

Figures for the final report, `docs/design/design.tex`, one file per figure, or per panel of a
figure with panels (`vivado_device_*`, numbered in panel order). Every figure that a
script can make is made by one, so it can follow a change to the design; the rest are manual,
each with a recipe below. Each figure is committed once it exists, and `make -C docs/design`
builds the PDF from the committed figures without Vivado or the board. Paths below are relative
to the repository root.

Formats: PDF for vector drawings, PNG for screenshots, JPEG for photos, and LaTeX for the
excerpts a TikZ drawing in `design.tex` sets (`flow_excerpts.tex`). Keep the source of a
hand-made drawing (for example `.svg`) next to its exported PDF.

A photo is committed without its metadata: a phone writes the GPS position into the EXIF
block, and the repository is public. Keep only the JFIF header, the ICC colour profile and the
image data; dropping segments, rather than re-saving, leaves every pixel as it was.

| File in `docs/design/figures/` | Chapter | Made by |
|---|---|---|
| `board.jpg` | Title page | by hand: the owner's photo, notes below |
| `board_bottom.jpg` | 2, Board and tools | by hand: the owner's photo, notes below |
| `rtl_soc.pdf` | 4, System architecture | `make figures`: `docs/design/scripts/rtl_schematics.tcl`, cropped by `docs/design/scripts/crop_pdf.sh` |
| `rtl_alu.pdf` | 5, The multi-cycle core | `make figures`, as above |
| `wave_fsm.pdf` | 5, The multi-cycle core: four instructions through the FSM states | `make figures`: `docs/design/scripts/waves/WaveBench.v` under iverilog, rendered by `docs/design/scripts/vcd_wave.py`; "Waveforms" below |
| `wave_flash.pdf`, `wave_flash_end.pdf` | 6, Memory and memory-mapped IO: an instruction fetched from the flash, whole and its end | `make figures`, as `wave_fsm.pdf` |
| `flow_excerpts.tex` | 8, From C to the board: the excerpts of the flow figure, drawn in `design.tex` | `make figures`: `docs/design/scripts/flow_excerpts.py`; "The C-to-board flow" below |
| `sch_oscillator.png`, `sch_reset.png`, `sch_leds.png`, `sch_uart.png`, `sch_config.png`, `sch_mode.png` | 2, Board and tools: excerpts of Digilent's schematic | `make figures`: `docs/design/scripts/schematic_crops.sh`, from a local copy of the schematic; "Schematic excerpts" below |
| `vivado_io_package.png` | 2, Board and tools | by hand, recipe below |
| `impl_results.tex` | 10, Implementation results: its numbers, the utilization table's rows and the data of the slack, logic-level and power charts, drawn in `design.tex` | `make figures`: `docs/design/scripts/impl_reports.tcl` and `docs/design/scripts/impl_results.py`; "Implementation results" below |
| `timing_worst_path.pdf` | 10, Implementation results: the worst setup path | `make figures`: `docs/design/scripts/path_schematic.tcl`, cropped by `docs/design/scripts/crop_pdf.sh` |
| `vivado_device_1_whole.png` to `vivado_device_4_path.png` | 10, Implementation results: the zoom series | by hand, recipe below |
| `vivado_device_5_routing_on.png`, `vivado_device_6_routing_off.png` | 10, Implementation results: the worst path | by hand, recipe below |
| `board_mandelbrot.pdf` | 11, Results on the board | `make figures`: `docs/design/scripts/board_figures.py`, from the board captures |
| `board_riscv_logo.pdf` | 11, Results on the board: the filmstrip (pages 1, 9, ..., 57) and the animation | `make figures`, as above |
| `board_riscv_logo.gif` | The README, "Running the demos" | `make figures`, as above |
| `board_tinyraytracer.pdf` | 11, Results on the board: flash boot | `make figures`, as above |

## Scripted figures: `make figures`

```sh
source ~/Xilinx/2025.2/Vivado/settings64.sh
make -C docs/design figures     # then review and commit the changed figures
```

Needs Vivado, `xvfb-run` (package `xvfb`), Ghostscript, `pdftoppm` (package `poppler-utils`),
the local copy of the board schematic ("Schematic excerpts" below), and Python 3 with Pillow for the
figures rendered from the board captures (`make board-figures` makes only those, and needs
nothing else). `docs/design/scripts/vivado_xvfb.sh`
runs each Vivado script in the GUI on a private X server, never on your display, from the
scratch directory `docs/design/build/vivado/`, so nothing Vivado writes lands in the tracked
tree; its log is `vivado.log` there. Afterwards `git status` shows only the figures that
changed: the crop writes no date or document ID, so an unchanged figure regenerates
byte-identical.

Facts about Vivado 2025.2 behind these scripts:

- `write_schematic` exports the open schematic window and writes nothing in batch mode, hence
  the GUI under Xvfb. Its formats are `pdf` and `native`; `-orientation portrait` keeps the
  drawing upright, and `crop_pdf.sh` trims the page to it (Ghostscript's `bbox` device,
  then `pdfwrite` with `-dFIXEDMEDIA`).
- In the GUI, never block with `after <ms>` right after `open_checkpoint`: the "Loading device"
  dialog stays up. Chain the steps with `after <ms> <proc>` and return to the event loop.
- Vivado has no command that exports the Device window as an image, and zooming it takes
  toolbar clicks. That is why the zoomed views below are manual.
- In the synthesized netlist the ALU's logic is absorbed into the register file, leaving two
  LUTs in the ALU, so the schematics come from the elaborated RTL (`synth_design -rtl`).
- Every Vivado run works in a scratch directory (the firmware image is read by bare name), and a
  checkpoint is opened from a copy, so the original is never written.

## Implementation results: `make impl`

Chapter 10's numbers are generated, so they follow a change to the RTL. `make impl` (part of
`make figures`) runs four steps, from `docs/design/`:

1. `vivado/baseline.tcl`, the script behind `docs/baseline.md`, builds the routed design into
   `docs/design/build/impl/`, in about a minute, and only when `rtl/firmware.hex`, the RTL, the
   constraints or the script changed. The report has its own checkpoint, not the one in
   `build/baseline/`, which holds whatever `make baseline` last built, possibly from an
   uncommitted tree.
2. `docs/design/scripts/impl_reports.tcl`, in batch, opens a copy of the checkpoint and writes
   the hierarchical utilization (`-hierarchical_min_primitive_count 0`, or the small modules
   are hidden), the power report, the worst setup path's properties and cells, the worst slack
   and logic levels of every timed endpoint, and WNS, WHS and the endpoint counts, into
   `docs/design/build/impl/reports/`.
3. `docs/design/scripts/impl_results.py` turns them into `impl_results.tex`: one macro per
   number the chapter quotes, the table's rows, the histogram's and the bar chart's
   coordinates (pgfplots) and the pie's slices (pgf-pie). It fails unless WNS, WHS, Fmax, the
   endpoint counts, LUTs, flip-flops, block RAM tiles and bonded IOBs all equal
   `docs/baseline.md`: after a change that moves them, `make baseline` and the baseline
   document come first.
4. `docs/design/scripts/path_schematic.tcl`, in the GUI under Xvfb as the RTL schematics are,
   draws the worst path from its pin pairs (`show_schematic -pin_pairs`), so each net shows
   only its segment on the path, and `crop_pdf.sh` crops it into `timing_worst_path.pdf`.

It also fails unless the reports agree with each other (the worst path's slack and the
smallest endpoint slack are the WNS, its logic levels are its cells between the registers) and
the path is still LUTs, one carry chain, then LUTs, the shape chapter 10 describes. A few facts
in that chapter's prose are written by hand: that the worst path is the load path, and that its
carry chain ends at bit 24, the flash region's bit. After a change that moves the path, read
`docs/design/build/impl/reports/worst_path.txt` and check them.

The power numbers are Vivado's vectorless estimate at its default toggle rates. Nothing in
either file records a date, so an unchanged design regenerates them byte-identical.

## Schematic excerpts: `make schematics`

`docs/design/scripts/schematic_crops.sh` (part of `make figures`) crops six fixed regions of
Digilent's Genesys 2 schematic, revision H.1 (22 pages, 828 x 612 pt), with `pdftoppm` at 300
dpi into `sch_*.png`; the table at the end of the script lists each region's page and box, in
points from the top left corner. Digilent's site refuses a scripted download (HTTP 403), so the
script reads a local copy: download the schematic from the Genesys 2 Resource Center,
<https://digilent.com/reference/programmable-logic/genesys-2/start>, as
`docs/design/build/genesys2_sch.pdf`, or point `SCHEMATIC=<path>` at it. The script checks its
SHA-256 (`73a6b396...c43`) and stops on any other file, since another revision would put other
parts in the boxes. If Digilent publishes a new revision, measure the boxes again on it and
update the hash with them.

| File | Page | Shows |
|---|---|---|
| `sch_oscillator.png` | 13 | IC23, the 200 MHz LVDS oscillator, `SYSCLK_P` and `SYSCLK_N` |
| `sch_reset.png` | 11 | BTN1, CPU RESET, and its pull-up, `CPU_RESET_N` |
| `sch_leds.png` | 4 | LD0 to LD7 and their 330 ohm resistors |
| `sch_uart.png` | 9 | IC16, the FT232RQ, behind the micro-USB port J15 |
| `sch_config.png` | 15 | the FPGA's configuration bank, the QSPI flash IC26, and IC25D, the buffer of `UART_TX_IN` |
| `sch_mode.png` | 15 | the mode jumper JP5 and its three positions |

## Waveforms: `make waves`

The waveforms are rendered from a VCD of the simulated SoC, not drawn by hand, so they follow
a change to the RTL or the firmware. `make waves` (part of `make figures`) runs three
steps, from `docs/design/`, once for each boot mode:

1. `docs/design/scripts/waves/run_bench.sh` simulates `docs/design/scripts/waves/WaveBench.v`
   under iverilog: the `SOC` top driven as `sim/bench.v` drives it, with Vivado's unisim
   models of `IBUFDS`, `BUFG` and `STARTUPE2` and its `glbl.v` from the Vivado install
   (`XILINX_VIVADO`, else `~/Xilinx/2025.2/Vivado`); no Vivado tool runs. In BRAM boot the RAM
   holds `rtl/firmware.hex`, for 3000 ns. With `--flash <image.bin>` the SoC boots from the
   flash, for 6000 ns: `make waves` first builds mandelbrot's flash image into
   `docs/design/build/waves/fw/` (`make -C fw TARGET=flash` with its own `BUILD`, so
   `fw/build/` is left alone), and `docs/design/scripts/waves/FlashImage.v`, a model of the
   flash's `03h` read, holds it at the code offset. The model is clocked from `glbl.CCLKO_GLBL`,
   the CCLK pin as the `STARTUPE2` model drives it. The bench dumps the signals the waveforms
   draw or trigger on and nothing else, the bench's header lists them, into
   `docs/design/build/waves/<bram|flash>/wave.vcd`. Nothing is checked.
2. `docs/design/scripts/vcd_wave.py` renders one window of the VCD as a vector PDF. A spec
   file names the signals, top to bottom, with a label and a format each (`bit`, `hex`,
   `dec`, named values for an FSM, `clock` for the one signal whose rising edges number the
   cycles, or `grid` for that signal when its row is not wanted); its header gives the
   syntax. `--start` names the signal values that open the window, as a trigger does, and
   `--cycles` its length, so the window moves with the firmware rather than with a
   simulation time. A bus value is written in hex without leading zeros, and left blank where
   it does not fit; `x` or `z` bits make the value `x`. In a long window the cycle numbers
   and grid lines thin out to every 2nd, 5th, 10th, ... cycle, so they stay legible.
   `--selftest` checks the VCD reader, the trigger and the spec parser against two built-in
   VCDs; `make waves` runs it first. It writes the PDF file through
   `docs/design/scripts/pdf_objects.py`, as `board_figures.py` does.
3. `docs/design/scripts/crop_pdf.sh` embeds the font, as for the RTL schematics.

| Figure | Spec | Window |
|---|---|---|
| `wave_fsm.pdf` | `docs/design/scripts/waves/fsm.wave` | BRAM boot, from `FETCH_INSTR` at `pc = 0x278`, 19 cycles: `lw s0,8(sp)`, `lui a5,0x400`, `lui a4,0x0`, `sw s0,4(a5)` at the end of `main`'s prologue in mandelbrot, where the frame counter goes to the LEDs |
| `wave_flash.pdf` | `docs/design/scripts/waves/flash.wave` | flash boot, from `FETCH_INSTR` at `pc = 0x1d00008`, 386 cycles: the fetch of `addi sp,sp,-2048`, the third instruction of `fw/start_spiflash.S`, one SPI transaction |
| `wave_flash_end.pdf` | `docs/design/scripts/waves/flash.wave` | the same fetch, from the controller's receive count at 2 (`spiflash.rcv_bitcount`, dumped for the trigger and not drawn), 22 cycles: the last two bits, the latch, and the next fetch's strobe |

The pc comes from `riscv64-unknown-elf-objdump -d fw/build/mandelbrot.bram.elf`, or from the
flash build's ELF in `docs/design/build/waves/fw/`; after a change to the firmware, find the
window again and update the `--start` value in `docs/design/Makefile`. The flash window
skips the first fetch on purpose: in the simulation it is lost, for the reason chapter 7
gives in "CCLK and STARTUPE2". To add a waveform, add its signals to the bench's `$dumpvars`, write
a spec file and add a render line to the `waves` target.

## The C-to-board flow: `make flow`

Figure `fig:flow` is drawn in TikZ in `design.tex`; its excerpts, one LaTeX macro each, are
generated into `flow_excerpts.tex` from the real build, so they follow a change to the
firmware or the RTL. `make flow` (part of `make figures`) runs three steps, from `docs/design/`:

1. `make -C fw` builds mandelbrot into `docs/design/build/flow/`: the BRAM-boot ELF and firmware
   image, the assembly (`build/mandelbrot.s`, the `fw/Makefile` rule for the reader), and the
   flash build's ELF, binary and MCS. `fw/build/` and `rtl/firmware.hex` are left alone; the
   MCS needs Vivado (`fw/tools/write_mcs.tcl`).
2. `docs/design/scripts/flow_bram.tcl` builds the BRAM-boot bitstream from that image with
   `board_bitstream.tcl`, about a minute and a half, and writes the routed block RAMs' `INIT`
   strings to `bram_init.txt`. Make rebuilds it only when the image, the RTL, the constraints
   or the scripts changed.
3. `docs/design/scripts/flow_excerpts.py` cuts the excerpts: the line of `fw/mandelbrot.c` that
   writes the LEDs, its four instructions in the assembly and in `objdump -d` (the store and
   the three before it, the window of `wave_fsm.pdf`), the firmware image's lines, the block
   RAMs' `INIT` string, the bitstream's header, the JTAG load and frame 0 from
   `captures/mandelbrot_bram`, and the flash build's first instruction through the binary and
   the MCS. The JTAG and flash lines are quoted from `board_program.tcl` and `board_flash.tcl`.
   It also writes the numbers and words chapter 8's prose quotes, one macro each. It fails
   unless each stage holds what the one before made: the image equals `rtl/firmware.hex`, its
   words are the ELF's instructions, two 18-bit-wide block RAMs of one kind hold its low and
   high halves, the binary begins with the flash ELF's first instruction, and the MCS holds
   the binary at `SPIFLASH_CODE_OFFSET`.

The window is found, not configured: the first store in `main` that `objdump` annotates with
the LED register's address. It is the window of `wave_fsm.pdf` too, whose `--start` in
`docs/design/Makefile` is configured: after a firmware change, check that both still agree.
Nothing in the file records a date, so an unchanged build regenerates it byte-identical.

## Board captures: `make captures`

The figures of chapter 11 are rendered from the board's UART output, recorded once and
committed in `docs/design/captures/` as source data, so `make figures` needs no board.
Recording again needs the board, its two micro-USB cables, Vivado, `riscv64-unknown-elf-gcc`
and Python 3 with pyserial:

```sh
source ~/Xilinx/2025.2/Vivado/settings64.sh
make -C docs/design captures    # then make figures; review and commit captures and figures
```

`make captures` records the BRAM-boot demos, mandelbrot, riscv_logo and sieve. For each,
`docs/design/scripts/board_capture.sh <demo> bram` builds the firmware image and a BRAM-boot
bitstream in `docs/design/build/board/<demo>/`, the bitstream only when the image, the RTL, the
constraints or `board_bitstream.tcl` changed (`board_bitstream.tcl`: synthesis and
implementation as in `vivado/baseline.tcl`, with `BOOT_ADDR` set to 0 as `sim/bench.v` sets
it; it fails unless timing is met). It then opens the UART, loads the bitstream over
JTAG (`board_program.tcl`) and records the output (`uart_capture.py`). The bitstream goes into
the FPGA only: the flash is not written, and a power cycle boots whatever the flash holds.
`rtl/firmware.hex` and `rtl/SOC.v` stay as they are. `UART_PORT` and `JTAG_TARGET` pick the
board when the defaults (the one FT232R in `/dev/serial/by-id`, the one JTAG cable) do not.

### Flash boot

A flash-boot capture needs the demo in the flash's code window first, and the code window holds
one demo at a time, so `make captures` leaves these out. Each write is the owner's call. With
Vivado's `settings64.sh` sourced, from `docs/design/`:

```sh
make -C ../../fw PROG=tinyraytracer TARGET=flash
# write fw/build/tinyraytracer.spiflash.mcs: the README's "Flash boot", step 2
scripts/board_capture.sh tinyraytracer flash 360 captures/tinyraytracer_flash
```

`board_flash.tcl` refuses an image with a byte below `0xC00000`, where the bitstream the board
boots at power-on lives. `board_capture.sh <demo> flash` reads the code window back first and
stops unless it holds the demo's binary, then builds the flash-boot bitstream, the `SOC`
default, in `docs/design/build/board/flash/` with a copy of `rtl/firmware.hex` that the core
never runs, and records as above. It prints a reminder just before the load: once the load has
ended, about half a minute after the script starts, press the board's CPU RESET button. After
configuration the core prints nothing until a reset (chapter 11 says why), and tinyraytracer
then takes about two minutes to draw its picture; 360 seconds leaves time for both.
`board_figures.py` draws the last complete run in the capture, so a second press does no harm.

Before the first write, `board_flash.tcl read 0x0 0x2000000 <file>` backs up the whole chip
in about two minutes. The owner's board was not blank above its factory bitstream: Digilent's
factory demo also holds data from `0x600000` to `0x69FFFF` and from `0x800000` to `0xDEFFFF`.
That backup, from 2026-10-28, is in the owner's snapshot of the original project; issue #21
records the readback. A full readback after the tinyraytracer write differed from the backup
only in the 29 016 bytes of the image, at `0xD00000` to `0xD07157`, and so did one after the
third write of the same image, below.

### The Quad Enable bit

The first tinyraytracer write, with the `hw_cfgmem` property `PROGRAM.SKIP_QE_BIT_ERASE` at its
default, 0, cleared the S25FL256S's non-volatile Quad Enable bit (configuration register 1,
bit 1), and a second write of the same image with an SPIx4 `.prm` did not set it back. The
factory bitstream reads the flash four bits wide (opcode `0x6C` in its BSPI register) and needs
the bit: without it the FPGA stalls in configuration at power-on, DONE low and no error flag
set, every byte of the flash intact.

Vivado's Tcl reads no flash register, so `scripts/flashregs/FlashRegs.v` is a small design for
the board that does: it reads status register 1, configuration register 1, the chip's ID and the
four bytes at `0x30` (a bitstream's sync word, `AA995566`, as a check that the bits line up),
prints them on the UART once a second and shows CR1 on the LEDs. Built with `WRITE_REGS=1` it
also writes SR1 `0x00` and CR1 `0x02` once, which sets the bit, and reads them again. On the
owner's board it read `CR1=00`, wrote, read `CR1=02`, and the FPGA configured from the flash
again (`boot_hw_device`, Vivado's reconfigure-from-flash over JTAG: DONE high). The third
write of the image, through `board_flash.tcl write` with `SKIP_QE_BIT_ERASE 1`, kept the bit,
and at the next power-on the board booted Digilent's factory demo, DONE lit and the demo on
the OLED. From `docs/design/`:

```sh
mkdir -p build/flashregs && cd build/flashregs
vivado -mode batch -nojournal -nolog -source ../../scripts/flashregs/build.tcl -tclargs 0
python3 ../../scripts/uart_capture.py /dev/serial/by-id/usb-FTDI_FT232R_* 5 regs -- \
    vivado -mode batch -nojournal -nolog -source ../../scripts/board_program.tcl \
    -tclargs FlashRegs_w0.bit
cat regs.bin    # SR1=00 CR1=02 ID=010219 D30=AA995566, one line a second
cd -
```

`-tclargs 1` builds the writing one, `FlashRegs_w1.bit`, which is a write to the chip: the
owner's call, as above. `FlashRegsBench.v` runs the writing tool against `FlashModel.v`, a
model of the register commands, under iverilog with Vivado's unisim models; its header gives
the command.

### Captures, figures and checks

A capture is two files, named for the demo and the boot mode. `<demo>_<boot>.bin` holds the
bytes as received, from the moment the bitstream starts to load. `<demo>_<boot>.times` is the
timeline, in seconds since the port was opened: `PROGRAM_START` and `PROGRAM_END` around the
load, a `READ <t> <count>` line for each read of the port (every millisecond, the bridge in
low-latency mode, so a byte's time is good to about 2 ms), and `END`. The first bytes are from
the design that was running before, up to the moment configuration stopped it;
`board_figures.py` takes the loaded design's output to start after the longest silence during
the load, while the FPGA was being configured.

`board_figures.py` replays the bytes through a small terminal emulator, documented in its
header, with LF taken as CR LF as `picocom --imap lfcrlf` does, the 16 and the 256 colours in
xterm's palette and the default background black. It prints `BOARD` lines with the measurements
chapter 11 quotes, and fails unless mandelbrot's first frame is byte for byte the UART bytes of
the golden trace, every sieve round captured ends in `OK`, and a complete tinyraytracer run
is in its capture. The riscv_logo capture can be checked against the program compiled natively
in the same way as `docs/baseline.md` checks the golden frame; 54 is the byte at which
`board_figures.py` reports the loaded design's output to begin:

```sh
gcc -O2 -w -o /tmp/logo fw/riscv_logo.c
tail -c +55 docs/design/captures/riscv_logo_bram.bin > /tmp/board_logo.bin
timeout 5 /tmp/logo | head -c $(stat -c %s /tmp/board_logo.bin) | cmp /tmp/board_logo.bin -
```

sieve is checked the same way, with an empty `wait()` and the checksum's hex digits in upper
case, as `fw/print.c` prints them:

```sh
echo 'void wait(void) {}' > /tmp/wait.c && gcc -O2 -w -o /tmp/sieve fw/sieve.c /tmp/wait.c
timeout 5 /tmp/sieve | sed 's/1772a48f/1772A48F/' \
    | head -c $(stat -c %s docs/design/captures/sieve_bram.bin) \
    | cmp docs/design/captures/sieve_bram.bin -
```

tinyraytracer's run, the bytes `board_figures.py` names, against the program compiled natively
with a stub `io.h`, whose LED writes do nothing (TRT_START and TRT_END are the first and last
byte it reports):

```sh
mkdir -p /tmp/trt && cp fw/tinyraytracer.c /tmp/trt/
echo '#define IO_OUT(port, val) ((void)(val))' > /tmp/trt/io.h
gcc -O2 -w -o /tmp/trt/trt /tmp/trt/tinyraytracer.c -lm
tail -c +$((TRT_START + 1)) docs/design/captures/tinyraytracer_flash.bin \
    | head -c $((TRT_END - TRT_START + 1)) | cmp - <(/tmp/trt/trt)
```

- Captured 2026-10-28, the BRAM-boot demos with `make captures` and tinyraytracer as above,
  Vivado 2025.2, on the owner's board: Genesys 2 revision H, through its own FT232R USB-UART
  bridge and Digilent USB-JTAG

## The report's module colours

One colour per module, in every Vivado view and drawing of the report. They are Okabe-Ito
colours, which stay distinct under the common forms of colour blindness.
`docs/design/scripts/gui_helper.tcl` holds the same table. `docs/design/design.tex` holds the
module rows, as the `\definecolor` lines in its preamble and the colour key, `tab:module-colours`,
in chapter 2; its views show the worst path selected, so the key has white for it, not red.

| Module | Cells | RGB | Ports |
|---|---|---|---|
| core (`Processor`, `Decoder`, `Control`, `ALU`) | `cpu`, except the register file | 0 114 178 (blue) | |
| `RegisterFile` | `cpu/register_file` | 86 180 233 (sky blue) | |
| `Memory` (RAM) | `ram` | 230 159 0 (orange) | |
| `IOBus` (LED register) | `bus` | 240 228 66 (yellow) | `LEDS` |
| `UartTx` | `uart` | 0 158 115 (bluish green) | `uart_rx_out`, `uart_tx_in` |
| `SPIFlash`, with `STARTUPE2` | `spiflash`, `spiflash_cclk_access` | 204 121 167 (reddish purple) | `spiflash_*` |
| clock and reset | `sysclk_buffer`, `sysclk_bufg`, `clockworks` (no cells while `SLOW` is 0) | 153 153 153 (grey) | `sysclk_*`, `RESET` |
| worst setup path | its cells; selected, its wires show in Vivado's selection white | 255 0 0 (red) | |

## Manual figures

All start from the GUI helper, `docs/design/scripts/gui_helper.tcl`. Sourced in the Vivado GUI,
it opens a copy of the routed checkpoint, colours the modules, colours the worst setup path's
cells red and selects the path. It never moves the mouse; the clicks below are yours.

Common steps:

1. `make baseline` if `build/baseline/post_route.dcp` is missing or older than the RTL.
2. Start the GUI from the repository's `build/`, so its by-products stay there:

   ```sh
   source ~/Xilinx/2025.2/Vivado/settings64.sh
   cd build && vivado -mode gui -nojournal -nolog
   ```

3. In the Tcl Console of the fresh session: `source ../docs/design/scripts/gui_helper.tcl`.
   Wait for `gui_helper: done`. The line before it names the worst path; its slack should be
   the WNS in `docs/baseline.md` (0.219 ns: `cpu/instr_reg[3]` to the register-file write,
   15 logic levels, data path 4.312 ns).

If the Vivado version is not 2025.2, note it in the commit that adds the screenshot.

### Device views, from the whole device to the worst path

- Files: `vivado_device_1_whole.png` to `vivado_device_6_routing_off.png`, chapter 10:
  figure `fig:device-zoom` holds panels 1 to 4, figure `fig:worst-path` panels 5 and 6
- Vivado 2025.2, checkpoint `build/baseline/post_route.dcp`
- View: Device window, the worst path selected, Auto-fit Selection on in every panel;
  Routing Resources on in panels 1 to 5, off in panel 6
- Taken 2026-10-27 by the owner: the maximised Device panel, 1827x872 at screen scale
  (GNOME on a 1920x1080 display). Panel 1 was retaken later in the day: the first take
  kept a mouse tooltip.

1. Common steps 1 to 3.
2. Maximise the Device window (double-click its tab) and, in its toolbar, turn on Auto-fit
   Selection and Routing Resources. With Routing Resources on, a net follows its routed wires
   instead of a straight line.
3. Leave the path selected: its wires and cells show white against the module colours.
4. Zoom out all the way, and take each panel as you zoom in, one screenshot of the maximised
   panel at screen scale each (GNOME: Print, then drag over the panel):
   1. `vivado_device_1_whole.png`: the whole device.
   2. `vivado_device_2_regions.png`: the lower clock regions.
   3. `vivado_device_3_design.png`: the design filling the view.
   4. `vivado_device_4_path.png`: the area around the path.
   5. `vivado_device_5_routing_on.png`: the path filling the view, the interconnect tiles'
      names showing; zoom out a step if the path touches the border.
5. Turn Routing Resources off, zoom in a step further, and take
   `vivado_device_6_routing_off.png`: the path's nets drawn as straight lines over the slices.

### I/O package view

- File: `vivado_io_package.png`, chapter 2, figure `fig:io-package`
- Vivado 2025.2, checkpoint `build/baseline/post_route.dcp`
- View: Package window of the I/O Planning layout, with all 16 ports on their pins in their
  modules' colours: the 15 bonded IOBs of `docs/baseline.md`, and `uart_tx_in` on Y20, which
  has no load and so no IOB but keeps its pin from the constraints file
- Taken 2026-10-27 by the owner, as above: the maximised Package panel, 1827x872

1. Common steps 1 to 3. The helper has coloured the ports with their modules' colours.
2. Type `unselect_objects` in the Tcl Console, so the path selection colours nothing.
3. Choose Layout > I/O Planning, maximise the Package window and zoom to fit.
4. Screenshot the maximised panel as above and save it as
   `docs/design/figures/vivado_io_package.png`.

## The board photos

### Top side

- File: `board.jpg`, the title page, under TikZ callouts in `design.tex` that point at the
  photo's own pixels (1964 by 1507): red labels for the parts the design uses, grey for
  notable unused ones. The 200 MHz oscillator, IC23, is the small package left of the fan's
  frame, below its decoupling capacitors C159 and C160; the QSPI flash is on the underside,
  and its callout is dashed, placed from the underside photo's callout mirrored
- iPhone 14, the board's top side, powered on and running Digilent's factory demo (DONE, PGOOD,
  LD0 to LD2 and the OLED lit), room light, no flash
- Cropped on the phone to 1964x1507 (3.0 MP), with a slight tilt. Issue #18 asked for a
  straight top-down daylight shot of at least 12 MP; the owner accepted this one. A retake
  replaces the file under the same name and must keep the framing, or the title page's
  callouts move with it.
- Metadata stripped on 2026-10-27, after the first commit of the photo: the Git history keeps
  that first version, with its GPS position.

### Underside

- File: `board_bottom.jpg`, chapter 2, figure `fig:board-bottom`, under TikZ callouts in
  `design.tex` that point at photo pixels (measured on a 1400-pixel-wide copy)
- iPhone 14, taken the same evening as the top side, held by hand at its lower left corner,
  room light; 2519x1948 (4.9 MP) as committed, metadata stripped
- The parts are named from their markings and Digilent's Genesys 2 schematic: IC26 the
  S25FL256S QSPI flash (schematic page 15, with the QSPI and CCLK nets), IC5 the TUSB1210 USB
  PHY with its oscillator IC4, a TMDS141 HDMI buffer (IC2 or IC3), IC33, IC34 and their
  look-alikes the INA219 current monitors, J3 the microSD slot. The decoupling capacitors are
  the dense field directly below the FPGA's place on the top side.
- A retake must keep the framing, or the callout coordinates in `design.tex` move with it.
