current_design rv32_core_pd
set clk_period 10.0
create_clock -name core_clock -period $clk_period [get_ports clk]
# The OBI ports meet the bus decoder and the RAM in soc_top; d_rdata/i_rdata
# arrive from the RAM output register, so 20% of the period is budgeted on
# each side of the core boundary.
set_input_delay  [expr {$clk_period * 0.2}] -clock core_clock [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay [expr {$clk_period * 0.2}] -clock core_clock [all_outputs]
