# Lockstep SoC testbench: soc_top vs model/rv32_iss.py on every program in
# build/sw (build them first with scripts/build_sw.sh).
#   make            all programs
#   make PROGS=hello,branch
#   make PROG_DIR=../../build/rand SIM_BUILD=sim_build_rand   (random programs)
SIM ?= verilator
TOPLEVEL_LANG ?= verilog
ROOT := $(abspath ../..)

VERILOG_SOURCES = $(addprefix $(ROOT)/,$(shell cat $(ROOT)/rtl/core/core.f)) \
                  $(ROOT)/rtl/mem/dp_ram.sv \
                  $(ROOT)/rtl/bus/obi_default_slave.sv $(ROOT)/rtl/bus/obi_decoder.sv \
                  $(ROOT)/rtl/bus/apb_mux.sv $(ROOT)/rtl/bus/obi2apb.sv \
                  $(ROOT)/rtl/periph/sync2ff.sv $(ROOT)/rtl/periph/sync_fifo.sv \
                  $(ROOT)/rtl/periph/uart_apb.sv $(ROOT)/rtl/periph/gpio_apb.sv \
                  $(ROOT)/rtl/periph/timer_apb.sv $(ROOT)/rtl/periph/simctrl_apb.sv \
                  $(ROOT)/rtl/bus/obi2axil.sv $(ROOT)/rtl/accel/async_fifo.sv \
                  $(addprefix $(ROOT)/rtl/accel/p1/,mac_unit.sv matmul_tile.sv exp_lut_1p.sv \
                    sync_ram.sv online_softmax.sv attention_top.sv) \
                  $(ROOT)/rtl/accel/attn_seq.sv $(ROOT)/rtl/accel/axil_attn.sv \
                  $(ROOT)/rtl/soc_top.sv
# p1's files include "rtl/exp_lut.svh" (rtl/accel/p1/README.md).
EXTRA_ARGS += +incdir+$(ROOT)/rtl/accel/p1
COCOTB_TOPLEVEL = soc_top
COCOTB_TEST_MODULES = test_soc

# Programs are written into the RAM array at run time, so one build serves all.
EXTRA_ARGS += --public-flat-rw -GFINISH_ON_EXIT=0 -GUART_DIV=16 -Wno-fatal
export PROGS PROG_DIR
export P2_ROOT = $(ROOT)

include $(shell cocotb-config --makefiles)/Makefile.sim
