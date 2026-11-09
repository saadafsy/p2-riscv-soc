# axil_attn unit tests (cocotb, Verilator): AXI4-Lite protocol with
# back-pressure, register map, full attention runs against p1 model/attn.py,
# with unrelated system and accelerator clocks.
#   make            check + lint + the tests at two clock ratios + formal
#   make tests      the tests at 100/73 and 100/137 MHz
#   make sim ACCEL_PERIOD_PS=7300   one ratio (system clock is 10 ns)
#   make check      rtl/accel/p1 byte-identical to p1, LUT header up to date
#   make lint | synth | formal
SIM ?= verilator
TOPLEVEL_LANG ?= verilog
ROOT := $(abspath ../..)
P1_ROOT ?= /home/saad/p1-attention
P1_COMMIT := 86d497c56a39a8364c21f87758da95bae349f767

VERILOG_SOURCES = $(ROOT)/rtl/periph/sync2ff.sv $(ROOT)/rtl/accel/async_fifo.sv \
                  $(addprefix $(ROOT)/rtl/accel/p1/,mac_unit.sv matmul_tile.sv exp_lut_1p.sv \
                    sync_ram.sv online_softmax.sv attention_top.sv) \
                  $(ROOT)/rtl/accel/attn_seq.sv $(ROOT)/rtl/accel/axil_attn.sv
COCOTB_TOPLEVEL = axil_attn
COCOTB_TEST_MODULES = test_axil_attn
EXTRA_ARGS += +incdir+$(ROOT)/rtl/accel/p1 -Wno-fatal
export P1_ROOT ACCEL_PERIOD_PS

.DEFAULT_GOAL := all
.PHONY: all tests check lint synth formal
all: check lint synth tests formal

tests:
	$(MAKE) sim ACCEL_PERIOD_PS=13698 COCOTB_RESULTS_FILE=results_73.xml
	$(MAKE) sim ACCEL_PERIOD_PS=7300 COCOTB_RESULTS_FILE=results_137.xml
	@python3 -c "import sys, pathlib; from cocotb_tools.check_results import get_results as g; \
	  r = [g(pathlib.Path(f)) for f in ('results_73.xml', 'results_137.xml')]; \
	  print('tests, failures:', r); \
	  sys.exit(any(f for _, f in r))"

check:
	@set -e; for f in mac_unit.sv matmul_tile.sv exp_lut_1p.sv sync_ram.sv online_softmax.sv \
	    attention_top.sv rtl/exp_lut.svh; do \
	  src=rtl/$$(basename $$f); \
	  git -C $(P1_ROOT) show $(P1_COMMIT):$$src | cmp -s - $(ROOT)/rtl/accel/p1/$$f \
	    || { echo "rtl/accel/p1/$$f differs from p1 $(P1_COMMIT):$$src"; exit 1; }; \
	done; echo "rtl/accel/p1: byte-identical to p1 $(P1_COMMIT)"
	python3 gen_lut_h.py $(P1_ROOT) --check

lint:
	bash lint.sh

synth:
	bash synth.sh

formal:
	cd $(ROOT)/formal && sby -f accel_fifo.sby

include $(shell cocotb-config --makefiles)/Makefile.sim
