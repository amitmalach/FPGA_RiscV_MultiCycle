# Figures

Figures for the final report, `docs/design/design.tex`, one file per figure. Every figure that a
script can make is made by one, so it can follow a change to the design; the rest are manual,
each with a recipe below. Each figure is committed once it exists, and `make -C docs/design`
builds the PDF from the committed figures without Vivado or the board. Paths below are relative
to the repository root.

Formats: PDF for vector drawings, PNG for screenshots, JPEG for photos. Keep the source of a
hand-made drawing (for example `.svg`) next to its exported PDF.

| File in `docs/design/figures/` | Chapter | Made by |
|---|---|---|
| `board.jpg` | Title page | by hand: the owner's photo, notes below |
| `rtl_soc.pdf` | 4, System architecture | `make figures`: `docs/design/scripts/rtl_schematics.tcl`, cropped by `docs/design/scripts/crop_pdf.sh` |
| `rtl_alu.pdf` | 5, The multi-cycle core | `make figures`, as above |
| `vivado_routed_worst_path.png` | 10, Implementation results | by hand, recipe below |
| `vivado_io_package.png` | 2, Board and tools | by hand, recipe below |

## Scripted figures: `make figures`

```sh
source ~/Xilinx/2025.2/Vivado/settings64.sh
make -C docs/design figures     # then review and commit the changed figures
```

Needs Vivado, `xvfb-run` (package `xvfb`) and Ghostscript. `docs/design/scripts/vivado_xvfb.sh`
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

## The report's module colours

One colour per module, in every Vivado view and drawing of the report. They are Okabe-Ito
colours, which stay distinct under the common forms of colour blindness.
`docs/design/scripts/gui_helper.tcl` holds the same table.

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

Both start from the GUI helper, `docs/design/scripts/gui_helper.tcl`. Sourced in the Vivado GUI,
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

### Zoomed routed view with the worst path

- File: `vivado_routed_worst_path.png`, chapter 10
- Vivado 2025.2, checkpoint `build/baseline/post_route.dcp`
- View: Device window, routing resources shown, zoomed to the worst path
- Taken 2026-10-27 by the owner: the maximised Device panel, 1827x872 at screen scale
  (GNOME on a 1920x1080 display), zoomed in until the interconnect tiles' names show

1. Common steps 1 to 3. The Device window zooms to the selected path when Auto-fit Selection
   is on in its toolbar; turn it on if the view did not move.
2. Maximise the Device window (double-click its tab).
3. In the Device window's toolbar, turn on Routing Resources, so the path follows its routed
   wires instead of straight lines. Zoom out a step if the path touches the border.
4. Leave the path selected: its wires and cells show white against the module colours.
5. Screenshot the maximised panel at screen scale (GNOME: Print, then drag over the panel);
   save it as `docs/design/figures/vivado_routed_worst_path.png`.

### I/O package view

- File: `vivado_io_package.png`, chapter 2
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

## The board photo

- File: `board.jpg`, the title page, under the TikZ labels
- iPhone 14, the board's top side, powered on and running Digilent's factory demo (DONE, PGOOD,
  LD0 to LD2 and the OLED lit), room light, no flash
- Cropped on the phone to 1964x1507 (3.0 MP), with a slight tilt. Issue #18 asked for a
  straight top-down daylight shot of at least 12 MP; the owner accepted this one. A retake
  replaces the file under the same name.
