# JTAG debug port verification. Needs oss-cad-suite, verible and the cocotb
# venv on PATH.
#   make test     cocotb bench (assertions on)
#   make formal   SymbiYosys: TAP (prove, bmc, cover), CDC handshake (bmc, cover)
#   make lint | all | clean

PY ?= python
.PHONY: all test formal lint clean

all: lint test formal

test:
	$(PY) run.py

formal:
	cd ../../formal && sby -f debug_tap.sby && sby -f debug_cdc.sby

lint:
	bash lint.sh

clean:
	cd ../../formal && rm -rf debug_tap_prove debug_tap_bmc debug_tap_cover \
		debug_cdc_bmc debug_cdc_cover
	rm -rf build __pycache__
