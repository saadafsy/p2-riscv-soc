`timescale 1ns / 1ps
// soc_top: rv32_core + 64 KB dual-port RAM + OBI data decoder + OBI-to-APB
// bridge with UART, GPIO, TIMER, SYSCTL and SIMCTRL, + OBI-to-AXI4-Lite
// bridge with the attention accelerator, + JTAG debug master, March C- RAM
// BIST and the accelerator clock gate (docs/spec.md sections 5 to 8, 12, 13).
// Instruction port goes straight to RAM port A. The core data port and the
// JTAG master share the decoder through obi_arb2; the decoder reaches RAM
// port B (through the BIST mux), the APB bridge or the AXI bridge. The
// accelerator runs on accel_clk / accel_rst (synchronous to accel_clk),
// gated by SYSCTL.ACCEL_CLK_EN.
module soc_top #(
    // verilog_lint: waive explicit-parameter-storage-type
    parameter     INIT_FILE      = "",
    parameter bit FINISH_ON_EXIT = 1'b1,
    parameter logic [15:0] UART_DIV = 16'd868,
    // 1: JTAG through the FPGA's BSCANE2 (FPGA_XC7 only); the tck/tms/tdi/
    // trst pins are then unused and tdo is 0. 0: jtag_tap on the pins.
    parameter bit JTAG_BSCAN     = 1'b0,
    parameter int BIST_NBG       = 1,
    // 0: no accelerator (the 0x2000_0000 range then reads 0 and drops writes,
    // like any unmapped range); for FPGAs too small for it, e.g. the Basys 3.
    parameter bit ACCEL_EN       = 1'b1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        accel_clk,
    input  logic        accel_rst,
    input  logic        uart_rx,
    output logic        uart_tx,
    input  logic [20:0] gpio_in,
    output logic [15:0] gpio_out,
    // JTAG (IEEE 1149.1). dbg_rst resets the debug transport's clk side; it and
    // trst must come from the same power-on event and not from a button or a
    // debugger-controlled reset (rtl/debug/README.md). In simulation tie it to rst.
    input  logic        dbg_rst,
    input  logic        tck,
    input  logic        trst,
    input  logic        tms,
    input  logic        tdi,
    output logic        tdo,
    output logic        tdo_oe
);

  // Core ports
  logic        i_req, i_gnt, i_rvalid;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_gnt, d_we, d_rvalid;
  logic [ 3:0] d_be;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic irq_timer, irq_uart, irq_accel, irq_ext;
  assign irq_ext = irq_uart | irq_accel;

  // SYSCTL.CORE_HOLD (and a running MBIST) keep the core in reset.
  logic core_hold, core_rst, core_quiet;
  assign core_rst   = rst | core_hold;
  assign core_quiet = !(d_req && !d_gnt);

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
      .clk(clk), .rst(core_rst),
      .i_req(i_req), .i_gnt(i_gnt), .i_addr(i_addr), .i_rvalid(i_rvalid), .i_rdata(i_rdata),
      .d_req(d_req), .d_gnt(d_gnt), .d_addr(d_addr), .d_we(d_we), .d_be(d_be),
      .d_wdata(d_wdata), .d_rvalid(d_rvalid), .d_rdata(d_rdata),
      .irq_timer(irq_timer), .irq_external(irq_ext),
      .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
      .rvfi_trap(rvfi_trap), .rvfi_intr(rvfi_intr),
      .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr), .rvfi_rd_addr(rvfi_rd_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_wdata(rvfi_rd_wdata), .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
      .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );

  // JTAG debug master (rtl/debug)
  logic        dbg_req, dbg_gnt, dbg_we, dbg_rvalid;
  logic [ 3:0] dbg_be;
  logic [31:0] dbg_addr, dbg_wdata, dbg_rdata;

  if (JTAG_BSCAN) begin : g_bscan
`ifdef FPGA_XC7
    bscan_jtag_xilinx u_dbg (
        .clk(clk), .rst(dbg_rst),
        .obi_req(dbg_req), .obi_gnt(dbg_gnt), .obi_addr(dbg_addr), .obi_we(dbg_we),
        .obi_be(dbg_be), .obi_wdata(dbg_wdata), .obi_rvalid(dbg_rvalid), .obi_rdata(dbg_rdata)
    );
`else
    $error("soc_top: JTAG_BSCAN needs FPGA_XC7");
`endif
    assign tdo    = 1'b0;
    assign tdo_oe = 1'b0;
    logic unused_pins;
    assign unused_pins = ^{tck, trst, tms, tdi};
  end else begin : g_tap
    jtag_debug u_dbg (
        .tck(tck), .trst(trst), .tms(tms), .tdi(tdi), .tdo(tdo), .tdo_oe(tdo_oe),
        .clk(clk), .rst(dbg_rst),
        .obi_req(dbg_req), .obi_gnt(dbg_gnt), .obi_addr(dbg_addr), .obi_we(dbg_we),
        .obi_be(dbg_be), .obi_wdata(dbg_wdata), .obi_rvalid(dbg_rvalid), .obi_rdata(dbg_rdata)
    );
  end

  // Data-side fabric: core and JTAG share the decoder
  logic        dec_req, dec_gnt, dec_we, dec_rvalid;
  logic [ 3:0] dec_be;
  logic [31:0] dec_addr, dec_wdata, dec_rdata;

  obi_arb2 u_arb (
      .clk(clk), .rst(rst),
      .m0_req(d_req), .m0_gnt(d_gnt), .m0_addr(d_addr), .m0_we(d_we), .m0_be(d_be),
      .m0_wdata(d_wdata), .m0_rvalid(d_rvalid), .m0_rdata(d_rdata),
      .m1_req(dbg_req), .m1_gnt(dbg_gnt), .m1_addr(dbg_addr), .m1_we(dbg_we), .m1_be(dbg_be),
      .m1_wdata(dbg_wdata), .m1_rvalid(dbg_rvalid), .m1_rdata(dbg_rdata),
      .s_req(dec_req), .s_gnt(dec_gnt), .s_addr(dec_addr), .s_we(dec_we), .s_be(dec_be),
      .s_wdata(dec_wdata), .s_rvalid(dec_rvalid), .s_rdata(dec_rdata)
  );

  logic        ram_req, ram_gnt, ram_we, ram_rvalid;
  logic [ 3:0] ram_be;
  logic [31:0] ram_addr, ram_wdata, ram_rdata;
  logic        apb_req, apb_gnt, apb_we, apb_rvalid;
  logic [ 3:0] apb_be;
  logic [31:0] apb_addr, apb_wdata, apb_rdata;
  logic        axb_req, axb_gnt, axb_we, axb_rvalid;
  logic [ 3:0] axb_be;
  logic [31:0] axb_addr, axb_wdata, axb_rdata;

  obi_decoder #(.AXI_EN(ACCEL_EN)) u_dec (
      .clk(clk), .rst(rst),
      .m_req(dec_req), .m_gnt(dec_gnt), .m_addr(dec_addr), .m_we(dec_we), .m_be(dec_be),
      .m_wdata(dec_wdata), .m_rvalid(dec_rvalid), .m_rdata(dec_rdata),
      .ram_req(ram_req), .ram_gnt(ram_gnt), .ram_addr(ram_addr), .ram_we(ram_we),
      .ram_be(ram_be), .ram_wdata(ram_wdata), .ram_rvalid(ram_rvalid), .ram_rdata(ram_rdata),
      .apb_req(apb_req), .apb_gnt(apb_gnt), .apb_addr(apb_addr), .apb_we(apb_we),
      .apb_be(apb_be), .apb_wdata(apb_wdata), .apb_rvalid(apb_rvalid), .apb_rdata(apb_rdata),
      .axi_req(axb_req), .axi_gnt(axb_gnt), .axi_addr(axb_addr), .axi_we(axb_we),
      .axi_be(axb_be), .axi_wdata(axb_wdata), .axi_rvalid(axb_rvalid), .axi_rdata(axb_rdata)
  );

  // Accelerator clock gate: ACCEL_CLK_EN synchronized into accel_clk (reset
  // value 1, so the domain is clocked while accel_rst is applied), then the ICG.
  logic accel_clk_en, accel_en_s, accel_gclk;

  sync2ff #(.WIDTH(1), .RESET_VAL(1'b1)) u_accel_en_sync (
      .clk(accel_clk), .rst(accel_rst), .d(accel_clk_en), .q(accel_en_s)
  );

  clk_gate u_accel_cg (.clk(accel_clk), .en(accel_en_s), .gclk(accel_gclk));

  // AXI4-Lite to the accelerator
  if (ACCEL_EN) begin : g_accel
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic        arvalid, arready, rvalid, rready;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [ 3:0] wstrb;
  logic [ 2:0] awprot, arprot;
  logic [ 1:0] bresp, rresp;

  obi2axil u_axb (
      .clk(clk), .rst(rst),
      .req(axb_req), .gnt(axb_gnt), .addr(axb_addr), .we(axb_we), .be(axb_be),
      .wdata(axb_wdata), .rvalid(axb_rvalid), .rdata(axb_rdata),
      .m_awvalid(awvalid), .m_awready(awready), .m_awaddr(awaddr), .m_awprot(awprot),
      .m_wvalid(wvalid), .m_wready(wready), .m_wdata(wdata), .m_wstrb(wstrb),
      .m_bvalid(bvalid), .m_bready(bready), .m_bresp(bresp),
      .m_arvalid(arvalid), .m_arready(arready), .m_araddr(araddr), .m_arprot(arprot),
      .m_rvalid(rvalid), .m_rready(rready), .m_rdata(rdata), .m_rresp(rresp)
  );

  axil_attn u_attn (
      .clk(clk), .rst(rst),
      .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
      .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
      .bvalid(bvalid), .bready(bready), .bresp(bresp),
      .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
      .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp),
      .irq(irq_accel),
      .accel_clk(accel_gclk), .accel_rst(accel_rst)
  );
  end else begin : g_no_accel
    // The decoder never selects the AXI port when AXI_EN = 0.
    assign axb_gnt    = 1'b0;
    assign axb_rvalid = 1'b0;
    assign axb_rdata  = 32'd0;
    assign irq_accel  = 1'b0;
    // verilator lint_off UNUSEDSIGNAL
    logic unused_axb;
    assign unused_axb = ^{axb_req, axb_addr, axb_we, axb_be, axb_wdata, accel_gclk};
    // verilator lint_on UNUSEDSIGNAL
  end

  // RAM port B: the data bus, or the March C- BIST while it runs
  logic        bist_start, bist_busy, bist_done, bist_fail;
  logic [31:0] bist_fail_addr, bist_fail_syn;
  logic [ 2:0] bist_fail_elem, bist_fail_bg;
  logic        bst_req, bst_gnt, bst_we, bst_rvalid;
  logic [ 3:0] bst_be;
  logic [31:0] bst_addr, bst_wdata, bst_rdata;
  logic        rb_req, rb_gnt, rb_we, rb_rvalid;
  logic [ 3:0] rb_be;
  logic [31:0] rb_addr, rb_wdata, rb_rdata;

  mbist_marchc #(.AW(14), .BASE(32'h0000_0000), .NBG(BIST_NBG)) u_bist (
      .clk(clk), .rst(rst), .start(bist_start), .busy(bist_busy), .done(bist_done),
      .fail(bist_fail), .fail_addr(bist_fail_addr), .fail_elem(bist_fail_elem),
      .fail_bg(bist_fail_bg), .fail_syn(bist_fail_syn),
      .obi_req(bst_req), .obi_gnt(bst_gnt), .obi_addr(bst_addr), .obi_we(bst_we),
      .obi_be(bst_be), .obi_wdata(bst_wdata), .obi_rvalid(bst_rvalid), .obi_rdata(bst_rdata)
  );

  bist_ram_mux u_bmux (
      .bist_sel(bist_busy),
      .sys_req(ram_req), .sys_gnt(ram_gnt), .sys_addr(ram_addr), .sys_we(ram_we),
      .sys_be(ram_be), .sys_wdata(ram_wdata), .sys_rvalid(ram_rvalid), .sys_rdata(ram_rdata),
      .bist_req(bst_req), .bist_gnt(bst_gnt), .bist_addr(bst_addr), .bist_we(bst_we),
      .bist_be(bst_be), .bist_wdata(bst_wdata), .bist_rvalid(bst_rvalid),
      .bist_rdata(bst_rdata),
      .ram_req(rb_req), .ram_gnt(rb_gnt), .ram_addr(rb_addr), .ram_we(rb_we), .ram_be(rb_be),
      .ram_wdata(rb_wdata), .ram_rvalid(rb_rvalid), .ram_rdata(rb_rdata)
  );

  dp_ram #(.AW(14), .INIT_FILE(INIT_FILE)) u_ram (
      .clk(clk), .rst(rst),
      .a_req(i_req), .a_gnt(i_gnt), .a_addr(i_addr), .a_rvalid(i_rvalid), .a_rdata(i_rdata),
      .b_req(rb_req), .b_gnt(rb_gnt), .b_addr(rb_addr), .b_we(rb_we), .b_be(rb_be),
      .b_wdata(rb_wdata), .b_rvalid(rb_rvalid), .b_rdata(rb_rdata)
  );

  // APB peripherals, slots by paddr[15:12]: 0 UART, 1 GPIO, 2 TIMER, 3 SYSCTL, F SIMCTRL
  // verilator lint_off UNUSEDSIGNAL
  logic [15:0]       psel;     // slots 4..14 are unpopulated
  logic [ 4:0]       pslverr;  // tied to 0 by every slave, not used by the bridge
  // verilator lint_on UNUSEDSIGNAL
  logic [15:0]       pready;
  logic [15:0][31:0] prdata;
  logic              penable, pwrite;
  logic [11:0]       paddr;
  logic [31:0]       pwdata;
  logic [ 3:0]       pstrb;
  logic [ 2:0]       pprot;
  wire               presetn = ~rst;

  obi2apb #(.SLV_MASK(16'h800F)) u_apb (
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

  sysctl_apb u_sysctl (
      .pclk(clk), .presetn(presetn), .psel(psel[3]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[3]), .pready(pready[3]), .pslverr(pslverr[4]),
      .core_quiet(core_quiet), .core_hold(core_hold),
      .accel_clk_en(accel_clk_en), .accel_clk_on(accel_en_s),
      .bist_start(bist_start), .bist_busy(bist_busy), .bist_done(bist_done),
      .bist_fail(bist_fail), .bist_fail_addr(bist_fail_addr), .bist_fail_elem(bist_fail_elem),
      .bist_fail_bg(bist_fail_bg), .bist_fail_syn(bist_fail_syn)
  );

  simctrl_apb #(.FINISH_ON_EXIT(FINISH_ON_EXIT)) u_simctrl (
      .pclk(clk), .presetn(presetn), .psel(psel[15]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .prdata(prdata[15]), .pready(pready[15]),
      .pslverr(pslverr[3])
  );

  // Unused slots: the bridge never selects them (SLV_MASK), so they read 0.
  for (genvar s = 4; s < 15; s++) begin : g_empty
    assign prdata[s] = '0;
    assign pready[s] = 1'b1;
  end

endmodule
