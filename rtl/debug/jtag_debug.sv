// Board-pin JTAG debug port: jtag_tap + jtag_obi_master. Use this when TCK,
// TMS, TDI and TDO come from pins; on the Basys 3 USB-JTAG use
// bscan_jtag_xilinx instead (the FPGA's own TAP replaces jtag_tap).
module jtag_debug #(
  parameter logic [31:0] IDCODE  = 32'h1050_2001,
  parameter logic [4:0]  USER_IR = 5'h18
) (
  input  logic        tck,
  input  logic        trst,
  input  logic        tms,
  input  logic        tdi,
  output logic        tdo,
  output logic        tdo_oe,

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
  logic user_sel, user_capture, user_shift, user_update, user_tdi, user_tdo;
  logic [3:0] tap_state;
  logic [4:0] tap_ir;

  jtag_tap #(.IDCODE(IDCODE), .USER_IR(USER_IR)) u_tap (
    .tck, .trst, .tms, .tdi, .tdo, .tdo_oe,
    .user_sel, .user_capture, .user_shift, .user_update, .user_tdi, .user_tdo,
    .state(tap_state), .ir(tap_ir)
  );

  jtag_obi_master u_dtm (
    .tck, .trst,
    .user_sel, .user_capture, .user_shift, .user_update, .user_tdi, .user_tdo,
    .clk, .rst,
    .obi_req, .obi_gnt, .obi_addr, .obi_we, .obi_be, .obi_wdata, .obi_rvalid, .obi_rdata
  );

  logic unused;
  assign unused = ^{tap_state, tap_ir};
endmodule
