# p2-riscv-soc top-level targets. Tools: oss-cad-suite (verilator, yosys, sby),
# verible, cocotb in the active venv, lowRISC clang in ~/tools/riscv/bin.
#   make all        everything below in order
#   make sw         build ISA tests and C programs (build/sw/<name>/<name>.hex)
#   make model      golden-model unit tests (pytest)
#   make core       core tests (tb/core), lint, formal
#   make periph     peripheral/bus tests, negative checker tests, formal, synth check
#   make soc        full SoC vs the ISS, every program in build/sw
#   make rand       N random programs (default 100) on the SoC vs the ISS
#   make socdbg     JTAG / core hold / MBIST / clock gate: lint, synth check,
#                   arbiter formal, SoC-level cocotb tests (docs/spec.md 13)
export PATH := $(HOME)/tools/riscv/bin:$(HOME)/oss-cad-suite/bin:$(HOME)/tools/verible/bin:$(PATH)
ROOT  := $(abspath .)
N     ?= 100
SEED  ?= 1

.PHONY: all sw model core periph soc rand socdbg dft perf clean
all: sw model core periph soc rand socdbg

sw:
	scripts/build_sw.sh --run

model:
	python3 -m pytest -q model/tests

core: sw
	$(MAKE) -C tb/core
	$(MAKE) -C tb/core lint
	$(MAKE) -C tb/core formal

periph:
	$(MAKE) -C tb/periph all

soc: sw
	$(MAKE) -C tb/soc

rand:
	rm -rf $(ROOT)/build/rand
	python3 model/randgen.py --batch $(N) --seed $(SEED) --length 1500 --build-dir $(ROOT)/build/rand
	$(MAKE) -C tb/soc PROG_DIR=$(ROOT)/build/rand SIM_BUILD=sim_build_rand COCOTB_RESULTS_FILE=results_rand.xml

socdbg: sw
	bash tb/socdbg/lint.sh
	bash tb/socdbg/synth.sh
	cd formal && sby -f arb_bmc.sby
	python3 tb/socdbg/run.py

dft:
	bash dft/run_fault.sh gpio_apb pclk presetn active_low -- rtl/periph/sync2ff.sv rtl/periph/gpio_apb.sv
	bash dft/run_fault.sh timer_apb pclk presetn active_low -- rtl/periph/timer_apb.sv
	bash dft/run_fault.sh uart_apb pclk presetn active_low -- rtl/periph/sync2ff.sv rtl/periph/sync_fifo.sv rtl/periph/uart_apb.sv
	bash dft/run_fault.sh rv32_core_pd clk rst -- $(shell cat rtl/core/core.f) pd/rv32_core/rv32_core_pd.sv

perf:
	mkdir -p build/perf
	g++ -std=c++17 -O2 -Wall -Wextra -o build/perf/p2perf model/perf/p2perf.cpp
	grep -h -o '[a-z_0-9]*: PASS, [0-9]* instructions in [0-9]* cycles' build/full/soc73.log | sort -u > build/perf/rtl_cycles.txt
	python3 model/perf/calibrate.py build/perf/rtl_cycles.txt

clean:
	rm -rf build tb/*/sim_build* tb/*/results*.xml formal/*/ tb/socdbg/build

# Board firmware on the UART pin, decoded in simulation (tb/soc/test_board_uart.py)
board:
	$(MAKE) -C sw board
	$(MAKE) -C tb/soc COCOTB_TEST_MODULES=test_board_uart COCOTB_RESULTS_FILE=results_board_uart.xml
