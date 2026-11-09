# Vivado batch build for the Basys 3.
#   vivado -mode batch -source fpga/build.tcl -tclargs <firmware.hex> [out_dir]
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
lappend srcs {*}[glob $root/rtl/mem/*.sv $root/rtl/bus/obi_*.sv $root/rtl/bus/apb_mux.sv \
                       $root/rtl/periph/*.sv] $root/rtl/soc_top.sv $root/fpga/basys3_top.sv
read_verilog -sv $srcs
read_xdc $root/fpga/basys3.xdc
set_property generic "INIT_FILE=[file normalize $out/firmware.hex]" [current_fileset]
synth_design -top basys3_top -part xc7a35tcpg236-1 -define SYNTHESIS
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
