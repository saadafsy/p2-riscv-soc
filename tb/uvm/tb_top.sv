`timescale 1ns / 1ps
// tb_top: APB subsystem UVM top. Test from +UVM_TESTNAME (read here: a
// UVM_NO_DPI build cannot read it inside run_test). final turns any
// UVM_ERROR/UVM_FATAL into $fatal so the simulator exits nonzero.
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import p2_uvm_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;  // 100 MHz

  initial begin
    repeat (8) @(posedge clk);
    rst <= 1'b0;
  end

  obi_if oif (.clk(clk), .rst(rst));
  apb_if aif (.clk(clk), .rst(rst));

  apb_sub_wrap dut (
    .clk, .rst,
    .req(oif.req), .gnt(oif.gnt), .addr(oif.addr), .we(oif.we), .be(oif.be),
    .wdata(oif.wdata), .rvalid(oif.rvalid), .rdata(oif.rdata),
    .apb_stall(aif.stall),
    .m_psel(aif.psel), .m_penable(aif.penable), .m_pwrite(aif.pwrite), .m_paddr(aif.paddr),
    .m_pwdata(aif.pwdata), .m_pstrb(aif.pstrb), .m_pprot(aif.pprot),
    .m_prdata(aif.prdata), .m_pready(aif.pready),
    .uart_rx(aif.uart_rx), .uart_tx(aif.uart_tx), .uart_irq(aif.uart_irq),
    .gpio_in(aif.gpio_in), .gpio_out(aif.gpio_out), .irq_timer(aif.irq_timer),
    .sim_exit_seen(aif.sim_exit_seen), .sim_exit_code(aif.sim_exit_code),
    .sim_putc_count(aif.sim_putc_count)
  );

  string tn;
  initial begin
    uvm_config_db#(virtual obi_if)::set(null, "*", "obi_vif", oif);
    uvm_config_db#(virtual apb_if)::set(null, "*", "apb_vif", aif);
    if ($value$plusargs("UVM_TESTNAME=%s", tn)) run_test(tn);
    else run_test();
  end

  // watchdog: 20 ms of simulated time (2M cycles)
  initial begin
    #20ms;
    $fatal(1, "tb_top: watchdog timeout");
  end

  final begin
    uvm_report_server srv;
    int errs;
    srv = uvm_report_server::get_server();
    errs = srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL);
    if (errs != 0) $display("P2UVM RESULT FAIL test=%s errors=%0d", tn, errs);
    else $display("P2UVM RESULT PASS test=%s", tn);
    if (errs != 0) $fatal(1, "tb_top: %0d UVM errors/fatals", errs);
  end
endmodule
