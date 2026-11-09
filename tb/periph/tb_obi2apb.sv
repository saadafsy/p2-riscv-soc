// cocotb top: obi2apb alone. APB slaves are modelled in Python on the flat
// prdata/pready vectors so wait states can be scripted per slot.
module tb_obi2apb (
  input  logic         clk,
  input  logic         rst,
  input  logic         req,
  output logic         gnt,
  input  logic [31:0]  addr,
  input  logic         we,
  input  logic [3:0]   be,
  input  logic [31:0]  wdata,
  output logic         rvalid,
  output logic [31:0]  rdata,
  output logic [15:0]  psel,
  output logic         penable,
  output logic         pwrite,
  output logic [11:0]  paddr,
  output logic [31:0]  pwdata,
  output logic [3:0]   pstrb,
  output logic [2:0]   pprot,
  input  logic [511:0] prdata,
  input  logic [15:0]  pready
);
  obi2apb #(.SLV_MASK(16'h8007)) dut (
    .clk, .rst, .req, .gnt, .addr, .we, .be, .wdata, .rvalid, .rdata,
    .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .prdata, .pready
  );
  obi_checker chk_obi (
    .clk, .rst, .req, .gnt, .addr, .we, .be, .wdata, .rvalid
  );
  apb_checker #(.NSEL(16)) chk_apb (
    .clk, .rst, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .pready
  );
endmodule
