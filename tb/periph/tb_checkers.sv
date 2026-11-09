// cocotb top for negative tests: both checkers driven directly by Python.
module tb_checkers (
  input logic        clk,
  input logic        rst,
  input logic        req,
  input logic        gnt,
  input logic [31:0] addr,
  input logic        we,
  input logic [3:0]  be,
  input logic [31:0] wdata,
  input logic        rvalid,
  input logic [3:0]  psel,
  input logic        penable,
  input logic        pwrite,
  input logic [11:0] paddr,
  input logic [31:0] pwdata,
  input logic [3:0]  pstrb,
  input logic [2:0]  pprot,
  input logic [3:0]  pready
);
  obi_checker chk_obi (.*);
  apb_checker #(.NSEL(4)) chk_apb (.*);
endmodule
