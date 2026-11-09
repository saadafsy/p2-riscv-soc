// Formal harness for rv32_core: unconstrained instruction and load data,
// free interrupt lines, OBI slaves that grant at will and answer after a
// free delay. Checks RVFI invariants and the core side of OBI.
// FAST_MEM (always grant, answer next cycle) adds a no-deadlock bound.
module core_bmc (
    input logic clk
);
  logic rst = 1'b1;
  always_ff @(posedge clk) rst <= 1'b0;

  (* anyseq *) logic [31:0] i_rdata_any, d_rdata_any;
  (* anyseq *) logic        irq_timer, irq_external;
  (* anyseq *) logic        i_gnt_any, d_gnt_any, i_rsp_any, d_rsp_any;

  logic i_req, i_gnt, i_rvalid, d_req, d_gnt, d_rvalid, d_we;
  logic [31:0] i_addr, d_addr, d_wdata;
  logic [3:0] d_be;
  logic rvfi_valid, rvfi_trap, rvfi_intr;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata, rvfi_pc_wdata, rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [4:0] rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [3:0] rvfi_mem_rmask, rvfi_mem_wmask;
  logic f_md_busy;

  // one-outstanding slaves: i_out / d_out mark a pending response
  logic i_out, d_out;
`ifdef FAST_MEM
  assign i_gnt    = 1'b1;
  assign d_gnt    = 1'b1;
  assign i_rvalid = i_out;
  assign d_rvalid = d_out;
`else
  assign i_gnt    = i_gnt_any;
  assign d_gnt    = d_gnt_any;
  assign i_rvalid = i_out && i_rsp_any;
  assign d_rvalid = d_out && d_rsp_any;
`endif

  always_ff @(posedge clk) begin
    if (rst) begin
      i_out <= 1'b0;
      d_out <= 1'b0;
    end else begin
      if (i_req && i_gnt) i_out <= 1'b1;
      else if (i_rvalid) i_out <= 1'b0;
      if (d_req && d_gnt) d_out <= 1'b1;
      else if (d_rvalid) d_out <= 1'b0;
    end
  end

  rv32_core dut (
      .clk, .rst,
      .i_req, .i_gnt, .i_addr, .i_rvalid, .i_rdata(i_rdata_any),
      .d_req, .d_gnt, .d_addr, .d_we, .d_be, .d_wdata, .d_rvalid, .d_rdata(d_rdata_any),
      .irq_timer, .irq_external,
      .rvfi_valid, .rvfi_order, .rvfi_insn, .rvfi_trap, .rvfi_intr,
      .rvfi_rs1_addr, .rvfi_rs2_addr, .rvfi_rd_addr,
      .rvfi_rs1_rdata, .rvfi_rs2_rdata, .rvfi_rd_wdata,
      .rvfi_pc_rdata, .rvfi_pc_wdata,
      .rvfi_mem_addr, .rvfi_mem_rmask, .rvfi_mem_wmask, .rvfi_mem_rdata, .rvfi_mem_wdata,
      .f_md_busy
  );

  logic [63:0] n_retired;
  logic [ 7:0] gap;
  logic        past_valid;
  logic        i_held, d_held;
  logic [31:0] i_addr_q, d_addr_q, d_wdata_q;
  logic [ 3:0] d_be_q;
  logic        d_we_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      n_retired  <= 64'd0;
      gap        <= 8'd0;
      past_valid <= 1'b0;
      i_held     <= 1'b0;
      d_held     <= 1'b0;
    end else begin
      past_valid <= 1'b1;
      if (rvfi_valid) n_retired <= n_retired + 64'd1;
      // M operation cycles are bounded by the asserts in rv32_muldiv
      gap      <= rvfi_valid ? 8'd0 : f_md_busy ? gap : gap + 8'd1;
      i_held   <= i_req && !i_gnt;
      d_held   <= d_req && !d_gnt;
      i_addr_q <= i_addr;
      d_addr_q <= d_addr;
      d_wdata_q <= d_wdata;
      d_be_q   <= d_be;
      d_we_q   <= d_we;
    end
  end

  always_comb begin
    if (!rst) begin
      // x0 reads as 0 and is never written
      if (rvfi_valid && rvfi_rs1_addr == 5'd0) assert (rvfi_rs1_rdata == 32'h0);
      if (rvfi_valid && rvfi_rs2_addr == 5'd0) assert (rvfi_rs2_rdata == 32'h0);
      if (rvfi_valid && rvfi_rd_addr == 5'd0) assert (rvfi_rd_wdata == 32'h0);
      if (rvfi_valid && rvfi_trap) assert (rvfi_rd_addr == 5'd0);
      // order counts retirements from 0 without gaps
      if (rvfi_valid) assert (rvfi_order == n_retired);
      // OBI master rules: hold the request until gnt, one outstanding
      if (past_valid && i_held) assert (i_req && i_addr == i_addr_q);
      if (past_valid && d_held)
        assert (d_req && d_addr == d_addr_q && d_we == d_we_q && d_be == d_be_q &&
                (!d_we || d_wdata == d_wdata_q));
      if (i_req && i_gnt) assert (!i_out || i_rvalid);
      if (d_req && d_gnt) assert (!d_out || d_rvalid);
      if (d_req) assert (d_addr[1:0] == 2'b00 && d_be != 4'h0);
`ifdef FAST_MEM
      // with a always-ready memory something retires at least every 12 cycles
      assert (gap < 8'd12);
`endif
      // reachability of the triggers above
      cover (rvfi_valid && rvfi_order == 64'd6);
      cover (rvfi_valid && rvfi_trap);
      cover (rvfi_valid && rvfi_intr);
      cover (rvfi_valid && rvfi_mem_rmask != 4'h0);
      cover (rvfi_valid && rvfi_mem_wmask != 4'h0);
      cover (d_held);
      // an M instruction retires
      cover (rvfi_valid && !rvfi_trap && rvfi_insn[6:0] == 7'h33 &&
             rvfi_insn[31:25] == 7'h01);
    end
  end

endmodule
