// Formal harness: async_fifo with two unrelated, free-running clocks
// (SymbiYosys multiclock). Both domains are reset at the start: rst stays
// high until each clock has had two rising edges, then stays low.
// Checked: no overflow (occupancy <= depth; !wfull means room), no
// underflow (!rempty means data), and order: the K-th entry read is the
// K-th entry written, for an arbitrary K.
module accel_fifo_top (
  input logic       wclk,
  input logic       rclk,
  input logic       rst,
  input logic       winc,
  input logic [7:0] wdata,
  input logic       rinc
);
  localparam int AW = 2, Depth = 4, CW = 4;  // counters wrap well past Depth

  logic       wfull, rempty;
  logic [7:0] rdata;

  async_fifo #(.W(8), .AW(AW)) dut (
    .wclk, .wrst(rst), .winc, .wdata, .wfull,
    .rclk, .rrst(rst), .rinc, .rdata, .rempty
  );

  (* gclk *) logic gclk;

  // ---- reset sequencing
  logic       wclk_q = 1'b0, rclk_q = 1'b0, rst_q = 1'b1;
  logic [1:0] wseen = 2'd0, rseen = 2'd0;
  always_ff @(posedge gclk) begin
    wclk_q <= wclk;
    rclk_q <= rclk;
    rst_q  <= rst;
    if (rst && wclk && !wclk_q && wseen != 2'd3) wseen <= wseen + 2'd1;
    if (rst && rclk && !rclk_q && rseen != 2'd3) rseen <= rseen + 2'd1;
  end
  initial assume (rst);
  always_comb begin
    if (!rst_q) assume (!rst);
    if (!rst) assume (wseen >= 2'd2 && rseen >= 2'd2);
  end

  // ---- scoreboard: push / pop counts and the K-th entry
  logic [CW-1:0] wcnt, rcnt;
  (* anyconst *) logic [CW-1:0] k;
  logic       cap_v;
  logic [7:0] cap_d;
  logic [CW-1:0] occ;

  always_ff @(posedge wclk) begin
    if (rst) begin
      wcnt  <= '0;
      cap_v <= 1'b0;
      cap_d <= '0;
    end else if (winc && !wfull) begin
      wcnt <= wcnt + 1'b1;
      if (wcnt == k) begin
        cap_v <= 1'b1;
        cap_d <= wdata;
      end
    end
  end

  always_ff @(posedge rclk) begin
    if (rst) rcnt <= '0;
    else if (rinc && !rempty) rcnt <= rcnt + 1'b1;
  end

  assign occ = wcnt - rcnt;

  always_comb begin
    if (!rst) begin
      a_no_overflow:  assert (occ <= Depth);
      a_full_honest:  assert (wfull || occ < Depth);
      a_empty_honest: assert (rempty || occ != '0);
      if (!rempty && rcnt == k) a_order: assert (cap_v && rdata == cap_d);
    end
  end

  // ---- reachability
  logic was_full = 1'b0, wrapped = 1'b0;
  always_ff @(posedge gclk) begin
    if (!rst && wfull) was_full <= 1'b1;
    if (!rst && was_full && wcnt == 4'd9) wrapped <= 1'b1;
  end
  always_comb begin
    if (!rst) begin
      c_full:         cover (wfull);
      c_full_drained: cover (was_full && rempty && wcnt != '0);
      c_wrapped:      cover (wrapped && rcnt == 4'd9);
    end
  end
endmodule
