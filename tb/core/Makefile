# rv32_core cocotb tests (Verilator).
#   make            run all tests
#   make lint       verilator -Wall and verible on rtl/core
#   make formal     SymbiYosys BMC/cover tasks in formal/core_bmc.sby
#   make progs      assemble tb/core/progs/*.S only
# Needs oss-cad-suite, verible and the lowRISC clang (~/tools/riscv/bin) on PATH.

PROJ := $(abspath $(CURDIR)/../..)
CORE_SRCS := $(addprefix $(PROJ)/,$(shell cat $(PROJ)/rtl/core/core.f))

SIM ?= verilator
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CORE_SRCS)
COCOTB_TOPLEVEL = rv32_core
COCOTB_TEST_MODULES = test_core
export PYTHONPATH := $(CURDIR):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: lint formal progs
lint:
	verilator --lint-only -Wall --top-module rv32_core $(CORE_SRCS)
	verible-verilog-lint --rules=line-length=length:100 $(CORE_SRCS)

formal:
	cd $(PROJ)/formal && sby -f core_bmc.sby

progs:
	python3 build_progs.py

clean::
	rm -rf build results.xml
