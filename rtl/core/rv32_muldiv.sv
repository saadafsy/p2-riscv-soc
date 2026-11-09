// M extension unit, used from EX.
// Multiply, 4 EX cycles: (1) operands registered as 33-bit signed values, one copy per
// partial product (fanout); (2) four 17 x 17 partial products registered; (3) 3:2
// carry-save step, 64-bit add, high/low word select, registered; (4) result out.
// Divide, 34 EX cycles: magnitudes registered, 32 radix-2 restoring steps, sign fix.
// The core holds EX while the op is in EX and !done; clear drops any operation in flight.
module rv32_muldiv (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,   // EX holds an M op, operands valid this cycle
    input  logic        clear,   // EX advances or is flushed
    input  logic [ 2:0] op,      // funct3
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        busy,
    output logic        done,
    output logic [31:0] result
);

  localparam logic [2:0] SIdle = 3'd0;
  localparam logic [2:0] SMulA = 3'd1;  // operands held: partial products
  localparam logic [2:0] SMulB = 3'd2;  // partials held: sum
  localparam logic [2:0] SMulC = 3'd3;  // product word held: result valid
  localparam logic [2:0] SDiv = 3'd4;
  localparam logic [2:0] SDone = 3'd5;  // quotient/remainder valid

  logic [2:0] state;
  logic [2:0] op_q;
  logic [4:0] cnt;
  logic [31:0] rem, quo, den, mres;
  logic neg_q, neg_r;

  // Operand set-up: MUL/MULH sign-extend both, MULHSU only rs1, MULHU neither.
  // DIV/REM take magnitudes; the quotient keeps all ones on a zero divisor.
  logic a_sgn, b_sgn, d_sgn, a_neg, b_neg, a_x, b_x;
  logic [31:0] a_abs, b_abs;
  assign a_sgn = op[1:0] != 2'b11;
  assign b_sgn = !op[1];
  assign d_sgn = !op[0];
  assign a_x   = a_sgn && a[31];
  assign b_x   = b_sgn && b[31];
  assign a_neg = d_sgn && a[31];
  assign b_neg = d_sgn && b[31];
  assign a_abs = a_neg ? 32'd0 - a : a;
  assign b_abs = b_neg ? 32'd0 - b : b;

  // {a_x, a} = ah * 2^16 + al, ah = {a_x, a[31:16]} signed, al = a[15:0] unsigned; same
  // for b. Each partial product has its own operand flops.
  (* keep *) logic [15:0] ll_a, ll_b, lh_a, hl_b;
  (* keep *) logic [16:0] lh_b, hl_a, hh_a, hh_b;
  logic [31:0] p_ll, p_hh;
  logic signed [33:0] p_lh, p_hl;
  logic [31:0] pp_ll;
  logic signed [33:0] pp_lh, pp_hl;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [33:0] pp_hh;  // only bits 31:0 reach the low 64 bits of the product
  /* verilator lint_on UNUSEDSIGNAL */
  assign pp_ll = ll_a * ll_b;
  assign pp_lh = $signed({1'b0, lh_a}) * $signed(lh_b);
  assign pp_hl = $signed(hl_a) * $signed({1'b0, hl_b});
  assign pp_hh = $signed(hh_a) * $signed(hh_b);

  // product[63:0] = {hh, ll} + (lh << 16) + (hl << 16)
  logic [63:0] sx, sy, sz, cs_s, cs_c, prod;
  assign sx   = {p_hh, p_ll};
  assign sy   = {{14{p_lh[33]}}, p_lh, 16'h0};
  assign sz   = {{14{p_hl[33]}}, p_hl, 16'h0};
  assign cs_s = sx ^ sy ^ sz;
  assign cs_c = {(sx[62:0] & sy[62:0]) | (sx[62:0] & sz[62:0]) | (sy[62:0] & sz[62:0]), 1'b0};
  assign prod = cs_s + cs_c;

  // One restoring step: shift in the next dividend bit, subtract if it fits.
  logic [32:0] r_sh, diff;
  assign r_sh = {rem, quo[31]};
  assign diff = r_sh - {1'b0, den};

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= SIdle;
      op_q  <= 3'd0;
      cnt   <= 5'd0;
      ll_a  <= 16'd0;
      ll_b  <= 16'd0;
      lh_a  <= 16'd0;
      lh_b  <= 17'd0;
      hl_a  <= 17'd0;
      hl_b  <= 16'd0;
      hh_a  <= 17'd0;
      hh_b  <= 17'd0;
      p_ll  <= 32'd0;
      p_hh  <= 32'd0;
      p_lh  <= 34'sd0;
      p_hl  <= 34'sd0;
      mres  <= 32'd0;
      rem   <= 32'd0;
      quo   <= 32'd0;
      den   <= 32'd0;
      neg_q <= 1'b0;
      neg_r <= 1'b0;
    end else if (clear) begin
      state <= SIdle;
    end else begin
      unique case (state)
        SIdle: begin
          if (start) begin
            op_q <= op;
            if (op[2]) begin
              state <= SDiv;
              cnt   <= 5'd0;
              rem   <= 32'd0;
              quo   <= a_abs;
              den   <= b_abs;
              neg_q <= (a_neg ^ b_neg) && b != 32'd0;
              neg_r <= a_neg;
            end else begin
              state <= SMulA;
              ll_a  <= a[15:0];
              ll_b  <= b[15:0];
              lh_a  <= a[15:0];
              lh_b  <= {b_x, b[31:16]};
              hl_a  <= {a_x, a[31:16]};
              hl_b  <= b[15:0];
              hh_a  <= {a_x, a[31:16]};
              hh_b  <= {b_x, b[31:16]};
            end
          end
        end
        SMulA: begin
          state <= SMulB;
          p_ll  <= pp_ll;
          p_lh  <= pp_lh;
          p_hl  <= pp_hl;
          p_hh  <= pp_hh[31:0];
        end
        SMulB: begin
          state <= SMulC;
          mres  <= op_q[1:0] == 2'b00 ? prod[31:0] : prod[63:32];
        end
        SDiv: begin
          if (diff[32]) begin
            rem <= r_sh[31:0];
            quo <= {quo[30:0], 1'b0};
          end else begin
            rem <= diff[31:0];
            quo <= {quo[30:0], 1'b1};
          end
          cnt <= cnt + 5'd1;
          if (cnt == 5'd31) state <= SDone;
        end
        default: ;  // SMulC, SDone: hold the result until clear
      endcase
    end
  end

  assign busy = state != SIdle;
  assign done = state == SMulC || state == SDone;

  logic [31:0] q_out, r_out;
  assign q_out  = neg_q ? 32'd0 - quo : quo;
  assign r_out  = neg_r ? 32'd0 - rem : rem;

`ifdef RISCV_FORMAL_ALTOPS
  // riscv-formal's substitute M functions (insns/insn_*.v): same timing and
  // control, a datapath the solver can handle. Formal runs only.
  logic [31:0] alt_a, alt_b, alt_r;
  always_ff @(posedge clk) begin
    if (rst) begin
      alt_a <= 32'd0;
      alt_b <= 32'd0;
    end else if (!clear && state == SIdle && start) begin
      alt_a <= a;
      alt_b <= b;
    end
  end
  always_comb begin
    unique case (op_q)
      3'd0:    alt_r = (alt_a + alt_b) ^ 32'h5876_063e;  // MUL
      3'd1:    alt_r = (alt_a + alt_b) ^ 32'hf658_3fb7;  // MULH
      3'd2:    alt_r = (alt_a - alt_b) ^ 32'hecfb_e137;  // MULHSU
      3'd3:    alt_r = (alt_a + alt_b) ^ 32'h949c_e5e8;  // MULHU
      3'd4:    alt_r = (alt_a - alt_b) ^ 32'h7f85_29ec;  // DIV
      3'd5:    alt_r = (alt_a - alt_b) ^ 32'h10e8_fd70;  // DIVU
      3'd6:    alt_r = (alt_a - alt_b) ^ 32'h8da6_8fa5;  // REM
      default: alt_r = (alt_a - alt_b) ^ 32'h3138_d0e1;  // REMU
    endcase
  end
  assign result = alt_r;
`else
  assign result = !op_q[2] ? mres : op_q[1] ? r_out : q_out;
`endif

`ifdef FORMAL
  // Each multi-cycle state moves on every cycle until cleared: a multiply is done
  // after 3 cycles, a divide after 33; done states hold.
  logic       f_past;
  logic [2:0] f_state;
  logic [4:0] f_cnt;
  logic       f_clear;
  always_ff @(posedge clk) begin
    f_past  <= !rst;
    f_state <= state;
    f_cnt   <= cnt;
    f_clear <= clear;
  end
  always_comb begin
    if (!rst) assert (state <= SDone);
    if (!rst && f_past && !f_clear && f_state == SDiv)
      assert ((state == SDiv && cnt == f_cnt + 5'd1) || (state == SDone && f_cnt == 5'd31));
    if (!rst && f_past && !f_clear && f_state == SMulA) assert (state == SMulB);
    if (!rst && f_past && !f_clear && f_state == SMulB) assert (state == SMulC);
    if (!rst && f_past && !f_clear && (f_state == SMulC || f_state == SDone))
      assert (state == f_state);
  end
`endif

endmodule
