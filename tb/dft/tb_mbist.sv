// cocotb top: mbist_marchc on fault_mem, OBI checker on the link.
module tb_mbist #(
  parameter int AW  = 6,
  parameter int NBG = 6
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          start,
  output logic          busy,
  output logic          done,
  output logic          fail,
  output logic [31:0]   fail_addr,
  output logic [2:0]    fail_elem,
  output logic [2:0]    fail_bg,
  output logic [31:0]   fail_syn,
  input  logic          gnt_ok,
  input  logic          rsp_ok,
  input  logic          clr,
  input  logic [3:0]    f_type,
  input  logic [AW-1:0] f_vaddr,
  input  logic [4:0]    f_vbit,
  input  logic [AW-1:0] f_aaddr,
  input  logic [4:0]    f_abit,
  input  logic          f_up,
  input  logic          f_val,
  output logic [31:0]   n_access
);
  logic        req, gnt, we, rvalid;
  logic [31:0] addr, wdata, rdata;
  logic [3:0]  be;

  mbist_marchc #(.AW(AW), .BASE(32'h0000_0000), .NBG(NBG)) dut (
    .clk, .rst, .start, .busy, .done, .fail, .fail_addr, .fail_elem, .fail_bg, .fail_syn,
    .obi_req(req), .obi_gnt(gnt), .obi_addr(addr), .obi_we(we), .obi_be(be),
    .obi_wdata(wdata), .obi_rvalid(rvalid), .obi_rdata(rdata)
  );

  fault_mem #(.AW(AW)) mem (
    .clk, .rst, .req, .gnt, .addr, .we, .be, .wdata, .rvalid, .rdata,
    .gnt_ok, .rsp_ok, .clr, .f_type, .f_vaddr, .f_vbit, .f_aaddr, .f_abit, .f_up, .f_val
  );

  obi_checker chk (.clk, .rst, .req, .gnt, .addr, .we, .be, .wdata, .rvalid);

  // Access count, to check the 10 * 2^AW * NBG figure.
  always_ff @(posedge clk) begin
    if (rst || (start && !busy)) n_access <= '0;
    else if (req && gnt)         n_access <= n_access + 1;
  end
endmodule
