# Repository gates. When each one runs, and what a commit may cite:
# docs/CONTRIBUTING.md, "Gates and evidence".
#
#   make lint          seconds: by-products, stale paths, line length, naming (no tools needed)
#   make unit          seconds: ALU bench under iverilog, results against hand-worked values
#   make smoke         ~25 s: unit, then a short xsim run that must match the golden trace so far
#   make check         minutes: unit, firmware reproducibility, xsim regression, Vivado synthesis
#   make -j2 check     same, regression and synthesis in parallel
#   make check-moves BASE=<rev>   every file moved since <rev> is a 100 % rename
#   make bitstream     synthesis, implementation, bitstream to build/SOC.bit
#   make baseline      non-project synth/impl with reports in build/baseline/
#
# unit needs iverilog; smoke and check also need riscv64-unknown-elf-gcc on PATH and
# Vivado's settings64.sh sourced.
#
# Every gate writes its output to build/logs/<target>-<timestamp>.log as well as
# the terminal; targets of one make invocation share the timestamp. The log ends
# with "PASS: <target>" or "FAIL: <target> (exit N)", and the terminal output ends
# with "LOG: build/logs/<target>-<timestamp>.log" so `tail -1` gives the line a
# commit message cites (the commit-msg hook in scripts/hooks checks the citation).

SHELL  := /bin/bash
VIVADO ?= vivado
BUILD   = build
LOGS    = $(BUILD)/logs
STAMP  := $(shell date +%Y%m%d-%H%M%S)
# logged,<target>,<command>: run the command, tee to the target's log, append the
# verdict to the log, print the log path last, keep the command's exit code.
logged = @mkdir -p $(LOGS) && log=$(LOGS)/$(1)-$(STAMP).log && { $(2); } 2>&1 | tee $$log; \
	rc=$${PIPESTATUS[0]}; \
	if [ $$rc = 0 ]; then echo "PASS: $(1)" | tee -a $$log; else echo "FAIL: $(1) (exit $$rc)" | tee -a $$log; fi; \
	echo "LOG: $$log"; exit $$rc
# Vivado writes .Xil/ into the directory it is launched from, so every Vivado
# run starts inside build/. The scripts take absolute paths.
VIVADO_BATCH = mkdir -p $(BUILD) && cd $(BUILD) && $(VIVADO) -mode batch -nojournal -nolog

.PHONY: lint unit smoke check check-fw check-sim check-synth check-moves bitstream baseline

lint:
	$(call logged,lint,scripts/lint.sh)

unit:
	$(call logged,unit,sim/run_unit.sh)

check: unit check-sim check-synth

# The firmware check deletes and regenerates rtl/firmware.hex, so the gates
# that read the image wait for it.
check-fw:
	$(call logged,check-fw,$(MAKE) --no-print-directory -C fw check)

check-sim: check-fw
	$(call logged,check-sim,sim/run_regression.sh)

SMOKE_CYCLES ?= 4000000
smoke: unit check-fw
	$(call logged,smoke,sim/run_regression.sh --max-cycles $(SMOKE_CYCLES))

check-synth: check-fw
	$(call logged,check-synth,$(VIVADO_BATCH) -source $(CURDIR)/vivado/build.tcl -tclargs $(CURDIR)/$(BUILD)/vivado synth)

# Full bitstream, and the non-project baseline run (the numbers in docs/baseline.md).
bitstream:
	$(call logged,bitstream,$(VIVADO_BATCH) -source $(CURDIR)/vivado/build.tcl -tclargs $(CURDIR)/$(BUILD)/vivado bitstream)

baseline:
	$(call logged,baseline,$(VIVADO_BATCH) -source $(CURDIR)/vivado/baseline.tcl -tclargs $(CURDIR)/$(BUILD)/baseline)

check-moves:
	$(call logged,check-moves,scripts/lint.sh --moves $(BASE))
