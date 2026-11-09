# March C- MBIST verification. Needs oss-cad-suite, verible and the cocotb
# venv on PATH.
#   make test     cocotb bench, AW=5/NBG=6 and AW=4/NBG=1 (assertions on)
#   make lint | all | clean

PY ?= python
.PHONY: all test lint clean

all: lint test

test:
	$(PY) run.py $(CONFIG)

lint:
	bash lint.sh

clean:
	rm -rf build __pycache__
