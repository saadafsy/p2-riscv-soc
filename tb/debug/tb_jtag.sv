// cocotb top: jtag_debug (TAP + debug transport) with the OBI checker on its
// master port. The TAP state and IR are brought out for the FSM tests.
module tb_jtag (
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
  input  logic [31:0] obi_rdata,
  output logic [3:0]  tap_state,
  output logic [4:0]  tap_ir
);
  jtag_debug dbg (.*);

  assign tap_state = dbg.u_tap.state;
  assign tap_ir    = dbg.u_tap.ir;

  obi_checker chk (
    .clk, .rst, .req(obi_req), .gnt(obi_gnt), .addr(obi_addr), .we(obi_we), .be(obi_be),
    .wdata(obi_wdata), .rvalid(obi_rvalid)
  );
endmodule
