// riscv-formal wrapper for rv32_core. The instruction and data ports see an
// unconstrained OBI memory: any grant pattern, any read data, and a response
// in any later cycle, in order, for each granted request. Interrupt lines are
// held low (the checks cover the ISA, not the interrupt controller).
module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
  (* keep *) `rvformal_rand_reg        i_gnt;
  (* keep *) `rvformal_rand_reg        i_rvalid_raw;
  (* keep *) `rvformal_rand_reg [31:0] i_rdata;
  (* keep *) `rvformal_rand_reg        d_gnt;
  (* keep *) `rvformal_rand_reg        d_rvalid_raw;
  (* keep *) `rvformal_rand_reg [31:0] d_rdata;

  (* keep *) wire        i_req, d_req, d_we;
  (* keep *) wire [31:0] i_addr, d_addr, d_wdata;
  (* keep *) wire [ 3:0] d_be;

  // Outstanding granted requests per port; a response needs one.
  reg [3:0] i_out, d_out;
  wire i_rvalid = i_rvalid_raw && (i_out != 0);
  wire d_rvalid = d_rvalid_raw && (d_out != 0);
  always @(posedge clock) begin
    if (reset) begin
      i_out <= 0;
      d_out <= 0;
    end else begin
      i_out <= i_out + (i_req && i_gnt) - i_rvalid;
      d_out <= d_out + (d_req && d_gnt) - d_rvalid;
    end
  end
  always @* begin
    assume (i_out != 4'hf);
    assume (d_out != 4'hf);
  end

  assign rvfi_halt = 1'b0;
  assign rvfi_mode = 2'd3;
  assign rvfi_ixl  = 2'd1;

  rv32_core uut (
      .clk         (clock),
      .rst         (reset),
      .i_req       (i_req),
      .i_gnt       (i_gnt),
      .i_addr      (i_addr),
      .i_rvalid    (i_rvalid),
      .i_rdata     (i_rdata),
      .d_req       (d_req),
      .d_gnt       (d_gnt),
      .d_addr      (d_addr),
      .d_we        (d_we),
      .d_be        (d_be),
      .d_wdata     (d_wdata),
      .d_rvalid    (d_rvalid),
      .d_rdata     (d_rdata),
      .irq_timer   (1'b0),
      .irq_external(1'b0),
      .rvfi_valid    (rvfi_valid),
      .rvfi_order    (rvfi_order),
      .rvfi_insn     (rvfi_insn),
      .rvfi_trap     (rvfi_trap),
      .rvfi_intr     (rvfi_intr),
      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_wdata (rvfi_rd_wdata),
      .rvfi_pc_rdata (rvfi_pc_rdata),
      .rvfi_pc_wdata (rvfi_pc_wdata),
      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata)
  );
endmodule
