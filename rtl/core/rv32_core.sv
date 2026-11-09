// rv32_core: 5-stage in-order RV32IM + Zicsr, machine mode only.
// IF (rv32_fetch) | ID decode + regfile | EX ALU, branches, CSRs, M unit |
// MEM issues the data request | WB takes the response and writes rd.
// Traps commit when the faulting instruction moves MEM -> WB; interrupts
// are attached to the instruction leaving EX, which then does nothing else.
module rv32_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst,
    // instruction port (OBI, read-only)
    output logic        i_req,
    input  logic        i_gnt,
    output logic [31:0] i_addr,
    input  logic        i_rvalid,
    input  logic [31:0] i_rdata,
    // data port (OBI)
    output logic        d_req,
    input  logic        d_gnt,
    output logic [31:0] d_addr,
    output logic        d_we,
    output logic [ 3:0] d_be,
    output logic [31:0] d_wdata,
    input  logic        d_rvalid,
    input  logic [31:0] d_rdata,
    input  logic        irq_timer,
    input  logic        irq_external,
    // retirement trace (RVFI subset)
    output logic        rvfi_valid,
    output logic [63:0] rvfi_order,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic        rvfi_intr,
    output logic [ 4:0] rvfi_rs1_addr,
    output logic [ 4:0] rvfi_rs2_addr,
    output logic [ 4:0] rvfi_rd_addr,
    output logic [31:0] rvfi_rs1_rdata,
    output logic [31:0] rvfi_rs2_rdata,
    output logic [31:0] rvfi_rd_wdata,
    output logic [31:0] rvfi_pc_rdata,
    output logic [31:0] rvfi_pc_wdata,
    output logic [31:0] rvfi_mem_addr,
    output logic [ 3:0] rvfi_mem_rmask,
    output logic [ 3:0] rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_rdata,
    output logic [31:0] rvfi_mem_wdata
`ifdef FORMAL
    ,
    output logic        f_md_busy  // formal harness only: M unit has an operation in flight
`endif
);

  // ---------------------------------------------------------------- control
  logic redirect, ex_redirect, trap_commit;
  logic [31:0] redirect_pc, ex_target_pc;
  logic wb_stall, mem_stall, ex_stall, id_stall, csr_drain, load_use;
  logic ex_go, mem_go, wb_done, irq_take;

  // ---------------------------------------------------------------- IF
  logic        id_valid, id_pop;
  logic [31:0] id_pc, id_insn;

  rv32_fetch #(.RESET_PC(RESET_PC)) u_fetch (
      .clk, .rst,
      .i_req, .i_gnt, .i_addr, .i_rvalid, .i_rdata,
      .redirect, .redirect_pc,
      .pop(id_pop),
      .id_valid, .id_pc, .id_insn
  );

  // ---------------------------------------------------------------- ID
  logic [4:0] d_rs1, d_rs2, d_rd;
  logic d_rd_we, d_a_pc, d_a_zero, d_b_imm, d_is_branch, d_is_jal, d_is_jalr;
  logic d_is_load, d_is_store, d_is_csr, d_is_mret, d_is_md, d_illegal, d_is_ecall, d_is_ebreak;
  logic [31:0] d_imm, rf_rdata1, rf_rdata2;
  logic [3:0] d_alu_op;

  rv32_decoder u_dec (
      .insn(id_insn),
      .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd), .rd_we(d_rd_we), .imm(d_imm),
      .alu_op(d_alu_op), .a_pc(d_a_pc), .a_zero(d_a_zero), .b_imm(d_b_imm),
      .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr),
      .is_load(d_is_load), .is_store(d_is_store), .is_csr(d_is_csr),
      .is_mret(d_is_mret), .is_md(d_is_md), .illegal(d_illegal), .is_ecall(d_is_ecall),
      .is_ebreak(d_is_ebreak)
  );

  logic        wb_valid, wb_rd_we;
  logic [ 4:0] wb_rd;
  logic [31:0] wb_value;

  rv32_regfile u_rf (
      .clk, .rst,
      .raddr1(d_rs1), .rdata1(rf_rdata1),
      .raddr2(d_rs2), .rdata2(rf_rdata2),
      .we(wb_done && wb_rd_we), .waddr(wb_rd), .wdata(wb_value)
  );

  logic       id_exc;
  logic [3:0] id_cause;
  assign id_exc   = d_illegal || d_is_ecall || d_is_ebreak;
  assign id_cause = d_illegal ? 4'd2 : d_is_ebreak ? 4'd3 : 4'd11;

  // ---------------------------------------------------------------- ID/EX
  logic        ex_valid, ex_rd_we, ex_a_pc, ex_a_zero, ex_b_imm, ex_is_branch;
  logic        ex_is_jal, ex_is_jalr, ex_is_load, ex_is_store, ex_is_csr, ex_is_mret;
  logic        ex_is_md, ex_exc_in;
  logic [ 3:0] ex_cause_in, ex_alu_op;
  logic [ 4:0] ex_rs1, ex_rs2, ex_rd;
  logic [31:0] ex_pc, ex_insn, ex_imm, ex_rs1_val, ex_rs2_val;

  // ---------------------------------------------------------------- EX/MEM
  logic        mem_valid, mem_rd_we, mem_is_load, mem_is_store, mem_exc, mem_intr;
  logic        mem_no_instret;
  logic [ 4:0] mem_rd, mem_rs1, mem_rs2;
  logic [31:0] mem_pc, mem_insn, mem_result, mem_addr, mem_wdata, mem_cause, mem_tval;
  logic [31:0] mem_rs1_val, mem_rs2_val, mem_pc_next, mem_rvfi_wdata;
  logic [ 3:0] mem_be;
  logic [ 2:0] mem_funct3;

  // ---------------------------------------------------------------- MEM/WB
  logic        wb_memop, wb_is_load, wb_trap, wb_no_instret;
  logic [ 4:0] wb_rs1, wb_rs2;
  logic [31:0] wb_pc, wb_insn, wb_result, wb_rs1_val, wb_rs2_val, wb_pc_next;
  logic [31:2] wb_addr;
  logic [31:0] wb_rvfi_wdata;
  logic [ 3:0] wb_mask, wb_ld_fill, wb_ld_sgn;
  logic [15:0] wb_ld_lane;

  // ---------------------------------------------------------------- hazards
  logic [1:0] fwd_a, fwd_b, fwd_a_nxt, fwd_b_nxt;
  logic       ex_kill;

  rv32_hazard u_hz (
      .id_valid, .id_rs1(d_rs1), .id_rs2(d_rs2),
      .ex_valid, .ex_is_load, .ex_rd, .ex_rs1, .ex_rs2,
      .mem_valid, .mem_rd,
      .wb_valid, .wb_rd,
      .ex_adv(!trap_commit && !ex_stall), .mem_adv(!mem_stall), .wb_adv(!wb_stall),
      .ex_go, .ex_kill, .wb_in_valid(mem_go && !mem_intr),
      .load_use, .fwd_a_nxt, .fwd_b_nxt
  );

  // Forwarding selects registered (timing); they track the ID/EX, EX/MEM and
  // MEM/WB updates below exactly, so they equal the direct compare. fwd_* drive
  // operand bits [15:0], the kept copies fwd_*_hi bits [31:16] (fanout), and
  // the inverted copies fwd_*_mdn the M unit's own operand muxes, so it adds no
  // load on fwd_rs1/2 (inverted so yosys does not merge them with fwd_*).
  (* keep *) logic [1:0] fwd_a_hi, fwd_b_hi, fwd_a_mdn, fwd_b_mdn;
  always_ff @(posedge clk) begin
    if (rst) begin
      fwd_a    <= 2'd0;
      fwd_b    <= 2'd0;
      fwd_a_hi <= 2'd0;
      fwd_b_hi <= 2'd0;
      fwd_a_mdn <= 2'b11;
      fwd_b_mdn <= 2'b11;
    end else begin
      fwd_a    <= fwd_a_nxt;
      fwd_b    <= fwd_b_nxt;
      fwd_a_hi <= fwd_a_nxt;
      fwd_b_hi <= fwd_b_nxt;
      fwd_a_mdn <= ~fwd_a_nxt;
      fwd_b_mdn <= ~fwd_b_nxt;
    end
  end

`ifdef FORMAL
  logic [1:0] fwd_a_ref, fwd_b_ref;
  always_comb begin
    fwd_a_ref = 2'd0;
    if (ex_rs1 != 5'd0 && mem_valid && mem_rd == ex_rs1) fwd_a_ref = 2'd1;
    else if (ex_rs1 != 5'd0 && wb_valid && wb_rd == ex_rs1) fwd_a_ref = 2'd2;
    fwd_b_ref = 2'd0;
    if (ex_rs2 != 5'd0 && mem_valid && mem_rd == ex_rs2) fwd_b_ref = 2'd1;
    else if (ex_rs2 != 5'd0 && wb_valid && wb_rd == ex_rs2) fwd_b_ref = 2'd2;
    if (!rst) assert (fwd_a == fwd_a_ref && fwd_b == fwd_b_ref &&
                      fwd_a_hi == fwd_a_ref && fwd_b_hi == fwd_b_ref &&
                      ~fwd_a_mdn == fwd_a_ref && ~fwd_b_mdn == fwd_b_ref);
  end
`endif

  // ---------------------------------------------------------------- stalls
  logic mem_bus;
  assign mem_bus   = mem_valid && (mem_is_load || mem_is_store);
  // One outstanding data transaction: WB holds until its rvalid.
  assign wb_stall  = wb_valid && wb_memop && !d_rvalid;
  assign d_req     = mem_bus && !wb_stall;
  assign mem_stall = wb_stall || (mem_bus && !d_gnt);
  // CSR accesses wait for older instructions to retire so counters read exact.
  assign csr_drain = ex_valid && ex_is_csr && (mem_valid || wb_valid);
  // An M op holds EX until its result is ready; a pending interrupt lets it go at
  // once (it then carries the interrupt and is abandoned).
  logic md_wait, md_done, md_busy, irq_pending;
  assign md_wait   = ex_valid && ex_is_md && !md_done && !irq_pending;
  assign ex_stall  = mem_stall || csr_drain || md_wait;
  assign id_stall  = ex_stall || load_use;

  assign mem_go      = mem_valid && !mem_stall;
  assign trap_commit = mem_go && (mem_exc || mem_intr);
  assign ex_go       = ex_valid && !ex_stall && !trap_commit;
  assign wb_done     = wb_valid && !wb_stall;
  assign id_pop      = id_valid && !id_stall;

  // ---------------------------------------------------------------- EX
  logic [31:0] fwd_rs1, fwd_rs2, alu_a, alu_b, alu_y, pc_plus4, tgt_base, tgt_sum, tgt_pc;
  logic        br_taken, take, tgt_mis, ld_mis, st_mis;
  logic        csr_illegal, csr_wr_intent, ex_exc, ex_do;
  logic [31:0] csr_rdata, csr_wsrc, mtvec, mepc, irq_cause, ex_tval;
  logic [ 3:0] ex_cause;
  logic [ 2:0] ex_funct3;

  assign ex_funct3 = ex_insn[14:12];

  always_comb begin
    unique case (fwd_a)
      2'd1:    fwd_rs1[15:0] = mem_result[15:0];
      2'd2:    fwd_rs1[15:0] = wb_value[15:0];
      default: fwd_rs1[15:0] = ex_rs1_val[15:0];
    endcase
    unique case (fwd_a_hi)
      2'd1:    fwd_rs1[31:16] = mem_result[31:16];
      2'd2:    fwd_rs1[31:16] = wb_value[31:16];
      default: fwd_rs1[31:16] = ex_rs1_val[31:16];
    endcase
    unique case (fwd_b)
      2'd1:    fwd_rs2[15:0] = mem_result[15:0];
      2'd2:    fwd_rs2[15:0] = wb_value[15:0];
      default: fwd_rs2[15:0] = ex_rs2_val[15:0];
    endcase
    unique case (fwd_b_hi)
      2'd1:    fwd_rs2[31:16] = mem_result[31:16];
      2'd2:    fwd_rs2[31:16] = wb_value[31:16];
      default: fwd_rs2[31:16] = ex_rs2_val[31:16];
    endcase
  end

  assign alu_a = ex_a_zero ? 32'h0 : ex_a_pc ? ex_pc : fwd_rs1;
  assign alu_b = ex_b_imm ? ex_imm : fwd_rs2;

  rv32_alu u_alu (.op(ex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  always_comb begin
    unique case (ex_funct3)
      3'b000:  br_taken = fwd_rs1 == fwd_rs2;
      3'b001:  br_taken = fwd_rs1 != fwd_rs2;
      3'b100:  br_taken = $signed(fwd_rs1) < $signed(fwd_rs2);
      3'b101:  br_taken = $signed(fwd_rs1) >= $signed(fwd_rs2);
      3'b110:  br_taken = fwd_rs1 < fwd_rs2;
      3'b111:  br_taken = fwd_rs1 >= fwd_rs2;
      default: br_taken = 1'b0;
    endcase
  end

  assign pc_plus4 = ex_pc + 32'd4;
  assign tgt_base = ex_is_jalr ? fwd_rs1 : ex_pc;
  assign tgt_sum  = tgt_base + ex_imm;
  assign tgt_pc   = tgt_sum & ~32'h1;
  assign take     = ex_is_jal || ex_is_jalr || (ex_is_branch && br_taken);
  // JALR clears bit 0, so only bit 1 can misalign a target.
  assign tgt_mis  = take && tgt_pc[1];
  // Load/store address is rs1 + imm: its low 2 bits need only a 2-bit add, which
  // keeps the 32-bit ALU out of the misalign -> trap -> redirect path.
  logic [1:0] ea_lo;
  logic       ea_mis;
  assign ea_lo    = fwd_rs1[1:0] + ex_imm[1:0];
  assign ea_mis   = (ex_funct3[1:0] == 2'b01 && ea_lo[0]) ||
                    (ex_funct3[1:0] == 2'b10 && ea_lo != 2'b00);
  assign ld_mis   = ex_is_load && ea_mis;
  assign st_mis   = ex_is_store && ea_mis;

  assign csr_wr_intent = ex_funct3[1:0] == 2'b01 || ex_insn[19:15] != 5'd0;
  assign csr_wsrc      = ex_funct3[2] ? {27'b0, ex_insn[19:15]} : fwd_rs1;

  always_comb begin
    ex_exc   = 1'b1;
    ex_cause = ex_cause_in;
    ex_tval  = 32'h0;
    if (ex_exc_in) begin
      ex_tval = ex_cause_in == 4'd2 ? ex_insn : 32'h0;
    end else if (tgt_mis) begin
      ex_cause = 4'd0;
      ex_tval  = tgt_pc;
    end else if (ex_is_csr && csr_illegal) begin
      ex_cause = 4'd2;
      ex_tval  = ex_insn;
    end else if (ld_mis) begin
      ex_cause = 4'd4;
      ex_tval  = alu_y;
    end else if (st_mis) begin
      ex_cause = 4'd6;
      ex_tval  = alu_y;
    end else begin
      ex_exc = 1'b0;
    end
  end

  assign irq_take     = ex_go && irq_pending;
  assign ex_do        = ex_go && !ex_exc && !irq_take;
  assign ex_redirect  = ex_do && (take || ex_is_csr || ex_is_mret);
  assign ex_target_pc = ex_is_mret ? mepc : ex_is_csr ? pc_plus4 : tgt_pc;

  assign redirect    = trap_commit || ex_redirect;
  assign redirect_pc = trap_commit ? mtvec : ex_target_pc;

  rv32_csr u_csr (
      .clk, .rst, .irq_timer, .irq_external,
      .addr(ex_insn[31:20]), .wr_intent(csr_wr_intent),
      .rdata(csr_rdata), .illegal(csr_illegal),
      .wr_en(ex_do && ex_is_csr && csr_wr_intent), .op(ex_funct3[1:0]), .wsrc(csr_wsrc),
      .trap_en(trap_commit), .trap_pc(mem_pc[31:2]), .trap_cause(mem_cause), .trap_tval(mem_tval),
      .mret_en(ex_do && ex_is_mret),
      .retire_en(wb_done && !wb_trap && !wb_no_instret),
      .mtvec_o(mtvec), .mepc_o(mepc),
      .irq_pending, .irq_cause
  );

  // M unit: operands are valid once MEM is not stalled (a load result in WB has
  // arrived), the same condition under which EX could advance.
  logic [31:0] md_result, md_a, md_b;
  always_comb begin
    unique case (~fwd_a_mdn)
      2'd1:    md_a = mem_result;
      2'd2:    md_a = wb_value;
      default: md_a = ex_rs1_val;
    endcase
    unique case (~fwd_b_mdn)
      2'd1:    md_b = mem_result;
      2'd2:    md_b = wb_value;
      default: md_b = ex_rs2_val;
    endcase
  end
  rv32_muldiv u_md (
      .clk, .rst,
      .start(ex_valid && ex_is_md && !md_busy && !mem_stall && !trap_commit),
      .clear(ex_go || trap_commit),
      .op(ex_funct3), .a(md_a), .b(md_b),
      .busy(md_busy), .done(md_done), .result(md_result)
  );

`ifdef FORMAL
  assign f_md_busy = md_busy;
  always_comb begin
    if (!rst && md_busy) assert (ex_valid && ex_is_md);
    if (!rst) cover (md_busy && !md_done && irq_take);  // an interrupt cuts an M op short
  end
`endif

  // Store lane placement and byte-lane mask of the access (size from funct3).
  logic [3:0] size_mask, lane_mask;
  logic [31:0] st_data, lane_bits;
  assign size_mask = ex_funct3[1:0] == 2'b00 ? 4'b0001 :
                     ex_funct3[1:0] == 2'b01 ? 4'b0011 : 4'b1111;
  assign st_data   = fwd_rs2 << {alu_y[1:0], 3'b000};
  assign lane_mask = size_mask << alu_y[1:0];
  assign lane_bits = {{8{lane_mask[3]}}, {8{lane_mask[2]}},
                      {8{lane_mask[1]}}, {8{lane_mask[0]}}};

  // ---------------------------------------------------------------- ID/EX regs
  always_ff @(posedge clk) begin
    if (rst) begin
      ex_valid     <= 1'b0;
      ex_pc        <= 32'h0;
      ex_insn      <= 32'h0;
      ex_imm       <= 32'h0;
      ex_rs1       <= 5'd0;
      ex_rs2       <= 5'd0;
      ex_rd        <= 5'd0;
      ex_rd_we     <= 1'b0;
      ex_rs1_val   <= 32'h0;
      ex_rs2_val   <= 32'h0;
      ex_alu_op    <= 4'h0;
      ex_a_pc      <= 1'b0;
      ex_a_zero    <= 1'b0;
      ex_b_imm     <= 1'b0;
      ex_is_branch <= 1'b0;
      ex_is_jal    <= 1'b0;
      ex_is_jalr   <= 1'b0;
      ex_is_load   <= 1'b0;
      ex_is_store  <= 1'b0;
      ex_is_csr    <= 1'b0;
      ex_is_mret   <= 1'b0;
      ex_is_md     <= 1'b0;
      ex_exc_in    <= 1'b0;
      ex_cause_in  <= 4'd0;
    end else if (trap_commit) begin
      ex_valid <= 1'b0;
    end else if (!ex_stall) begin
      ex_valid     <= id_valid && !load_use && !ex_redirect;
      ex_pc        <= id_pc;
      ex_insn      <= id_insn;
      ex_imm       <= d_imm;
      ex_rs1       <= d_rs1;
      ex_rs2       <= d_rs2;
      ex_rd        <= d_rd;
      ex_rd_we     <= d_rd_we;
      ex_rs1_val   <= rf_rdata1;
      ex_rs2_val   <= rf_rdata2;
      ex_alu_op    <= d_alu_op;
      ex_a_pc      <= d_a_pc;
      ex_a_zero    <= d_a_zero;
      ex_b_imm     <= d_b_imm;
      ex_is_branch <= d_is_branch;
      ex_is_jal    <= d_is_jal;
      ex_is_jalr   <= d_is_jalr;
      ex_is_load   <= d_is_load;
      ex_is_store  <= d_is_store;
      ex_is_csr    <= d_is_csr;
      ex_is_mret   <= d_is_mret;
      ex_is_md     <= d_is_md;
      ex_exc_in    <= id_exc;
      ex_cause_in  <= id_cause;
    end else begin
      // Producers may leave MEM/WB while EX is held; keep their values.
      ex_rs1_val <= fwd_rs1;
      ex_rs2_val <= fwd_rs2;
    end
  end

  // ---------------------------------------------------------------- EX/MEM regs
  logic ex_illegal;
  assign ex_kill    = ex_exc || irq_take;
  assign ex_illegal = ex_exc && ex_cause == 4'd2;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_valid      <= 1'b0;
      mem_rd_we      <= 1'b0;
      mem_rd         <= 5'd0;
      mem_is_load    <= 1'b0;
      mem_is_store   <= 1'b0;
      mem_exc        <= 1'b0;
      mem_intr       <= 1'b0;
      mem_cause      <= 32'h0;
      mem_tval       <= 32'h0;
      mem_no_instret <= 1'b0;
      mem_pc         <= 32'h0;
      mem_insn       <= 32'h0;
      mem_result     <= 32'h0;
      mem_addr       <= 32'h0;
      mem_wdata      <= 32'h0;
      mem_be         <= 4'h0;
      mem_funct3     <= 3'd0;
      mem_rs1        <= 5'd0;
      mem_rs2        <= 5'd0;
      mem_rs1_val    <= 32'h0;
      mem_rs2_val    <= 32'h0;
      mem_pc_next    <= 32'h0;
      mem_rvfi_wdata <= 32'h0;
    end else if (!mem_stall) begin
      mem_valid      <= ex_go;
      mem_rd_we      <= ex_rd_we && !ex_kill;
      mem_rd         <= ex_kill ? 5'd0 : ex_rd;
      mem_is_load    <= ex_is_load && !ex_kill;
      mem_is_store   <= ex_is_store && !ex_kill;
      mem_exc        <= ex_exc && !irq_take;
      mem_intr       <= irq_take;
      mem_cause      <= irq_take ? irq_cause : {28'h0, ex_cause};
      mem_tval       <= irq_take ? 32'h0 : ex_tval;
      // Writing minstret overrides the increment of the writing instruction.
      mem_no_instret <= ex_is_csr && csr_wr_intent &&
                        (ex_insn[31:20] == 12'hB02 || ex_insn[31:20] == 12'hB82);
      mem_pc         <= ex_pc;
      mem_insn       <= ex_insn;
      mem_result     <= ex_is_csr ? csr_rdata : (ex_is_jal || ex_is_jalr) ? pc_plus4 :
                        ex_is_md ? md_result : alu_y;
      mem_addr       <= alu_y;
      mem_wdata      <= st_data;
      mem_be         <= lane_mask;
      mem_funct3     <= ex_funct3;
      // An illegal instruction reports no source registers, even a CSR access
      // found illegal only here in EX.
      mem_rs1        <= ex_illegal ? 5'd0 : ex_rs1;
      mem_rs2        <= ex_illegal ? 5'd0 : ex_rs2;
      mem_rs1_val    <= ex_illegal ? 32'h0 : fwd_rs1;
      mem_rs2_val    <= ex_illegal ? 32'h0 : fwd_rs2;
      mem_pc_next    <= ex_redirect ? ex_target_pc : pc_plus4;
      mem_rvfi_wdata <= st_data & lane_bits;
    end
  end

  assign d_addr  = {mem_addr[31:2], 2'b00};
  assign d_we    = mem_is_store;
  assign d_be    = mem_be;
  assign d_wdata = mem_wdata;

  // Load alignment decoded in MEM (timing; wb_addr[1:0] had fanout 26 in WB).
  // Result byte k takes d_rdata lane j when m_ld_lane[4k+j], else sign/zero
  // fill when m_ld_fill[k]; the sign is bit 7 of the lane set in m_ld_sgn.
  // Same as (d_rdata >> 8*addr[1:0]) extended by funct3; all zero for a non-load.
  logic [15:0] m_ld_lane;
  logic [ 3:0] m_ld_fill, m_ld_sgn;
  logic [ 2:0] m_ld_a, m_ld_n;  // byte offset, access size in bytes
  assign m_ld_a = {1'b0, mem_addr[1:0]};
  assign m_ld_n = mem_funct3[1:0] == 2'b00 ? 3'd1 : mem_funct3[1:0] == 2'b01 ? 3'd2 : 3'd4;
  for (genvar k = 0; k < 4; k++) begin : g_ld_dec
    assign m_ld_fill[k] = mem_is_load && 3'(k) >= m_ld_n;
    assign m_ld_sgn[k]  = mem_is_load && !mem_funct3[2] && m_ld_n != 3'd4 &&
                          3'(k) == m_ld_a + m_ld_n - 3'd1;
    for (genvar j = 0; j < 4; j++) begin : g_lane
      assign m_ld_lane[4*k+j] = mem_is_load && 3'(k) < m_ld_n && 3'(j) == 3'(k) + m_ld_a;
    end
  end

  // ---------------------------------------------------------------- MEM/WB regs
  always_ff @(posedge clk) begin
    if (rst) begin
      wb_valid      <= 1'b0;
      wb_rd_we      <= 1'b0;
      wb_rd         <= 5'd0;
      wb_memop      <= 1'b0;
      wb_is_load    <= 1'b0;
      wb_trap       <= 1'b0;
      wb_no_instret <= 1'b0;
      wb_pc         <= 32'h0;
      wb_insn       <= 32'h0;
      wb_result     <= 32'h0;
      wb_addr       <= 30'h0;
      wb_mask       <= 4'h0;
      wb_ld_lane    <= 16'h0;
      wb_ld_fill    <= 4'h0;
      wb_ld_sgn     <= 4'h0;
      wb_rs1        <= 5'd0;
      wb_rs2        <= 5'd0;
      wb_rs1_val    <= 32'h0;
      wb_rs2_val    <= 32'h0;
      wb_pc_next    <= 32'h0;
      wb_rvfi_wdata <= 32'h0;
    end else if (!wb_stall) begin
      // An interrupted instruction never retires; it only carried the trap.
      wb_valid      <= mem_go && !mem_intr;
      wb_rd_we      <= mem_rd_we;
      wb_rd         <= mem_rd;
      wb_memop      <= mem_bus;
      wb_is_load    <= mem_is_load;
      wb_trap       <= mem_exc;
      wb_no_instret <= mem_no_instret;
      wb_pc         <= mem_pc;
      wb_insn       <= mem_insn;
      // A load's value comes from d_rdata; zero here lets WB OR the two.
      wb_result     <= mem_is_load ? 32'h0 : mem_result;
      wb_addr       <= mem_addr[31:2];
      wb_mask       <= mem_bus ? mem_be : 4'h0;
      wb_ld_lane    <= m_ld_lane;
      wb_ld_fill    <= m_ld_fill;
      wb_ld_sgn     <= m_ld_sgn;
      wb_rs1        <= mem_rs1;
      wb_rs2        <= mem_rs2;
      wb_rs1_val    <= mem_rs1_val;
      wb_rs2_val    <= mem_rs2_val;
      wb_pc_next    <= mem_exc ? mtvec : mem_pc_next;
      wb_rvfi_wdata <= mem_is_store ? mem_rvfi_wdata : 32'h0;
    end
  end

  // ---------------------------------------------------------------- WB
  logic [31:0] ld_value;
  logic        ld_sign;
  assign ld_sign = |(wb_ld_sgn & {d_rdata[31], d_rdata[23], d_rdata[15], d_rdata[7]});
  for (genvar k = 0; k < 4; k++) begin : g_ld
    assign ld_value[8*k+:8] = {8{wb_ld_fill[k] && ld_sign}} |
                              ({8{wb_ld_lane[4*k+0]}} & d_rdata[ 7: 0]) |
                              ({8{wb_ld_lane[4*k+1]}} & d_rdata[15: 8]) |
                              ({8{wb_ld_lane[4*k+2]}} & d_rdata[23:16]) |
                              ({8{wb_ld_lane[4*k+3]}} & d_rdata[31:24]);
  end
  assign wb_value = ld_value | wb_result;

  // ---------------------------------------------------------------- RVFI
  logic [63:0] order_cnt;
  logic        intr_pend;

  always_ff @(posedge clk) begin
    if (rst) begin
      order_cnt      <= 64'h0;
      intr_pend      <= 1'b0;
      rvfi_valid     <= 1'b0;
      rvfi_order     <= 64'h0;
      rvfi_insn      <= 32'h0;
      rvfi_trap      <= 1'b0;
      rvfi_intr      <= 1'b0;
      rvfi_rs1_addr  <= 5'd0;
      rvfi_rs2_addr  <= 5'd0;
      rvfi_rd_addr   <= 5'd0;
      rvfi_rs1_rdata <= 32'h0;
      rvfi_rs2_rdata <= 32'h0;
      rvfi_rd_wdata  <= 32'h0;
      rvfi_pc_rdata  <= 32'h0;
      rvfi_pc_wdata  <= 32'h0;
      rvfi_mem_addr  <= 32'h0;
      rvfi_mem_rmask <= 4'h0;
      rvfi_mem_wmask <= 4'h0;
      rvfi_mem_rdata <= 32'h0;
      rvfi_mem_wdata <= 32'h0;
    end else begin
      rvfi_valid <= wb_done;
      // The next retirement after a trap or interrupt entry is the handler's first.
      if ((trap_commit && mem_intr) || (wb_done && wb_trap)) intr_pend <= 1'b1;
      else if (wb_done) intr_pend <= 1'b0;
      if (wb_done) begin
        order_cnt      <= order_cnt + 64'd1;
        rvfi_order     <= order_cnt;
        rvfi_insn      <= wb_insn;
        rvfi_trap      <= wb_trap;
        rvfi_intr      <= intr_pend;
        rvfi_rs1_addr  <= wb_rs1;
        rvfi_rs2_addr  <= wb_rs2;
        rvfi_rs1_rdata <= wb_rs1_val;
        rvfi_rs2_rdata <= wb_rs2_val;
        rvfi_rd_addr   <= wb_rd;
        rvfi_rd_wdata  <= wb_rd_we ? wb_value : 32'h0;
        rvfi_pc_rdata  <= wb_pc;
        rvfi_pc_wdata  <= wb_pc_next;
        rvfi_mem_addr  <= wb_memop ? {wb_addr, 2'b00} : 32'h0;
        rvfi_mem_rmask <= wb_is_load ? wb_mask : 4'h0;
        rvfi_mem_wmask <= wb_is_load ? 4'h0 : wb_mask;
        rvfi_mem_rdata <= wb_is_load ? d_rdata & {{8{wb_mask[3]}}, {8{wb_mask[2]}},
                                                  {8{wb_mask[1]}}, {8{wb_mask[0]}}} : 32'h0;
        rvfi_mem_wdata <= wb_rvfi_wdata;
      end
    end
  end

endmodule
