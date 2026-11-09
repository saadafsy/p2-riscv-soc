# Vivado batch build for the Basys 3.
#   vivado -mode batch -source fpga/build.tcl -tclargs <firmware.hex> [out_dir]
#   ACCEL=1 vivado ...    full SoC including the attention accelerator
# Writes <out_dir>/basys3_top.bit plus utilization and timing reports; exits 1
# if timing is not met.
if {$argc < 1} { puts "usage: build.tcl <firmware.hex> \[out_dir\]"; exit 1 }
set hex [file normalize [lindex $argv 0]]
set out [expr {$argc > 1 ? [lindex $argv 1] : "build/fpga"}]
set root [file normalize [file join [file dirname [info script]] ..]]
file mkdir $out
file copy -force $hex $out/firmware.hex

create_project -in_memory -part xc7a35tcpg236-1
set srcs {}
foreach f [split [string trim [read [open $root/rtl/core/core.f]]] "\n"] { lappend srcs $root/$f }
# rtl/soc.f: everything outside the core (bus, peripherals, accelerator,
# debug, BIST, clock gate), soc_top last.
foreach f [split [string trim [read [open $root/rtl/soc.f]]] "\n"] { lappend srcs $root/$f }
lappend srcs $root/fpga/basys3_top.sv
# FPGA_XC7 selects BSCANE2 (bscan_jtag_xilinx) and BUFGCE (clk_gate). Not
# XILINX_FPGA: p1's RTL uses that for an XPM ROM that P2 does not include.
read_verilog -sv -define FPGA_XC7 $srcs
set_property include_dirs [list $root/rtl/accel/p1] [current_fileset]
read_xdc $root/fpga/basys3.xdc
# ACCEL=1 in the environment builds the full SoC with the attention accelerator
# (ACCEL_EN=1); synthesis is then held to 72 DSP48 slices so the multipliers
# the cap pushes out go to LUTs, leaving routing room on the 90-DSP XC7A35T.
set accel [expr {[info exists ::env(ACCEL)] && $::env(ACCEL) eq "1"}]
set generics "INIT_FILE=[file normalize $out/firmware.hex]"
if {$accel} { append generics " ACCEL_EN=1'b1" }
set_property generic $generics [current_fileset]
set dsp_opt [expr {$accel ? "-max_dsp 72" : ""}]
synth_design -top basys3_top -part xc7a35tcpg236-1 -define SYNTHESIS -define FPGA_XC7 {*}$dsp_opt
opt_design
place_design
route_design
report_utilization -file $out/util.rpt
report_timing_summary -file $out/timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "setup WNS: $wns ns"
if {$wns < 0} { puts "ERROR: timing not met"; exit 1 }
write_bitstream -force $out/basys3_top.bit
exit 0
