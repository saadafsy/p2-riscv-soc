export DESIGN_NICKNAME = rv32_core
export DESIGN_NAME     = rv32_core_pd
export PLATFORM        = sky130hd

export VERILOG_FILES = $(addprefix /work/,$(shell grep -vE '^[[:space:]]*(\#|//|$$)' /work/rtl/core/core.f)) \
                       /work/pd/rv32_core/rv32_core_pd.sv
export SDC_FILE      = /work/pd/rv32_core/constraint.sdc

export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
# Repair to 80% of the slew/cap limits so the post-route values stay inside them.
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
