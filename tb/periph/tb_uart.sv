// cocotb top: uart_apb with the APB checker on its port.
module tb_uart (
  input  logic        clk,
  input  logic        rst,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic [2:0]  pprot,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  input  logic        rx,
  output logic        tx,
  output logic        irq
);
  uart_apb #(.DIV_RESET(16'd868)) dut (
    .pclk(clk), .presetn(!rst), .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot,
    .prdata, .pready, .pslverr, .rx, .tx, .irq
  );
  apb_checker #(.NSEL(1)) chk_apb (
    .clk, .rst, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .pready
  );
endmodule
