# Design document: docs/design/design.tex -> build/design.pdf with pdflatex.
#
#   make            build the PDF (two passes, so the table of contents and
#                   cross references settle)
#   make clean      remove build/
#
# Source material for the content: docs/design/notes.md, the design rationale
# behind each module (bugs, workarounds, timing subtleties, deliberate quirks).
# The RTL under rtl/ and the firmware under fw/ are the other inputs.
#
# All output goes to build/ (ignored by git). The PDF is committed once the
# document has content; until then there is nothing to commit.

TEX      = design.tex
BUILD    = build
PDF      = $(BUILD)/design.pdf
PDFLATEX = pdflatex -interaction=nonstopmode -halt-on-error -output-directory $(BUILD)

.PHONY: all clean
.DELETE_ON_ERROR:

all: $(PDF)

$(PDF): $(TEX) $(wildcard figures/*) | $(BUILD)
	$(PDFLATEX) $(TEX)
	$(PDFLATEX) $(TEX)
	@echo "PDF $(abspath $@)"

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
