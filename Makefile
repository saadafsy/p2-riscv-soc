# p2-riscv-soc top-level targets. Tools: oss-cad-suite (verilator, yosys, sby),
# verible, cocotb in the active venv, lowRISC clang in ~/tools/riscv/bin.
#   make all        everything below in order
#   make sw         build ISA tests and C programs (build/sw/<name>/<name>.hex)
#   make model      golden-model unit tests (pytest)
#   make core       core tests (tb/core), lint, formal
#   make periph     peripheral/bus tests, negative checker tests, formal, synth check
#   make soc        full SoC vs the ISS, every program in build/sw
#   make rand       N random programs (default 100) on the SoC vs the ISS
export PATH := $(HOME)/tools/riscv/bin:$(HOME)/oss-cad-suite/bin:$(HOME)/tools/verible/bin:$(PATH)
ROOT  := $(abspath .)
N     ?= 100
SEED  ?= 1

.PHONY: all sw model core periph soc rand clean
all: sw model core periph soc rand

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

clean:
	rm -rf build tb/*/sim_build* tb/*/results*.xml formal/*/
