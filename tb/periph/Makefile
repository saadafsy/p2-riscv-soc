# Bus, peripheral and RAM verification. Needs oss-cad-suite, verible and the
# cocotb venv on PATH.
#   make test            all cocotb benches (assertions on) + negative checker tests
#   make test BENCH=uart one bench: uart gpio timer simctrl dp_ram obi2apb bus neg
#   make formal          SymbiYosys BMC + cover on obi_decoder + obi2apb
#   make lint | synth | all | clean

PY ?= python
.PHONY: all test formal lint synth clean

all: lint test formal synth

test:
	$(PY) run.py $(BENCH)

formal:
	cd ../../formal && sby -f bus_bmc.sby

lint:
	bash lint.sh

synth:
	bash synth.sh

clean:
	rm -rf build __pycache__ ../../formal/bus_bmc_bmc ../../formal/bus_bmc_cover
