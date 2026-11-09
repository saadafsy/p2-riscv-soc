// Formal harness for cdc_req_ack: both clocks are free inputs (multiclock), so
// the solver picks any frequency ratio and phase, including stopped clocks.
// Both domains are held in reset until each has seen a reset edge (the
// common power-on reset the module requires), then reset stays low.
// Proven within the BMC depth: no request lost or duplicated in either
// direction, request and response words arrive intact and stay stable.
module debug_cdc_top (
  input logic       src_clk,
  input logic       dst_clk,
  input logic       rst,
  input logic       src_valid,
  input logic [7:0] src_data,
  input logic       dst_ack,
  input logic [7:0] dst_rsp
);
  logic       src_busy, src_done, dst_valid, dst_pend;
  logic [7:0] src_rsp, dst_data;

  cdc_req_ack #(.REQ_W(8), .RSP_W(8)) dut (
    .src_clk, .src_rst(rst), .src_valid, .src_data, .src_busy, .src_done, .src_rsp,
    .dst_clk, .dst_rst(rst), .dst_valid, .dst_data, .dst_pend, .dst_ack, .dst_rsp
  );

  // ---- common power-on reset
  logic src_init = 1'b0, dst_init = 1'b0;
  always @(posedge src_clk) if (rst) src_init <= 1'b1;
  always @(posedge dst_clk) if (rst) dst_init <= 1'b1;
  logic armed;
  assign armed = src_init && dst_init;
  always @* begin
    if (!armed) assume (rst);
    else        assume (!rst);
  end

  // ---- event counters (mod 16) and scoreboards, one per domain
  logic [3:0] n_req = '0, n_done = '0, n_dst = '0, n_ack = '0;
  logic [7:0] last_req = '0, last_rsp = '0;

  always @(posedge src_clk) if (!rst) begin
    if (src_valid && !src_busy) begin
      n_req    <= n_req + 1'b1;
      last_req <= src_data;
    end
    if (src_done) n_done <= n_done + 1'b1;
  end

  always @(posedge dst_clk) if (!rst) begin
    if (dst_valid) n_dst <= n_dst + 1'b1;
    if (dst_ack && dst_pend) begin
      n_ack    <= n_ack + 1'b1;
      last_rsp <= dst_rsp;
    end
  end

  logic [3:0] d_req_dst, d_dst_ack, d_ack_done, d_req_done;
  assign d_req_dst  = n_req - n_dst;
  assign d_dst_ack  = n_dst - n_ack;
  assign d_ack_done = n_ack - n_done;
  assign d_req_done = n_req - n_done;

  // Bounded delivery: a launched request reaches dst, and an ack reaches
  // src, within three edges of the receiving clock (two synchronizer flops,
  // plus the edge at which the harness counts the event). This turns a
  // lost toggle (a deadlock) into a BMC failure.
  // Counted on the solver step (global clock) so they clear as soon as the
  // event is delivered, not at the next edge of the receiving clock.
  (* gclk *) logic gclk;
  logic       src_clk_q = 1'b0, dst_clk_q = 1'b0;
  logic [2:0] dst_wait = '0, src_wait = '0;
  always @(posedge gclk) begin
    src_clk_q <= src_clk;
    dst_clk_q <= dst_clk;
    if (rst || d_req_dst == 4'd0)   dst_wait <= '0;
    else if (dst_clk && !dst_clk_q) dst_wait <= dst_wait + 1'b1;
    if (rst || d_ack_done == 4'd0)  src_wait <= '0;
    else if (src_clk && !src_clk_q) src_wait <= src_wait + 1'b1;
  end

  always @* if (armed && !rst) begin
    assert (dst_wait <= 3'd3);
    assert (src_wait <= 3'd3);
    // Each accepted request reaches dst once, is acked once, completes once.
    assert (d_req_dst  <= 4'd1);
    assert (d_dst_ack  <= 4'd1);
    assert (d_ack_done <= 4'd1);
    // n_done counts src_done on the next src edge, so the done pulse is
    // still owed in the cycle it is high.
    assert (d_req_done == {3'b0, src_busy || src_done});
    assert (!(src_busy && src_done));
    assert (!(dst_valid && dst_pend));
    // Request word intact at dst and stable until acked.
    if (dst_valid || dst_pend) assert (dst_data == last_req);
    // Response word intact at src and stable whenever the source is idle.
    if (!src_busy) assert (src_rsp == last_rsp);
    if (src_done)  assert (src_rsp == last_rsp);
  end

  always @* if (armed && !rst) begin
    cover (n_done == 4'd3);
    cover (n_done == 4'd2 && src_busy && dst_pend);
  end
endmodule
