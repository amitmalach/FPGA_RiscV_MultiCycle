# Final report: docs/design/design.tex -> build/design.pdf with pdflatex.
#
#   make            build the PDF from the committed figures (two passes, so the table of
#                   contents and cross references settle); no Vivado, no board
#   make figures    regenerate the scriptable figures into figures/, then commit them; needs
#                   Vivado's settings64.sh sourced, xvfb-run and Ghostscript
#   make board-figures
#                   only the figures rendered from the board captures in captures/ (part of
#                   make figures, which also needs Pillow for them)
#   make waves      only the waveforms: scripts/waves/WaveBench.v simulated under iverilog
#                   with Vivado's unisim models, rendered by scripts/vcd_wave.py (part of
#                   make figures; needs iverilog, the Vivado install and Ghostscript)
#   make captures   record the BRAM-boot board captures again, then commit them: each demo's
#                   bitstream loaded over JTAG; needs the board, Vivado's settings64.sh
#                   sourced, riscv64-unknown-elf-gcc and pyserial. The flash-boot captures
#                   need a flash write first: figures/README.md, "Board captures"
#   make clean      remove build/
#
# Source material for the content: docs/design/notes.md, the design rationale
# behind each module (bugs, workarounds, timing subtleties, deliberate quirks).
# The RTL under rtl/ and the firmware under fw/ are the other inputs.
# figures/README.md lists every figure, the script or recipe behind it, and the
# manual figures' recipes.
#
# The PDF and every by-product go to build/ (ignored by git), including the scratch
# directory Vivado runs in, so nothing Vivado writes lands beside the sources. The
# only tracked output is the regenerated figures in figures/.

TEX      = design.tex
BUILD    = build
PDF      = $(BUILD)/design.pdf
PDFLATEX = pdflatex -interaction=nonstopmode -halt-on-error -output-directory $(BUILD)
SCRATCH  = $(abspath $(BUILD)/vivado)

# RTL schematics written by scripts/rtl_schematics.tcl, cropped into figures/.
RTL_SCHEMATICS = rtl_soc rtl_alu
WAVES    = $(abspath $(BUILD)/waves)
VCD_WAVE = scripts/vcd_wave.py

.PHONY: all figures board-figures waves captures clean
.DELETE_ON_ERROR:

all: $(PDF)

$(PDF): $(TEX) $(wildcard figures/*) | $(BUILD)
	$(PDFLATEX) $(TEX)
	$(PDFLATEX) $(TEX)
	@echo "PDF $(abspath $@)"

figures: board-figures waves | $(BUILD)
	scripts/vivado_xvfb.sh $(SCRATCH) scripts/rtl_schematics.tcl $(SCRATCH)
	for f in $(RTL_SCHEMATICS); do scripts/crop_pdf.sh $(SCRATCH)/$$f.pdf figures/$$f.pdf || exit 1; done

board-figures:
	scripts/board_figures.py captures figures

# Each waveform is one window of the bench's VCD: --start names the values that open it
# (an FSM state and a pc, from the disassembly of fw/build/mandelbrot.bram.elf) and
# --cycles its length. The crop embeds the font and drops nothing else.
waves:
	$(VCD_WAVE) --selftest
	scripts/waves/run_bench.sh $(WAVES)
	$(VCD_WAVE) $(WAVES)/wave.vcd scripts/waves/fsm.wave $(WAVES)/wave_fsm.pdf \
	    --start cpu.control.state=0,cpu.pc=278 --cycles 19
	scripts/crop_pdf.sh $(WAVES)/wave_fsm.pdf figures/wave_fsm.pdf

# Seconds recorded after each load: mandelbrot's first frames, riscv_logo's 64-frame turn
# with a few frames to spare, and sieve's first rounds.
captures:
	scripts/board_capture.sh mandelbrot bram 5 captures/mandelbrot_bram
	scripts/board_capture.sh riscv_logo bram 40 captures/riscv_logo_bram
	scripts/board_capture.sh sieve bram 5 captures/sieve_bram

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
