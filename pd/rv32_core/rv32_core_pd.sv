// rv32_core as it sits in soc_top: the RVFI trace port is left open, so
// synthesis removes the trace-only logic.
module rv32_core_pd (
    input  logic        clk,
    input  logic        rst,
    output logic        i_req,
    input  logic        i_gnt,
    output logic [31:0] i_addr,
    input  logic        i_rvalid,
    input  logic [31:0] i_rdata,
    output logic        d_req,
    input  logic        d_gnt,
    output logic [31:0] d_addr,
    output logic        d_we,
    output logic [ 3:0] d_be,
    output logic [31:0] d_wdata,
    input  logic        d_rvalid,
    input  logic [31:0] d_rdata,
    input  logic        irq_timer,
    input  logic        irq_external
);
  rv32_core u_core (
      .clk, .rst,
      .i_req, .i_gnt, .i_addr, .i_rvalid, .i_rdata,
      .d_req, .d_gnt, .d_addr, .d_we, .d_be, .d_wdata, .d_rvalid, .d_rdata,
      .irq_timer, .irq_external,
      .rvfi_valid(), .rvfi_order(), .rvfi_insn(), .rvfi_trap(), .rvfi_intr(),
      .rvfi_rs1_addr(), .rvfi_rs2_addr(), .rvfi_rd_addr(), .rvfi_rs1_rdata(),
      .rvfi_rs2_rdata(), .rvfi_rd_wdata(), .rvfi_pc_rdata(), .rvfi_pc_wdata(),
      .rvfi_mem_addr(), .rvfi_mem_rmask(), .rvfi_mem_wmask(), .rvfi_mem_rdata(),
      .rvfi_mem_wdata()
  );
endmodule
