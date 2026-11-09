`timescale 1ns / 1ps
// soc_top: rv32_core + 64 KB dual-port RAM + OBI data decoder + OBI-to-APB
// bridge with UART, GPIO, TIMER and SIMCTRL (docs/spec.md sections 5 to 8).
// Instruction port goes straight to RAM port A; data port goes through the
// decoder to RAM port B or the APB bridge.
module soc_top #(
    // verilog_lint: waive explicit-parameter-storage-type
    parameter     INIT_FILE      = "",
    parameter bit FINISH_ON_EXIT = 1'b1,
    parameter logic [15:0] UART_DIV = 16'd868
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        uart_rx,
    output logic        uart_tx,
    input  logic [20:0] gpio_in,
    output logic [15:0] gpio_out
);

  // Core ports
  logic        i_req, i_gnt, i_rvalid;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_gnt, d_we, d_rvalid;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic irq_timer, irq_uart;

  // verilator lint_off UNUSEDSIGNAL
  // The retirement trace is read by testbenches through the hierarchy.
  logic rvfi_valid, rvfi_trap, rvfi_intr;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata, rvfi_pc_wdata, rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [4:0] rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [3:0] rvfi_mem_rmask, rvfi_mem_wmask;
  // verilator lint_on UNUSEDSIGNAL

  rv32_core u_core (
      .clk(clk), .rst(rst),
      .i_req(i_req), .i_gnt(i_gnt), .i_addr(i_addr), .i_rvalid(i_rvalid), .i_rdata(i_rdata),
      .d_req(d_req), .d_gnt(d_gnt), .d_addr(d_addr), .d_we(d_we), .d_be(d_be),
      .d_wdata(d_wdata), .d_rvalid(d_rvalid), .d_rdata(d_rdata),
      .irq_timer(irq_timer), .irq_external(irq_uart),
      .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
      .rvfi_trap(rvfi_trap), .rvfi_intr(rvfi_intr),
      .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr), .rvfi_rd_addr(rvfi_rd_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_wdata(rvfi_rd_wdata), .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
      .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );

  // Data-side fabric
  logic        ram_req, ram_gnt, ram_we, ram_rvalid;
  logic [ 3:0] ram_be;
  logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic        apb_req, apb_gnt, apb_we, apb_rvalid;
  logic [ 3:0] apb_be;
  logic [31:0] apb_addr, apb_wdata, apb_rdata;

  obi_decoder u_dec (
      .clk(clk), .rst(rst),
      .m_req(d_req), .m_gnt(d_gnt), .m_addr(d_addr), .m_we(d_we), .m_be(d_be),
      .m_wdata(d_wdata), .m_rvalid(d_rvalid), .m_rdata(d_rdata),
      .ram_req(ram_req), .ram_gnt(ram_gnt), .ram_addr(ram_addr), .ram_we(ram_we),
      .ram_be(ram_be), .ram_wdata(ram_wdata), .ram_rvalid(ram_rvalid), .ram_rdata(ram_rdata),
      .apb_req(apb_req), .apb_gnt(apb_gnt), .apb_addr(apb_addr), .apb_we(apb_we),
      .apb_be(apb_be), .apb_wdata(apb_wdata), .apb_rvalid(apb_rvalid), .apb_rdata(apb_rdata)
  );

  dp_ram #(.AW(14), .INIT_FILE(INIT_FILE)) u_ram (
      .clk(clk), .rst(rst),
      .a_req(i_req), .a_gnt(i_gnt), .a_addr(i_addr), .a_rvalid(i_rvalid), .a_rdata(i_rdata),
      .b_req(ram_req), .b_gnt(ram_gnt), .b_addr(ram_addr), .b_we(ram_we), .b_be(ram_be),
      .b_wdata(ram_wdata), .b_rvalid(ram_rvalid), .b_rdata(ram_rdata)
  );

  // APB peripherals, slots by paddr[15:12]: 0 UART, 1 GPIO, 2 TIMER, F SIMCTRL
  logic [15:0]       psel, pready;
  logic [15:0][31:0] prdata;
  logic              penable, pwrite;
  logic [11:0]       paddr;
  logic [31:0]       pwdata;
  logic [ 3:0]       pstrb;
  logic [ 2:0]       pprot;
  logic [ 3:0]       pslverr;  // tied to 0 by every slave, not used by the bridge
  wire               presetn = ~rst;

  obi2apb u_apb (
      .clk(clk), .rst(rst),
      .req(apb_req), .gnt(apb_gnt), .addr(apb_addr), .we(apb_we), .be(apb_be),
      .wdata(apb_wdata), .rvalid(apb_rvalid), .rdata(apb_rdata),
      .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
      .pstrb(pstrb), .pprot(pprot), .prdata(prdata), .pready(pready)
  );

  uart_apb #(.DIV_RESET(UART_DIV)) u_uart (
      .pclk(clk), .presetn(presetn), .psel(psel[0]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[0]), .pready(pready[0]),
      .pslverr(pslverr[0]), .rx(uart_rx), .tx(uart_tx), .irq(irq_uart)
  );

  gpio_apb u_gpio (
      .pclk(clk), .presetn(presetn), .psel(psel[1]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[1]), .pready(pready[1]),
      .pslverr(pslverr[1]), .gpio_in(gpio_in), .gpio_out(gpio_out)
  );

  timer_apb u_timer (
      .pclk(clk), .presetn(presetn), .psel(psel[2]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[2]), .pready(pready[2]),
      .pslverr(pslverr[2]), .irq_timer(irq_timer)
  );

  simctrl_apb #(.FINISH_ON_EXIT(FINISH_ON_EXIT)) u_simctrl (
      .pclk(clk), .presetn(presetn), .psel(psel[15]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[15]), .pready(pready[15]),
      .pslverr(pslverr[3])
  );

  // Unused slots: the bridge never selects them (SLV_MASK), so they read 0.
  for (genvar s = 3; s < 15; s++) begin : g_empty
    assign prdata[s] = '0;
    assign pready[s] = 1'b1;
  end

endmodule
