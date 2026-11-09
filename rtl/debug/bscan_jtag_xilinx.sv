// FPGA-only: reach jtag_obi_master through the 7-series BSCANE2 primitive,
// so the Basys 3 USB-JTAG cable (the one Vivado programs with) can drive the
// debug transport. Select it with the Xilinx USER<JTAG_CHAIN> instruction
// (USER4 = IR 6'h23 on the XC7A35T, 6-bit IR) instead of jtag_tap's USER_IR;
// the 66-bit DR protocol is unchanged (rtl/debug/README.md).
//
// UNTESTED on a board: compiled only for the FPGA (FPGA_XC7 defined; not
// XILINX_FPGA, which p1's RTL uses for its XPM ROM). Linted against stubs.
//
// BSCANE2 CAPTURE/SHIFT/UPDATE fire for any DR scan; jtag_obi_master gates
// them with SEL. The tck-domain flops get no reset here (trst tied low):
// BSCANE2 RESET is Test-Logic-Reset, which must not reset the CDC toggle
// (see cdc_req_ack), and the bitstream initializes every flop to 0.
`ifdef FPGA_XC7
module bscan_jtag_xilinx #(
  parameter int JTAG_CHAIN = 4
) (
  input  logic        clk,
  input  logic        rst,
  output logic        obi_req,
  input  logic        obi_gnt,
  output logic [31:0] obi_addr,
  output logic        obi_we,
  output logic [3:0]  obi_be,
  output logic [31:0] obi_wdata,
  input  logic        obi_rvalid,
  input  logic [31:0] obi_rdata
);
  logic tck_raw, tck, sel, capture, shift, update, tdi, tdo;

  BSCANE2 #(.JTAG_CHAIN(JTAG_CHAIN)) u_bscan (
    .CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
    .TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo)
  );

  // TCK drives a clock net; constrain it as its own asynchronous clock.
  BUFG u_tck_bufg (.I(tck_raw), .O(tck));

  jtag_obi_master u_dtm (
    .tck, .trst(1'b0),
    .user_sel(sel), .user_capture(capture), .user_shift(shift), .user_update(update),
    .user_tdi(tdi), .user_tdo(tdo),
    .clk, .rst,
    .obi_req, .obi_gnt, .obi_addr, .obi_we, .obi_be, .obi_wdata, .obi_rvalid, .obi_rdata
  );
endmodule
`endif
