// Two-phase (toggle) request/acknowledge handshake between two unrelated
// clocks, carrying a request word src -> dst and a response word dst -> src.
//
// Source: src_valid launches a request when !src_busy (ignored otherwise).
// The request word is registered and held until the response returns, and
// req_tgl flips on the same edge; dst sees the toggle only after two dst
// flops, so the word has been stable for at least one dst cycle by then.
// Destination: dst_valid pulses once per request, dst_data stays stable
// until dst_ack. dst_ack (ignored unless a request is pending) registers the
// response and flips ack_tgl. The source sees it two src flops later, so
// src_rsp is stable whenever !src_busy.
//
// Toggle protocols need both sides to leave reset together: src_rst and
// dst_rst must come from the same power-on event. Resetting only one side
// while a toggle is set can replay or drop one request.
module cdc_req_ack #(
  parameter int REQ_W = 8,
  parameter int RSP_W = 8
) (
  input  logic             src_clk,
  input  logic             src_rst,
  input  logic             src_valid,
  input  logic [REQ_W-1:0] src_data,
  output logic             src_busy,
  output logic             src_done,  // one src cycle when the response lands
  output logic [RSP_W-1:0] src_rsp,   // stable while !src_busy

  input  logic             dst_clk,
  input  logic             dst_rst,
  output logic             dst_valid,  // one dst cycle per request
  output logic [REQ_W-1:0] dst_data,   // stable from dst_valid until dst_ack
  output logic             dst_pend,   // request accepted, not yet acked
  input  logic             dst_ack,
  input  logic [RSP_W-1:0] dst_rsp
);
  // ---- source domain
  logic             req_tgl;
  logic [REQ_W-1:0] req_q;
  (* ASYNC_REG = "TRUE" *) logic ack_meta, ack_sync;
  logic             ack_seen;

  assign src_busy = req_tgl ^ ack_sync;
  assign src_done = ack_sync ^ ack_seen;

  always_ff @(posedge src_clk) begin
    if (src_rst) begin
      req_tgl  <= 1'b0;
      req_q    <= '0;
      ack_meta <= 1'b0;
      ack_sync <= 1'b0;
      ack_seen <= 1'b0;
    end else begin
      ack_meta <= ack_tgl;
      ack_sync <= ack_meta;
      ack_seen <= ack_sync;
      if (src_valid && !src_busy) begin
        req_q   <= src_data;
        req_tgl <= ~req_tgl;
      end
    end
  end

  // ---- destination domain
  logic             ack_tgl;
  logic [RSP_W-1:0] rsp_q;
  (* ASYNC_REG = "TRUE" *) logic req_meta, req_sync;
  logic             req_seen;

  assign dst_valid = req_sync ^ req_seen;
  assign dst_data  = req_q;
  assign src_rsp   = rsp_q;

  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      req_meta <= 1'b0;
      req_sync <= 1'b0;
      req_seen <= 1'b0;
      dst_pend <= 1'b0;
      ack_tgl  <= 1'b0;
      rsp_q    <= '0;
    end else begin
      req_meta <= req_tgl;
      req_sync <= req_meta;
      req_seen <= req_sync;
      if (dst_valid) begin
        dst_pend <= 1'b1;
      end else if (dst_ack && dst_pend) begin
        dst_pend <= 1'b0;
        rsp_q    <= dst_rsp;
        ack_tgl  <= ~ack_tgl;
      end
    end
  end
endmodule
