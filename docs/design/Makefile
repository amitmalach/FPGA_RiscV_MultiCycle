# Final report: docs/design/design.tex -> build/design.pdf with pdflatex.
#
#   make            build the PDF from the committed figures (two passes, so the table of
#                   contents and cross references settle); no Vivado, no board
#   make figures    regenerate the scriptable figures into figures/, then commit them; needs
#                   Vivado's settings64.sh sourced, xvfb-run, Ghostscript, iverilog,
#                   riscv64-unknown-elf-gcc and Pillow
#   make board-figures
#                   only the figures rendered from the board captures in captures/ (part of
#                   make figures, which also needs Pillow for them)
#   make waves      only the waveforms: scripts/waves/WaveBench.v simulated under iverilog
#                   with Vivado's unisim models, in BRAM boot and in flash boot, rendered by
#                   scripts/vcd_wave.py (part of make figures; needs iverilog, the Vivado
#                   install, riscv64-unknown-elf-gcc and Ghostscript)
#   make flow       only the excerpts of the C-to-board flow figure, figures/flow_excerpts.tex:
#                   mandelbrot built into build/flow/ (its firmware image must equal
#                   rtl/firmware.hex) and a BRAM-boot bitstream built from it, with the
#                   mandelbrot capture in captures/ read as it is; part of make figures, needs
#                   Vivado's settings64.sh sourced, riscv64-unknown-elf-gcc and Pillow
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
FLOW     = $(abspath $(BUILD)/flow)

.PHONY: all figures board-figures waves flow captures clean
.DELETE_ON_ERROR:

all: $(PDF)

$(PDF): $(TEX) $(wildcard figures/*) | $(BUILD)
	$(PDFLATEX) $(TEX)
	$(PDFLATEX) $(TEX)
	@echo "PDF $(abspath $@)"

figures: board-figures waves flow | $(BUILD)
	scripts/vivado_xvfb.sh $(SCRATCH) scripts/rtl_schematics.tcl $(SCRATCH)
	for f in $(RTL_SCHEMATICS); do scripts/crop_pdf.sh $(SCRATCH)/$$f.pdf figures/$$f.pdf || exit 1; done

board-figures:
	scripts/board_figures.py captures figures

# Each waveform is one window of a bench run's VCD: --start names the values that open it
# (an FSM state and a pc, from the disassembly of fw/build/mandelbrot.bram.elf, or of the
# flash build's ELF in build/waves/fw/; the flash controller's receive count for the end of a
# transaction) and --cycles its length. The flash run boots mandelbrot's flash build, made
# here so that fw/build/ is left alone; the window is the third instruction fetch of
# fw/start_spiflash.S. The crop embeds the font and drops nothing else.
FLASH_IMAGE = $(WAVES)/fw/mandelbrot.spiflash.bin
waves:
	$(VCD_WAVE) --selftest
	scripts/waves/run_bench.sh $(WAVES)/bram
	$(VCD_WAVE) $(WAVES)/bram/wave.vcd scripts/waves/fsm.wave $(WAVES)/wave_fsm.pdf \
	    --start cpu.control.state=0,cpu.pc=278 --cycles 19
	scripts/crop_pdf.sh $(WAVES)/wave_fsm.pdf figures/wave_fsm.pdf
	$(MAKE) -C ../../fw PROG=mandelbrot TARGET=flash BUILD=$(WAVES)/fw $(FLASH_IMAGE)
	scripts/waves/run_bench.sh $(WAVES)/flash --flash $(FLASH_IMAGE) +ns=6000
	$(VCD_WAVE) $(WAVES)/flash/wave.vcd scripts/waves/flash.wave $(WAVES)/wave_flash.pdf \
	    --start cpu.control.state=0,cpu.pc=1d00008 --cycles 386
	$(VCD_WAVE) $(WAVES)/flash/wave.vcd scripts/waves/flash.wave $(WAVES)/wave_flash_end.pdf \
	    --start cpu.pc=1d00008,spiflash.rcv_bitcount=2 --cycles 22
	for f in wave_flash wave_flash_end; do \
	    scripts/crop_pdf.sh $(WAVES)/$$f.pdf figures/$$f.pdf || exit 1; done

# The flow figure follows mandelbrot from its C source to the board, in BRAM boot and in flash
# boot. Its firmware is built into build/flow/fw/, so fw/build/ is left alone, and the BRAM-boot
# bitstream is rebuilt only when the image, the RTL, the constraints or the scripts behind it
# changed. flow_excerpts.py fails unless the image is rtl/firmware.hex and the block RAMs hold it.
FLOW_BIT = $(FLOW)/bram/SOC.bit
RTL_SOURCES = $(addprefix ../../,$(shell grep -vE '^\s*(\#|$$)' ../../vivado/rtl_sources.txt))
flow: | $(BUILD)
	mkdir -p $(FLOW)/bram
	$(MAKE) -C ../../fw PROG=mandelbrot BUILD=$(FLOW)/fw HEX_OUT=$(FLOW)/bram/firmware.hex \
	    $(FLOW)/bram/firmware.hex $(FLOW)/fw/mandelbrot.s
	$(MAKE) -C ../../fw PROG=mandelbrot TARGET=flash BUILD=$(FLOW)/fw
	$(MAKE) $(FLOW_BIT)
	scripts/flow_excerpts.py $(FLOW) captures figures/flow_excerpts.tex

$(FLOW_BIT): $(FLOW)/bram/firmware.hex $(RTL_SOURCES) ../../constraints/Genesys-2-Master.xdc \
	    ../../vivado/common.tcl scripts/board_bitstream.tcl scripts/flow_bram.tcl
	cd $(FLOW)/bram && vivado -mode batch -nojournal -nolog \
	    -source $(abspath scripts/flow_bram.tcl) -tclargs $(FLOW)/bram > build.out \
	    || { tail -n 20 build.out; exit 1; }
	grep -E '^(BOARD|FLOW)' $(FLOW)/bram/build.out

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
