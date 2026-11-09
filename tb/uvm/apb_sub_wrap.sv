`timescale 1ns / 1ps
// apb_sub_wrap: DUT for the UVM bench. obi2apb (default SLV_MASK 0x8007) and
// the four APB4 slaves of spec 8: slot 0 uart_apb, 1 gpio_apb, 2 timer_apb,
// 15 simctrl_apb (FINISH_ON_EXIT = 0, so EXIT writes are observed, not fatal).
// Slots 3..14 are tied off (prdata 0, pready 1); the bridge never selects them.
//
// Wait-state injection (testbench adapter, not RTL): the slaves are all
// pready = 1, so to exercise waited ACCESS phases the bench drives `stall`.
// While stall is high the bridge sees pready = 0 and the slaves see
// penable = 0 (an extended SETUP from their point of view), so a slave acts
// exactly once, in the cycle its ACCESS completes. The m_* outputs are the
// bus as the bridge drives and sees it (bridge penable, gated pready), which
// is what the APB monitor and apb_checker observe.
//
// Injected bugs (tb/uvm only, the RTL is untouched):
//   INJECT_BUG_STRB   shim between bridge and slaves turns any nonzero pstrb
//                     into 4'b1111: a bridge that ignores byte enables.
//                     Protocol stays legal; only the scoreboard can see it.
//   INJECT_BUG_PROTO  pwdata bit 0 flips in the ACCESS phase of writes:
//                     violates APB A5 (pwdata stable SETUP..pready).
module apb_sub_wrap (
  input  logic              clk,
  input  logic              rst,
  // OBI slave side
  input  logic              req,
  output logic              gnt,
  input  logic [31:0]       addr,
  input  logic              we,
  input  logic [3:0]        be,
  input  logic [31:0]       wdata,
  output logic              rvalid,
  output logic [31:0]       rdata,
  // wait-state request from the bench
  input  logic              apb_stall,
  // APB bus taps
  output logic [15:0]       m_psel,
  output logic              m_penable,
  output logic              m_pwrite,
  output logic [11:0]       m_paddr,
  output logic [31:0]       m_pwdata,
  output logic [3:0]        m_pstrb,
  output logic [2:0]        m_pprot,
  output logic [15:0][31:0] m_prdata,
  output logic [15:0]       m_pready,
  // pins
  input  logic              uart_rx,
  output logic              uart_tx,
  output logic              uart_irq,
  input  logic [20:0]       gpio_in,
  output logic [15:0]       gpio_out,
  output logic              irq_timer,
  // simctrl taps
  output logic              sim_exit_seen,
  output logic [31:0]       sim_exit_code,
  output logic [15:0]       sim_putc_count
);
  logic [31:0] pwdata_br;
  logic [3:0]  pstrb_br;
  logic [15:0] pready_s;
  logic        penable_s;
  logic [3:0]  unused_slverr;

  obi2apb u_br (
    .clk, .rst,
    .req, .gnt, .addr, .we, .be, .wdata, .rvalid, .rdata,
    .psel(m_psel), .penable(m_penable), .pwrite(m_pwrite), .paddr(m_paddr),
    .pwdata(pwdata_br), .pstrb(pstrb_br), .pprot(m_pprot),
    .prdata(m_prdata), .pready(m_pready)
  );

`ifdef INJECT_BUG_STRB
  assign m_pstrb = (pstrb_br != 4'b0000) ? 4'b1111 : 4'b0000;
`else
  assign m_pstrb = pstrb_br;
`endif
`ifdef INJECT_BUG_PROTO
  assign m_pwdata = pwdata_br ^ {31'd0, m_penable & m_pwrite};
`else
  assign m_pwdata = pwdata_br;
`endif

  assign m_pready  = pready_s & {16{!apb_stall}};
  assign penable_s = m_penable & !apb_stall;

  for (genvar s = 3; s < 15; s++) begin : g_tie
    assign m_prdata[s] = '0;
    assign pready_s[s] = 1'b1;
  end

  uart_apb #(.DIV_RESET(16'd868)) u_uart (
    .pclk(clk), .presetn(!rst), .psel(m_psel[0]), .penable(penable_s), .pwrite(m_pwrite),
    .paddr(m_paddr), .pwdata(m_pwdata), .pstrb(m_pstrb), .pprot(m_pprot),
    .prdata(m_prdata[0]), .pready(pready_s[0]), .pslverr(unused_slverr[0]),
    .rx(uart_rx), .tx(uart_tx), .irq(uart_irq)
  );

  gpio_apb u_gpio (
    .pclk(clk), .presetn(!rst), .psel(m_psel[1]), .penable(penable_s), .pwrite(m_pwrite),
    .paddr(m_paddr), .pwdata(m_pwdata), .pstrb(m_pstrb), .pprot(m_pprot),
    .prdata(m_prdata[1]), .pready(pready_s[1]), .pslverr(unused_slverr[1]),
    .gpio_in, .gpio_out
  );

  timer_apb u_timer (
    .pclk(clk), .presetn(!rst), .psel(m_psel[2]), .penable(penable_s), .pwrite(m_pwrite),
    .paddr(m_paddr), .pwdata(m_pwdata), .pstrb(m_pstrb), .pprot(m_pprot),
    .prdata(m_prdata[2]), .pready(pready_s[2]), .pslverr(unused_slverr[2]),
    .irq_timer
  );

  simctrl_apb #(.FINISH_ON_EXIT(1'b0)) u_sim (
    .pclk(clk), .presetn(!rst), .psel(m_psel[15]), .penable(penable_s), .pwrite(m_pwrite),
    .paddr(m_paddr), .pwdata(m_pwdata), .pstrb(m_pstrb), .pprot(m_pprot),
    .prdata(m_prdata[15]), .pready(pready_s[15]), .pslverr(unused_slverr[3])
  );

  assign sim_exit_seen  = u_sim.exit_seen;
  assign sim_exit_code  = u_sim.exit_code;
  assign sim_putc_count = u_sim.putc_count;
endmodule
