// JTAG debug transport: a 66-bit user DR that issues single OBI word
// transactions on the system clock. Scan protocol: rtl/debug/README.md.
//
//   DR[65:34] addr   DR[33:2] data   DR[1:0] op      (shifted LSB first)
//   op (Update-DR): 0 NOP, 1 READ, 2 WRITE, 3 STATUS (clear sticky error)
//   Capture-DR:     {last addr, read data, status}
//                   status 0 OK, 2 ERROR (sticky), 3 BUSY
//
// The DR, the sticky error and the request side of the handshake are in the
// tck domain; the OBI master is in the clk domain. They meet only in
// cdc_req_ack, so read data is captured only while the handshake is idle
// (then it is stable). A READ or WRITE while busy, or to a non word-aligned
// address, is dropped and sets the sticky error.
//
// Resets: trst (tck domain) and rst (clk domain) must be released from the
// same power-on event (see cdc_req_ack); do not drive rst from a
// debugger-controlled or button reset.
module jtag_obi_master (
  // tck domain: user DR interface of jtag_tap or BSCANE2
  input  logic        tck,
  input  logic        trst,
  input  logic        user_sel,
  input  logic        user_capture,
  input  logic        user_shift,
  input  logic        user_update,
  input  logic        user_tdi,
  output logic        user_tdo,

  // clk domain: OBI master (spec 4), word accesses only
  input  logic        clk,
  input  logic        rst,
  output logic        obi_req,
  input  logic        obi_gnt,
  output logic [31:0] obi_addr,
  output logic        obi_we,
  output logic [3:0]  obi_be,
  output logic [31:0] obi_wdata,
  input  logic        obi_rvalid,
  input  logic [31:0] obi_rdata
);
  // op 0 (NOP) needs no decode.
  localparam logic [1:0] OpRead = 2'd1, OpWrite = 2'd2, OpStatus = 2'd3;
  localparam logic [1:0] StOk = 2'd0, StErr = 2'd2, StBusy = 2'd3;

  // ---------------- tck domain
  logic [65:0] sr;
  logic        shifted;  // a Shift-DR happened since Capture-DR
  logic        err;
  logic [31:0] last_addr;
  logic        busy;
  logic [31:0] rsp_data;

  logic [1:0]  sr_op;
  logic [31:0] sr_addr, sr_data;
  assign sr_op   = sr[1:0];
  assign sr_data = sr[33:2];
  assign sr_addr = sr[65:34];

  // BSCANE2 asserts CAPTURE/SHIFT/UPDATE for every DR scan, so qualify them
  // with user_sel here (jtag_tap already does; the AND is then redundant).
  logic cap, shf, upd;
  assign cap = user_sel && user_capture;
  assign shf = user_sel && user_shift;
  assign upd = user_sel && user_update;

  logic issue, launch;
  assign issue  = upd && shifted && (sr_op == OpRead || sr_op == OpWrite);
  assign launch = issue && !busy && (sr_addr[1:0] == 2'b00);

  logic [1:0] status;
  assign status = busy ? StBusy : (err ? StErr : StOk);

  always_ff @(posedge tck) begin
    if (trst) begin
      sr        <= '0;
      shifted   <= 1'b0;
      err       <= 1'b0;
      last_addr <= '0;
    end else begin
      if (cap) begin
        // Data is masked while busy: the response word may be changing.
        sr      <= {last_addr, busy ? 32'h0 : rsp_data, status};
        shifted <= 1'b0;
      end else if (shf) begin
        sr      <= {user_tdi, sr[65:1]};
        shifted <= 1'b1;
      end
      // Without a shift the DR still holds the captured status, which must
      // not be replayed as an op.
      if (upd && shifted) begin
        if (sr_op == OpStatus)      err <= 1'b0;
        else if (issue && !launch)   err <= 1'b1;
      end
      if (launch) last_addr <= sr_addr;
    end
  end

  assign user_tdo = sr[0];

  // ---------------- clock-domain crossing: {we, addr, wdata} -> rdata
  logic        dst_valid, dst_pend, dst_ack, src_done;
  logic [64:0] dst_data;
  logic [31:0] rsp_q;

  cdc_req_ack #(.REQ_W(65), .RSP_W(32)) u_cdc (
    .src_clk  (tck),
    .src_rst  (trst),
    .src_valid(launch),
    .src_data ({sr_op == OpWrite, sr_addr, sr_data}),
    .src_busy (busy),
    .src_done (src_done),
    .src_rsp  (rsp_data),
    .dst_clk  (clk),
    .dst_rst  (rst),
    .dst_valid(dst_valid),
    .dst_data (dst_data),
    .dst_pend (dst_pend),
    .dst_ack  (dst_ack),
    .dst_rsp  (rsp_q)
  );

  // ---------------- clk domain: one OBI transaction per request
  typedef enum logic [1:0] {S_IDLE, S_REQ, S_RSP} state_e;
  state_e st;

  always_ff @(posedge clk) begin
    if (rst) begin
      st        <= S_IDLE;
      obi_req   <= 1'b0;
      obi_we    <= 1'b0;
      obi_addr  <= '0;
      obi_wdata <= '0;
    end else begin
      unique case (st)
        S_IDLE: if (dst_valid) begin
          // Register the crossing word so the OBI outputs launch from clk.
          {obi_we, obi_addr, obi_wdata} <= dst_data;
          obi_req <= 1'b1;
          st      <= S_REQ;
        end
        S_REQ: if (obi_gnt) begin
          obi_req <= 1'b0;
          st      <= S_RSP;
        end
        S_RSP: if (obi_rvalid) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end

  assign obi_be  = 4'hF;
  assign dst_ack = (st == S_RSP) && obi_rvalid;
  // Writes return 0: OBI rdata is undefined on a write response.
  assign rsp_q   = obi_we ? 32'h0 : obi_rdata;

  logic unused;
  assign unused = ^{dst_pend, src_done};
endmodule
