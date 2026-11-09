// cocotb top: dp_ram with OBI checkers on both ports.
module tb_dp_ram #(
  parameter int AW = 10,
  // verilog_lint: waive explicit-parameter-storage-type
  parameter     INIT_FILE = ""
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        a_req,
  output logic        a_gnt,
  input  logic [31:0] a_addr,
  output logic        a_rvalid,
  output logic [31:0] a_rdata,
  input  logic        b_req,
  output logic        b_gnt,
  input  logic [31:0] b_addr,
  input  logic        b_we,
  input  logic [3:0]  b_be,
  input  logic [31:0] b_wdata,
  output logic        b_rvalid,
  output logic [31:0] b_rdata
);
  dp_ram #(.AW(AW), .INIT_FILE(INIT_FILE)) dut (.*);

  obi_checker chk_a (
    .clk, .rst, .req(a_req), .gnt(a_gnt), .addr(a_addr), .we(1'b0), .be(4'hF),
    .wdata(32'd0), .rvalid(a_rvalid)
  );
  obi_checker chk_b (
    .clk, .rst, .req(b_req), .gnt(b_gnt), .addr(b_addr), .we(b_we), .be(b_be),
    .wdata(b_wdata), .rvalid(b_rvalid)
  );
endmodule
