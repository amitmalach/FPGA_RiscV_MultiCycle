# Figures

Figures for the final report, `docs/design/design.tex`, one file per figure, or per panel of a
figure with panels (`vivado_device_*`, numbered in panel order). Every figure that a
script can make is made by one, so it can follow a change to the design; the rest are manual,
each with a recipe below. Each figure is committed once it exists, and `make -C docs/design`
builds the PDF from the committed figures without Vivado or the board. Paths below are relative
to the repository root.

Formats: PDF for vector drawings, PNG for screenshots, JPEG for photos. Keep the source of a
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
| `vivado_io_package.png` | 2, Board and tools | by hand, recipe below |
| `vivado_device_1_whole.png` to `vivado_device_4_path.png` | 10, Implementation results: the zoom series | by hand, recipe below |
| `vivado_device_5_routing_on.png`, `vivado_device_6_routing_off.png` | 10, Implementation results: the worst path | by hand, recipe below |
| `board_mandelbrot.pdf` | 11, Results on the board | `make figures`: `docs/design/scripts/board_figures.py`, from the board captures |
| `board_riscv_logo.pdf` | 11, Results on the board: the filmstrip (pages 1, 9, ..., 57) and the animation | `make figures`, as above |
| `board_riscv_logo.gif` | The README, "Running the demos" | `make figures`, as above |

## Scripted figures: `make figures`

```sh
source ~/Xilinx/2025.2/Vivado/settings64.sh
make -C docs/design figures     # then review and commit the changed figures
```

Needs Vivado, `xvfb-run` (package `xvfb`), Ghostscript, and Python 3 with Pillow for the
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

## Board captures: `make captures`

The figures of chapter 11 are rendered from the board's UART output, recorded once and
committed in `docs/design/captures/` as source data, so `make figures` needs no board.
Recording again needs the board, its two micro-USB cables, Vivado, `riscv64-unknown-elf-gcc`
and Python 3 with pyserial:

```sh
source ~/Xilinx/2025.2/Vivado/settings64.sh
make -C docs/design captures    # then make figures; review and commit captures and figures
```

For each demo, `docs/design/scripts/board_capture.sh` builds the firmware image and a BRAM-boot
bitstream in `docs/design/build/board/<demo>/`, the bitstream only when the image, the RTL, the
constraints or `board_bitstream.tcl` changed (`board_bitstream.tcl`: synthesis and
implementation as in `vivado/baseline.tcl`, with `BOOT_ADDR` set to 0 as `sim/bench.v` sets
it; it fails unless timing is met). It then opens the UART, loads the bitstream over
JTAG (`board_program.tcl`) and records the output (`uart_capture.py`). The bitstream goes into
the FPGA only: the flash is never written, and a power cycle boots whatever the flash holds.
`rtl/firmware.hex` and `rtl/SOC.v` stay as they are. `UART_PORT` and `JTAG_TARGET` pick the
board when the defaults (the one FT232R in `/dev/serial/by-id`, the one JTAG cable) do not.

A capture is two files. `<demo>_bram.bin` holds the bytes as received, from the moment the
bitstream starts to load. `<demo>_bram.times` is the timeline, in seconds since the port was
opened: `PROGRAM_START` and `PROGRAM_END` around the load, a `READ <t> <count>` line for each
read of the port (every millisecond, the bridge in low-latency mode, so a byte's time is good
to about 2 ms), and `END`. The first bytes are from the design that was running before, up to
the moment configuration stopped it; `board_figures.py` takes the loaded design's output to
start after the longest silence during the load, while the FPGA was being configured.

`board_figures.py` replays the bytes through a small terminal emulator, documented in its
header, with LF taken as CR LF as `picocom --imap lfcrlf` does, the 16 colours in xterm's
palette and the default background black. It prints `BOARD` lines with the measurements
chapter 11 quotes, and fails unless mandelbrot's first frame is byte for byte the UART bytes of
the golden trace. The riscv_logo capture can be checked against the program compiled natively
in the same way as `docs/baseline.md` checks the golden frame; 54 is the byte at which
`board_figures.py` reports the loaded design's output to begin:

```sh
gcc -O2 -w -o /tmp/logo fw/riscv_logo.c
tail -c +55 docs/design/captures/riscv_logo_bram.bin > /tmp/board_logo.bin
timeout 5 /tmp/logo | head -c $(stat -c %s /tmp/board_logo.bin) | cmp /tmp/board_logo.bin -
```

- Captured 2026-10-28 with `make captures`, Vivado 2025.2, on the owner's board: Genesys 2
  revision H, through its own FT232R USB-UART bridge and Digilent USB-JTAG

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

- File: `board.jpg`, the title page, under the TikZ labels
- iPhone 14, the board's top side, powered on and running Digilent's factory demo (DONE, PGOOD,
  LD0 to LD2 and the OLED lit), room light, no flash
- Cropped on the phone to 1964x1507 (3.0 MP), with a slight tilt. Issue #18 asked for a
  straight top-down daylight shot of at least 12 MP; the owner accepted this one. A retake
  replaces the file under the same name.
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
