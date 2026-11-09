// March C- memory BIST with an OBI master port (spec 4), so it can test the
// RAM through dp_ram port B behind a 2:1 OBI mux (mux not included).
//
//   M0 up   (w0)       M3 down (r0,w1)
//   M1 up   (r0,w1)    M4 down (r1,w0)
//   M2 up   (r1,w0)    M5 down (r0)
//
// "0" is the data background and "1" its complement. With NBG = 1 the only
// background is all-zeros, which detects stuck-at, transition, address
// decoder and coupling faults between words; faults coupling two bits of
// the same word need the further backgrounds 5555.., 3333.., 0F0F..,
// 00FF.., 0000FFFF (NBG up to 6), each a full March C- pass.
//
// Word accesses only (be = 4'hF), one outstanding transaction, two cycles
// per access against a slave that grants at once and answers next cycle:
// 10 * 2^AW * NBG accesses in all. start is accepted when idle or done;
// done stays high until the next start. fail is sticky and fail_* hold the
// first mismatch: byte address, element (0..5), background, and the XOR of
// expected and read data.
module mbist_marchc #(
  parameter int          AW   = 14,  // words tested: 2^AW
  parameter logic [31:0] BASE = 32'h0000_0000,
  parameter int          NBG  = 1    // data backgrounds, 1..6
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  output logic        busy,
  output logic        done,
  output logic        fail,
  output logic [31:0] fail_addr,
  output logic [2:0]  fail_elem,
  output logic [2:0]  fail_bg,
  output logic [31:0] fail_syn,

  output logic        obi_req,
  input  logic        obi_gnt,
  output logic [31:0] obi_addr,
  output logic        obi_we,
  output logic [3:0]  obi_be,
  output logic [31:0] obi_wdata,
  input  logic        obi_rvalid,
  input  logic [31:0] obi_rdata
);
  localparam logic [AW-1:0] LAST   = {AW{1'b1}};
  localparam logic [2:0]    BgMax = 3'(NBG - 1);

  typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_WAIT, S_DONE} state_e;
  state_e        st;
  logic [2:0]    elem, bg;
  logic          op;      // index of the access within the element
  logic [AW-1:0] idx;

  // Element decode.
  logic down, rd, two_ops, pol;  // pol: complement of the background
  always_comb begin
    down    = (elem >= 3'd3);
    two_ops = (elem != 3'd0) && (elem != 3'd5);
    rd      = (elem == 3'd5) || (two_ops && !op);
    unique case (elem)
      3'd1, 3'd3: pol = op;    // r0, w1
      3'd2, 3'd4: pol = !op;   // r1, w0
      default:    pol = 1'b0;  // w0 / r0
    endcase
  end

  logic [31:0] bg_word, data;
  always_comb begin
    unique case (bg)
      3'd1:    bg_word = 32'h5555_5555;
      3'd2:    bg_word = 32'h3333_3333;
      3'd3:    bg_word = 32'h0F0F_0F0F;
      3'd4:    bg_word = 32'h00FF_00FF;
      3'd5:    bg_word = 32'h0000_FFFF;
      default: bg_word = 32'h0000_0000;
    endcase
    data = pol ? ~bg_word : bg_word;
  end

  // OBI outputs come straight from state flops, so they hold until gnt.
  assign obi_req   = (st == S_ISSUE);
  assign obi_addr  = BASE + (32'(idx) << 2);
  assign obi_we    = !rd;
  assign obi_be    = 4'hF;
  assign obi_wdata = data;

  assign busy = (st == S_ISSUE) || (st == S_WAIT);
  assign done = (st == S_DONE);

  logic last_op, last_idx;
  assign last_op  = !two_ops || op;
  assign last_idx = down ? (idx == '0) : (idx == LAST);

  logic mismatch;
  assign mismatch = rd && (obi_rdata != data);

  always_ff @(posedge clk) begin
    if (rst) begin
      st        <= S_IDLE;
      elem      <= '0;
      bg        <= '0;
      op        <= 1'b0;
      idx       <= '0;
      fail      <= 1'b0;
      fail_addr <= '0;
      fail_elem <= '0;
      fail_bg   <= '0;
      fail_syn  <= '0;
    end else begin
      unique case (st)
        S_IDLE, S_DONE: if (start) begin
          st        <= S_ISSUE;
          elem      <= '0;
          bg        <= '0;
          op        <= 1'b0;
          idx       <= '0;
          fail      <= 1'b0;
          fail_addr <= '0;
          fail_elem <= '0;
          fail_bg   <= '0;
          fail_syn  <= '0;
        end
        S_ISSUE: if (obi_gnt) st <= S_WAIT;
        S_WAIT: if (obi_rvalid) begin
          if (mismatch && !fail) begin
            fail      <= 1'b1;
            fail_addr <= obi_addr;
            fail_elem <= elem;
            fail_bg   <= bg;
            fail_syn  <= obi_rdata ^ data;
          end
          st <= S_ISSUE;
          if (!last_op) begin
            op <= 1'b1;
          end else begin
            op <= 1'b0;
            if (!last_idx) begin
              idx <= down ? idx - 1'b1 : idx + 1'b1;
            end else if (elem != 3'd5) begin
              elem <= elem + 3'd1;
              idx  <= (elem >= 3'd2) ? LAST : '0;  // M3..M5 run down
            end else if (bg != BgMax) begin
              bg   <= bg + 3'd1;
              elem <= '0;
              idx  <= '0;
            end else begin
              st <= S_DONE;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // Elaboration-time range checks.
  if (NBG < 1 || NBG > 6) begin : g_bad_nbg
    $error("mbist_marchc: NBG must be 1..6");
  end
  if (AW < 1 || AW > 30) begin : g_bad_aw
    $error("mbist_marchc: AW must be 1..30");
  end
endmodule
