# Synthesis + static timing for the RV32I core (rv32_core), standalone.
# Run from the repo root as `make -C synth <target>` (or `make -f synth/Makefile <target>`).
#   sta-core   yosys -> sky130_fd_sc_hd (tt, 25C, 1.80V) netlist, OpenSTA setup/hold, summary
#   synth-core the sky130 gate netlist only
#   fpga-core  yosys synth_xilinx -family xc7 resource count (LUT/FF/CARRY/DSP/BRAM)
# Outputs go to build/synth/ (gitignored). Pre-layout estimates only: liberty
# default wire load, no placement, ideal clock.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -ec

ROOT       := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SYN        := $(ROOT)/synth
OUT        := $(ROOT)/build/synth
TOP        ?= rv32_core
LIB        ?= $(HOME)/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
PERIOD_NS  ?= 10
XC7_FAMILY ?= xc7

# Source list in rtl/core/core.f order (comment and blank lines skipped).
SRC := $(addprefix $(ROOT)/,$(shell grep -vE '^[[:space:]]*(\#|//|$$)' $(ROOT)/rtl/core/core.f))

ABC_PS     := $(shell awk 'BEGIN{printf "%d", $(PERIOD_NS)*1000}')
ABC_SCRIPT := $(OUT)/abc_timing_$(ABC_PS).abc
NETLIST    := $(OUT)/$(TOP)_sky130_netlist.v
SYNTH_FAST  = synth -booth -flatten -top $(TOP) -run :fine; techmap -map +/techmap.v -map +/choices/kogge-stone.v; synth -booth -flatten -top $(TOP) -run fine:;

.PHONY: help sta-core synth-core fpga-core check-lib clean

help:
	@echo "targets: sta-core [PERIOD_NS=10] | synth-core | fpga-core | clean"

check-lib:
	@test -f "$(LIB)" || { echo "LIB=$(LIB) not found; set LIB=<path to sky130_fd_sc_hd__tt_025C_1v80.lib>"; exit 1; }

$(ABC_SCRIPT): $(SYN)/abc_timing.abc
	@mkdir -p $(OUT)
	sed 's/{D}/$(ABC_PS)/g' $< > $@

# Gate netlist: flattened, Kogge-Stone adders, timing-driven ABC mapping at PERIOD_NS.
synth-core: check-lib $(ABC_SCRIPT)
	@mkdir -p $(OUT)
	yosys -p 'read_verilog -sv -defer $(SRC); hierarchy -top $(TOP); proc; setattr -set keep 1 a:keep %ci1 c:* %i; $(SYNTH_FAST) dfflibmap -liberty $(LIB); abc -D $(ABC_PS) -script $(ABC_SCRIPT) -liberty $(LIB); opt_clean; stat -liberty $(LIB); write_verilog -noattr $(NETLIST)' \
	  > $(OUT)/synth_$(TOP)_sky130.log 2>&1 || { tail -30 $(OUT)/synth_$(TOP)_sky130.log; exit 1; }
	@# OpenSTA's Verilog reader rejects 'signed' on ports/wires; a gate netlist does not need it.
	sed -i -E 's/^(  (input|output|inout|wire)) signed /\1 /' $(NETLIST)
	@grep -E 'Chip area' $(OUT)/synth_$(TOP)_sky130.log | tail -1

sta-core: synth-core
	LIB=$(LIB) NETLIST=$(NETLIST) MODULE=$(TOP) PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init $(SYN)/sta.tcl > $(OUT)/sta_$(TOP).log 2>&1 || { tail -30 $(OUT)/sta_$(TOP).log; exit 1; }
	python3 $(SYN)/sta_summary.py $(OUT)/sta_$(TOP).log --period $(PERIOD_NS) \
	  --netlist $(NETLIST) --out $(OUT)/sta_$(TOP)_summary.txt

# Xilinx 7-series resource count (generic xc7 mapping; no part, no place and route).
fpga-core:
	@mkdir -p $(OUT)
	yosys -p 'read_verilog -sv -defer $(SRC); hierarchy -top $(TOP); synth_xilinx -family $(XC7_FAMILY) -flatten -top $(TOP); tee -o $(OUT)/fpga_$(TOP)_stat.txt stat' \
	  > $(OUT)/fpga_$(TOP).log 2>&1 || { tail -30 $(OUT)/fpga_$(TOP).log; exit 1; }
	python3 $(SYN)/fpga_summary.py $(OUT)/fpga_$(TOP)_stat.txt --out $(OUT)/fpga_$(TOP)_summary.txt

clean:
	rm -rf $(OUT)
