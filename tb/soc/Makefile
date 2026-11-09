# Lockstep SoC testbench: soc_top vs model/rv32_iss.py on every program in
# build/sw (build them first with scripts/build_sw.sh).
#   make            all programs
#   make PROGS=hello,branch
#   make PROG_DIR=../../build/rand SIM_BUILD=sim_build_rand   (random programs)
SIM ?= verilator
TOPLEVEL_LANG ?= verilog
ROOT := $(abspath ../..)

# rtl/soc.f lists everything outside the core, soc_top last.
VERILOG_SOURCES = $(addprefix $(ROOT)/,$(shell cat $(ROOT)/rtl/core/core.f)) \
                  $(addprefix $(ROOT)/,$(shell cat $(ROOT)/rtl/soc.f))
# p1's files include "rtl/exp_lut.svh" (rtl/accel/p1/README.md).
EXTRA_ARGS += +incdir+$(ROOT)/rtl/accel/p1
COCOTB_TOPLEVEL = soc_top
COCOTB_TEST_MODULES = test_soc

# Programs are written into the RAM array at run time, so one build serves all.
EXTRA_ARGS += --public-flat-rw -GFINISH_ON_EXIT=0 -GUART_DIV=16 -Wno-fatal
export PROGS PROG_DIR
export P2_ROOT = $(ROOT)

include $(shell cocotb-config --makefiles)/Makefile.sim
