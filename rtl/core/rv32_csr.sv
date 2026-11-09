// Machine-mode CSR file, trap entry/exit state and interrupt pending logic.
module rv32_csr (
    input  logic        clk,
    input  logic        rst,
    input  logic        irq_timer,
    input  logic        irq_external,
    // CSR instruction in EX
    input  logic [11:0] addr,
    input  logic        wr_intent,   // the instruction would write (legality check)
    output logic [31:0] rdata,
    output logic        illegal,
    input  logic        wr_en,       // commit the write this cycle
    input  logic [ 1:0] op,          // 01 RW, 10 RS, 11 RC
    input  logic [31:0] wsrc,
    // trap entry at the MEM/WB boundary, MRET in EX
    input  logic        trap_en,
    input  logic [31:2] trap_pc,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_tval,
    input  logic        mret_en,
    input  logic        retire_en,   // one instruction retired (minstret)
    output logic [31:0] mtvec_o,
    output logic [31:0] mepc_o,
    output logic        irq_pending,
    output logic [31:0] irq_cause
);

  logic        mstatus_mie, mstatus_mpie, mie_mtie, mie_meie;
  logic [31:2] mtvec, mepc;
  logic [31:0] mscratch, mcause, mtval;
  logic [63:0] mcycle, minstret;
  logic [31:0] wval;
  logic        known;

  always_comb begin
    known = 1'b1;
    unique case (addr)
      12'h300: rdata = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
      12'h301: rdata = 32'h4000_1100;  // MXL=32, I, M
      12'h304: rdata = {20'b0, mie_meie, 3'b0, mie_mtie, 7'b0};
      12'h305: rdata = {mtvec, 2'b00};
      12'h340: rdata = mscratch;
      12'h341: rdata = {mepc, 2'b00};
      12'h342: rdata = mcause;
      12'h343: rdata = mtval;
      12'h344: rdata = {20'b0, irq_external, 3'b0, irq_timer, 7'b0};
      12'hB00, 12'hC00: rdata = mcycle[31:0];
      12'hB80, 12'hC80: rdata = mcycle[63:32];
      12'hB02, 12'hC02: rdata = minstret[31:0];
      12'hB82, 12'hC82: rdata = minstret[63:32];
      12'hF11, 12'hF12, 12'hF13, 12'hF14: rdata = 32'h0;
      default: begin
        rdata = 32'h0;
        known = 1'b0;
      end
    endcase
  end

  // addr[11:10] == 2'b11 marks the read-only CSR space.
  assign illegal = !known || (wr_intent && addr[11:10] == 2'b11);

  always_comb begin
    unique case (op)
      2'b10:   wval = rdata | wsrc;
      2'b11:   wval = rdata & ~wsrc;
      default: wval = wsrc;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_mtie     <= 1'b0;
      mie_meie     <= 1'b0;
      mtvec        <= 30'h0;
      mepc         <= 30'h0;
      mscratch     <= 32'h0;
      mcause       <= 32'h0;
      mtval        <= 32'h0;
      mcycle       <= 64'h0;
      minstret     <= 64'h0;
    end else begin
      // A counter write takes precedence over that cycle's increment.
      if (wr_en && addr == 12'hB00) mcycle <= {mcycle[63:32], wval};
      else if (wr_en && addr == 12'hB80) mcycle <= {wval, mcycle[31:0]};
      else mcycle <= mcycle + 64'd1;

      if (wr_en && addr == 12'hB02) minstret <= {minstret[63:32], wval};
      else if (wr_en && addr == 12'hB82) minstret <= {wval, minstret[31:0]};
      else if (retire_en) minstret <= minstret + 64'd1;

      if (trap_en) begin
        mepc         <= trap_pc;
        mcause       <= trap_cause;
        mtval        <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (mret_en) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (wr_en) begin
        unique case (addr)
          12'h300: begin
            mstatus_mie  <= wval[3];
            mstatus_mpie <= wval[7];
          end
          12'h304: begin
            mie_mtie <= wval[7];
            mie_meie <= wval[11];
          end
          12'h305: mtvec <= wval[31:2];
          12'h340: mscratch <= wval;
          12'h341: mepc <= wval[31:2];
          12'h342: mcause <= wval;
          12'h343: mtval <= wval;
          default: ;  // misa, mip and counters: ignored here or handled above
        endcase
      end
    end
  end

  logic ext_pend, tim_pend;
  assign ext_pend    = mstatus_mie && mie_meie && irq_external;
  assign tim_pend    = mstatus_mie && mie_mtie && irq_timer;
  assign irq_pending = ext_pend || tim_pend;
  assign irq_cause   = ext_pend ? 32'h8000_000B : 32'h8000_0007;
  assign mtvec_o     = {mtvec, 2'b00};
  assign mepc_o      = {mepc, 2'b00};

endmodule
