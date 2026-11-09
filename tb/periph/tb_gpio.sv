// cocotb top: gpio_apb with the APB checker on its port.
module tb_gpio (
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
  input  logic [20:0] gpio_in,
  output logic [15:0] gpio_out
);
  gpio_apb dut (
    .pclk(clk), .presetn(!rst), .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot,
    .prdata, .pready, .pslverr, .gpio_in, .gpio_out
  );
  apb_checker #(.NSEL(1)) chk_apb (
    .clk, .rst, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .pready
  );
endmodule
