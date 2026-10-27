# Final report: docs/design/design.tex -> build/design.pdf with pdflatex.
#
#   make            build the PDF from the committed figures (two passes, so the table of
#                   contents and cross references settle); no Vivado, no board
#   make figures    regenerate the scriptable figures into figures/, then commit them; needs
#                   Vivado's settings64.sh sourced, xvfb-run and Ghostscript
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

.PHONY: all figures clean
.DELETE_ON_ERROR:

all: $(PDF)

$(PDF): $(TEX) $(wildcard figures/*) | $(BUILD)
	$(PDFLATEX) $(TEX)
	$(PDFLATEX) $(TEX)
	@echo "PDF $(abspath $@)"

figures: | $(BUILD)
	scripts/vivado_xvfb.sh $(SCRATCH) scripts/rtl_schematics.tcl $(SCRATCH)
	for f in $(RTL_SCHEMATICS); do scripts/crop_pdf.sh $(SCRATCH)/$$f.pdf figures/$$f.pdf || exit 1; done

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
