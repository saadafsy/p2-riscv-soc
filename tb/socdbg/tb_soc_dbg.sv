// cocotb top: soc_top with OBI protocol checkers on every link the debug,
// BIST and arbitration logic touches: core data port (in core reset while
// held), JTAG master port, arbiter to decoder, MBIST master, RAM port B.
module tb_soc_dbg #(
  parameter bit          FINISH_ON_EXIT = 1'b0,
  parameter logic [15:0] UART_DIV       = 16'd16
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        accel_clk,
  input  logic        accel_rst,
  input  logic        uart_rx,
  output logic        uart_tx,
  input  logic [20:0] gpio_in,
  output logic [15:0] gpio_out,
  input  logic        dbg_rst,
  input  logic        tck,
  input  logic        trst,
  input  logic        tms,
  input  logic        tdi,
  output logic        tdo,
  output logic        tdo_oe
);
  soc_top #(.FINISH_ON_EXIT(FINISH_ON_EXIT), .UART_DIV(UART_DIV)) u_soc (.*);

  obi_checker chk_core (
    .clk, .rst(u_soc.core_rst), .req(u_soc.d_req), .gnt(u_soc.d_gnt), .addr(u_soc.d_addr),
    .we(u_soc.d_we), .be(u_soc.d_be), .wdata(u_soc.d_wdata), .rvalid(u_soc.d_rvalid)
  );
  obi_checker chk_jtag (
    .clk, .rst, .req(u_soc.dbg_req), .gnt(u_soc.dbg_gnt), .addr(u_soc.dbg_addr),
    .we(u_soc.dbg_we), .be(u_soc.dbg_be), .wdata(u_soc.dbg_wdata), .rvalid(u_soc.dbg_rvalid)
  );
  obi_checker chk_dec (
    .clk, .rst, .req(u_soc.dec_req), .gnt(u_soc.dec_gnt), .addr(u_soc.dec_addr),
    .we(u_soc.dec_we), .be(u_soc.dec_be), .wdata(u_soc.dec_wdata), .rvalid(u_soc.dec_rvalid)
  );
  obi_checker chk_bist (
    .clk, .rst, .req(u_soc.bst_req), .gnt(u_soc.bst_gnt), .addr(u_soc.bst_addr),
    .we(u_soc.bst_we), .be(u_soc.bst_be), .wdata(u_soc.bst_wdata), .rvalid(u_soc.bst_rvalid)
  );
  obi_checker chk_ramb (
    .clk, .rst, .req(u_soc.rb_req), .gnt(u_soc.rb_gnt), .addr(u_soc.rb_addr),
    .we(u_soc.rb_we), .be(u_soc.rb_be), .wdata(u_soc.rb_wdata), .rvalid(u_soc.rb_rvalid)
  );
endmodule
