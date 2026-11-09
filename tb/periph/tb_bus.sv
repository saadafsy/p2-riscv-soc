// cocotb top: the data-side memory system. obi_decoder routes to dp_ram
// port B, obi2apb (UART, GPIO, TIMER, SIMCTRL) and its default slave.
// Port A of the RAM stays open for instruction-side tests. Checkers sit on
// every OBI link and on the APB bus.
module tb_bus (
  input  logic        clk,
  input  logic        rst,
  // core data port
  input  logic        m_req,
  output logic        m_gnt,
  input  logic [31:0] m_addr,
  input  logic        m_we,
  input  logic [3:0]  m_be,
  input  logic [31:0] m_wdata,
  output logic        m_rvalid,
  output logic [31:0] m_rdata,
  // core instruction port
  input  logic        i_req,
  output logic        i_gnt,
  input  logic [31:0] i_addr,
  output logic        i_rvalid,
  output logic [31:0] i_rdata,
  // pins
  input  logic        uart_rx,
  output logic        uart_tx,
  output logic        uart_irq,
  input  logic [20:0] gpio_in,
  output logic [15:0] gpio_out,
  output logic        irq_timer
);
  logic        ram_req, ram_gnt, ram_we, ram_rvalid;
  logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic [3:0]  ram_be;
  logic        br_req, br_gnt, br_we, br_rvalid;
  logic [31:0] br_addr, br_wdata, br_rdata;
  logic [3:0]  br_be;

  logic [15:0]       psel, pready;
  logic              penable, pwrite;
  logic [11:0]       paddr;
  logic [31:0]       pwdata;
  logic [3:0]        pstrb;
  logic [2:0]        pprot;
  logic [15:0][31:0] prdata;

  obi_decoder u_dec (
    .clk, .rst,
    .m_req, .m_gnt, .m_addr, .m_we, .m_be, .m_wdata, .m_rvalid, .m_rdata,
    .ram_req, .ram_gnt, .ram_addr, .ram_we, .ram_be, .ram_wdata, .ram_rvalid, .ram_rdata,
    .apb_req(br_req), .apb_gnt(br_gnt), .apb_addr(br_addr), .apb_we(br_we),
    .apb_be(br_be), .apb_wdata(br_wdata), .apb_rvalid(br_rvalid), .apb_rdata(br_rdata)
  );

  dp_ram #(.AW(14)) u_ram (
    .clk, .rst,
    .a_req(i_req), .a_gnt(i_gnt), .a_addr(i_addr), .a_rvalid(i_rvalid), .a_rdata(i_rdata),
    .b_req(ram_req), .b_gnt(ram_gnt), .b_addr(ram_addr), .b_we(ram_we), .b_be(ram_be),
    .b_wdata(ram_wdata), .b_rvalid(ram_rvalid), .b_rdata(ram_rdata)
  );

  obi2apb u_br (
    .clk, .rst,
    .req(br_req), .gnt(br_gnt), .addr(br_addr), .we(br_we), .be(br_be), .wdata(br_wdata),
    .rvalid(br_rvalid), .rdata(br_rdata),
    .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .prdata, .pready
  );

  // Unpopulated slots: the bridge never selects them (SLV_MASK).
  for (genvar s = 3; s < 15; s++) begin : g_tie
    assign prdata[s] = '0;
    assign pready[s] = 1'b1;
  end

  logic [3:0] unused_slverr;

  uart_apb #(.DIV_RESET(16'd868)) u_uart (
    .pclk(clk), .presetn(!rst), .psel(psel[0]), .penable, .pwrite, .paddr, .pwdata, .pstrb,
    .pprot, .prdata(prdata[0]), .pready(pready[0]), .pslverr(unused_slverr[0]),
    .rx(uart_rx), .tx(uart_tx), .irq(uart_irq)
  );
  gpio_apb u_gpio (
    .pclk(clk), .presetn(!rst), .psel(psel[1]), .penable, .pwrite, .paddr, .pwdata, .pstrb,
    .pprot, .prdata(prdata[1]), .pready(pready[1]), .pslverr(unused_slverr[1]),
    .gpio_in, .gpio_out
  );
  timer_apb u_timer (
    .pclk(clk), .presetn(!rst), .psel(psel[2]), .penable, .pwrite, .paddr, .pwdata, .pstrb,
    .pprot, .prdata(prdata[2]), .pready(pready[2]), .pslverr(unused_slverr[2]), .irq_timer
  );
  simctrl_apb #(.FINISH_ON_EXIT(1'b0)) u_sim (
    .pclk(clk), .presetn(!rst), .psel(psel[15]), .penable, .pwrite, .paddr, .pwdata, .pstrb,
    .pprot, .prdata(prdata[15]), .pready(pready[15]), .pslverr(unused_slverr[3])
  );

  obi_checker chk_core (
    .clk, .rst, .req(m_req), .gnt(m_gnt), .addr(m_addr), .we(m_we), .be(m_be),
    .wdata(m_wdata), .rvalid(m_rvalid)
  );
  obi_checker chk_ifetch (
    .clk, .rst, .req(i_req), .gnt(i_gnt), .addr(i_addr), .we(1'b0), .be(4'hF),
    .wdata(32'd0), .rvalid(i_rvalid)
  );
  obi_checker chk_ram (
    .clk, .rst, .req(ram_req), .gnt(ram_gnt), .addr(ram_addr), .we(ram_we), .be(ram_be),
    .wdata(ram_wdata), .rvalid(ram_rvalid)
  );
  obi_checker chk_br (
    .clk, .rst, .req(br_req), .gnt(br_gnt), .addr(br_addr), .we(br_we), .be(br_be),
    .wdata(br_wdata), .rvalid(br_rvalid)
  );
  apb_checker #(.NSEL(16)) chk_apb (
    .clk, .rst, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .pready
  );
endmodule
