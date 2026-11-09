// Formal harness: obi_arb2 with two free masters and a free slave. Master
// rules (M1) are assumed on both master links and slave rules (S1, S2) are
// asserted there; on the slave link the slave rules are assumed and M1 is
// asserted. On top: grants are exclusive and only to a requester, a granted
// request is the one the slave sees, responses go to one master, and a
// waiting master is passed over by at most one handshake of the other.
module arb_formal_top (
  input logic        clk,
  input logic        rst,
  input logic        m0_req,
  input logic [31:0] m0_addr,
  input logic        m0_we,
  input logic [3:0]  m0_be,
  input logic [31:0] m0_wdata,
  input logic        m1_req,
  input logic [31:0] m1_addr,
  input logic        m1_we,
  input logic [3:0]  m1_be,
  input logic [31:0] m1_wdata,
  input logic        s_gnt,
  input logic        s_rvalid,
  input logic [31:0] s_rdata
);
  logic        m0_gnt, m0_rvalid, m1_gnt, m1_rvalid;
  logic [31:0] m0_rdata, m1_rdata;
  logic        s_req, s_we;
  logic [31:0] s_addr, s_wdata;
  logic [3:0]  s_be;

  obi_arb2 dut (.*);

  obi_checker #(.ASSUME_M(1'b1)) chk_m0 (
    .clk, .rst, .req(m0_req), .gnt(m0_gnt), .addr(m0_addr), .we(m0_we), .be(m0_be),
    .wdata(m0_wdata), .rvalid(m0_rvalid)
  );
  obi_checker #(.ASSUME_M(1'b1)) chk_m1 (
    .clk, .rst, .req(m1_req), .gnt(m1_gnt), .addr(m1_addr), .we(m1_we), .be(m1_be),
    .wdata(m1_wdata), .rvalid(m1_rvalid)
  );
  obi_checker #(.ASSUME_S(1'b1)) chk_s (
    .clk, .rst, .req(s_req), .gnt(s_gnt), .addr(s_addr), .we(s_we), .be(s_be),
    .wdata(s_wdata), .rvalid(s_rvalid)
  );

  initial assume (rst);

  // Handshakes of the other master while this one waits.
  logic [2:0] pass0, pass1;
  always @(posedge clk) begin
    if (rst) begin
      pass0 <= '0;
      pass1 <= '0;
    end else begin
      if (!m0_req || m0_gnt) pass0 <= '0;
      else if (m1_gnt && pass0 != 3'd7) pass0 <= pass0 + 3'd1;
      if (!m1_req || m1_gnt) pass1 <= '0;
      else if (m0_gnt && pass1 != 3'd7) pass1 <= pass1 + 3'd1;
    end
  end

  // A request presented downstream and not granted last cycle.
  logic stalled_q;
  always @(posedge clk) stalled_q <= !rst && s_req && !s_gnt;

  // Fair-grant cover state: m0 then m1 then m0 granted while both request.
  logic [1:0] alt;
  always @(posedge clk) begin
    if (rst) alt <= '0;
    else if (m0_req && m1_req) begin
      if (m0_gnt && alt != 2'd1 && alt != 2'd3) alt <= alt + 2'd1;
      else if (m1_gnt && alt == 2'd1) alt <= 2'd2;
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      arb_gnt_exclusive: assert (!(m0_gnt && m1_gnt));
      arb_gnt_m0_req: assert (!m0_gnt || m0_req);
      arb_gnt_m1_req: assert (!m1_gnt || m1_req);
      arb_fwd_m0: assert (!m0_gnt || (s_addr == m0_addr && s_we == m0_we && s_be == m0_be &&
                                      s_wdata == m0_wdata));
      arb_fwd_m1: assert (!m1_gnt || (s_addr == m1_addr && s_we == m1_we && s_be == m1_be &&
                                      s_wdata == m1_wdata));
      arb_gnt_is_slave_gnt: assert ((m0_gnt || m1_gnt) == (s_req && s_gnt));
      arb_rvalid_one: assert (!(m0_rvalid && m1_rvalid));
      arb_rvalid_routed: assert ((m0_rvalid || m1_rvalid) == s_rvalid);
      arb_fair_m0: assert (pass0 <= 3'd1);
      arb_fair_m1: assert (pass1 <= 3'd1);

      cov_both_req_m1_wins: cover (m0_req && m1_req && m1_gnt);
      cov_both_req_m0_wins: cover (m0_req && m1_req && m0_gnt);
      cov_alternate: cover (alt == 2'd2 && m0_req && m1_req && m0_gnt);
      cov_stall_then_gnt: cover (stalled_q && m1_gnt);
      cov_m1_response: cover (m1_rvalid && m0_req);
    end
  end
endmodule
