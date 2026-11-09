# APB peripheral subsystem UVM bench (Verilator 5.053 + Accellera UVM 2017).
#   make smoke                 directed test, seed 1
#   make random  SEED=n        constrained-random test
#   make stress  SEED=n        back-to-back stress test
#   make regress SEEDS="1 2 3" smoke + random and stress per seed, summary table
#   make bug                   injected bugs must be caught (see README)
#   make clean
# NUM_TXN=<n> overrides the per-test transaction count. JOBS caps the build.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
SEED  ?= 1
SEEDS ?= 1 2 3 4 5
JOBS  ?= 4
export JOBS
OUT   := $(CURDIR)/build/runs
RUN   := bash scripts/run.sh
EXTRA := $(if $(NUM_TXN),+NUM_TXN=$(NUM_TXN))

.PHONY: smoke random stress regress bug clean

smoke:
	$(RUN) p2_smoke_test $(SEED) $(OUT)/smoke_s$(SEED)
	@bash scripts/summary.sh $(OUT)/smoke_s$(SEED)

random:
	$(RUN) p2_random_test $(SEED) $(OUT)/random_s$(SEED) $(EXTRA)
	@bash scripts/summary.sh $(OUT)/random_s$(SEED)

stress:
	$(RUN) p2_stress_test $(SEED) $(OUT)/stress_s$(SEED) $(EXTRA)
	@bash scripts/summary.sh $(OUT)/stress_s$(SEED)

# Every run executes even if an earlier one failed; summary.sh exits 1 if any failed.
regress:
	@rm -rf $(OUT)/regress; dirs="$(OUT)/regress/smoke_s1"; \
	$(RUN) p2_smoke_test 1 $(OUT)/regress/smoke_s1 || true; \
	for s in $(SEEDS); do \
	  $(RUN) p2_random_test $$s $(OUT)/regress/random_s$$s $(EXTRA) || true; \
	  $(RUN) p2_stress_test $$s $(OUT)/regress/stress_s$$s $(EXTRA) || true; \
	  dirs="$$dirs $(OUT)/regress/random_s$$s $(OUT)/regress/stress_s$$s"; \
	done; \
	rc=0; bash scripts/summary.sh $$dirs || rc=1; \
	dats=$$(for d in $$dirs; do [ -f $$d/coverage.dat ] && echo $$d/coverage.dat; done); \
	PATH=$$HOME/oss-cad-suite/bin:$$PATH verilator_coverage --write $(OUT)/regress/merged.dat $$dats; \
	echo "merged coverage over $$(echo $$dats | wc -w) runs (verilator_coverage --write)"; \
	echo "verilator_coverage --report summary (RTL plus bench class files):"; \
	PATH=$$HOME/oss-cad-suite/bin:$$PATH verilator_coverage --report summary $(OUT)/regress/merged.dat | grep -E "line|toggle|covergroup"; \
	python3 -I scripts/covsum.py $(OUT)/regress/merged.dat; \
	exit $$rc

# Each leg MUST fail, and for the right reason:
#   strb   bridge ignores byte enables (protocol-legal): the scoreboard must
#          report APB field mismatches AND wrong OBI read data, with no
#          assertion involved.
#   proto  pwdata changes during ACCESS: apb_checker A5 must fire.
#   obi    bench drives wdata changes before gnt: obi_checker M1 must fire.
bug:
	@set -e; fail=0; \
	if $(RUN) p2_random_test $(SEED) $(OUT)/bug_strb --bug strb +NUM_TXN=600; then \
	  echo "BUG strb : NOT CAUGHT (run passed)"; fail=1; \
	else L=$(OUT)/bug_strb/sim.log; \
	  f=$$(sed -n 's/.*mismatches: total=[0-9]* apb_fields=\([0-9]*\).*/\1/p' $$L); \
	  r=$$(sed -n 's/.*obi_rdata=\([0-9]*\).*/\1/p' $$L); \
	  if grep -q "u_apb_chk\|u_obi_chk" $$L; then echo "BUG strb : a protocol checker fired; expected scoreboard only"; fail=1; \
	  elif [ "$${f:-0}" -gt 0 ] && [ "$${r:-0}" -gt 0 ]; then \
	    echo "BUG strb : CAUGHT by scoreboard (apb_fields=$$f obi_rdata=$$r mismatches, no assertion)"; \
	  else echo "BUG strb : run failed but not by scoreboard mismatches (f=$$f r=$$r)"; fail=1; fi; \
	fi; \
	if $(RUN) p2_random_test $(SEED) $(OUT)/bug_proto --bug proto +NUM_TXN=600; then \
	  echo "BUG proto: NOT CAUGHT (run passed)"; fail=1; \
	elif grep -q "apb_a5_stable\|u_apb_chk" $(OUT)/bug_proto/sim.log; then \
	  echo "BUG proto: CAUGHT by bound apb_checker ($$(grep -m1 -o 'Assertion failed in [^:]*' $(OUT)/bug_proto/sim.log))"; \
	else echo "BUG proto: run failed but apb_checker did not report"; fail=1; fi; \
	if $(RUN) p2_random_test $(SEED) $(OUT)/bug_obi --bug obi +NUM_TXN=600; then \
	  echo "BUG obi  : NOT CAUGHT (run passed)"; fail=1; \
	elif grep -q "obi_m1_hold\|u_obi_chk" $(OUT)/bug_obi/sim.log; then \
	  echo "BUG obi  : CAUGHT by bound obi_checker ($$(grep -m1 -o 'Assertion failed in [^:]*' $(OUT)/bug_obi/sim.log))"; \
	else echo "BUG obi  : run failed but obi_checker did not report"; fail=1; fi; \
	if [ $$fail = 0 ]; then echo "BUG GATE PASS: all injected bugs caught"; else echo "BUG GATE FAIL"; exit 1; fi

clean:
	rm -rf build
