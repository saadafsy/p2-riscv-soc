// Lint-only stand-ins for the Xilinx 7-series primitives used by
// fpga/basys3_top.sv, rtl/debug/bscan_jtag_xilinx.sv and rtl/clk/clk_gate.sv
// (FPGA_XC7). Ports and parameters as in UG953; behaviour is not modeled.
// verilator lint_off UNUSEDSIGNAL
// verilator lint_off UNUSEDPARAM
// verilator lint_off DECLFILENAME
module MMCME2_BASE #(
  parameter string BANDWIDTH = "OPTIMIZED",
  parameter real CLKFBOUT_MULT_F = 5.0, CLKFBOUT_PHASE = 0.0, CLKIN1_PERIOD = 0.0,
  parameter real CLKOUT0_DIVIDE_F = 1.0, CLKOUT0_DUTY_CYCLE = 0.5, CLKOUT0_PHASE = 0.0,
  parameter real REF_JITTER1 = 0.0,
  parameter int CLKOUT1_DIVIDE = 1, CLKOUT2_DIVIDE = 1, CLKOUT3_DIVIDE = 1, CLKOUT4_DIVIDE = 1,
  parameter int CLKOUT5_DIVIDE = 1, CLKOUT6_DIVIDE = 1, DIVCLK_DIVIDE = 1,
  parameter string CLKOUT4_CASCADE = "FALSE", STARTUP_WAIT = "FALSE"
) (
  input  logic CLKIN1, CLKFBIN, PWRDWN, RST,
  output logic CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
  output logic CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6, LOCKED
);
  assign {CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
          CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = {13{CLKIN1}};
  assign LOCKED = 1'b1;
endmodule

module BUFG (input logic I, output logic O);
  assign O = I;
endmodule

module BUFGCE (input logic I, input logic CE, output logic O);
  assign O = I & CE;
endmodule

module BSCANE2 #(parameter int JTAG_CHAIN = 1) (
  output logic CAPTURE, DRCK, RESET, RUNTEST, SEL, SHIFT, TCK, TDI, TMS, UPDATE,
  input  logic TDO
);
  assign {CAPTURE, DRCK, RESET, RUNTEST, SEL, SHIFT, TCK, TDI, TMS, UPDATE} = '0;
endmodule
// verilator lint_on DECLFILENAME
// verilator lint_on UNUSEDPARAM
// verilator lint_on UNUSEDSIGNAL
