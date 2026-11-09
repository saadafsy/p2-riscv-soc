// OBI protocol checker (spec 4). Instantiate or bind on any OBI link.
// Rules are plain clocked immediate assertions over local history registers,
// so the same file runs in Verilator (--assert) and in SymbiYosys.
// ASSUME_M / ASSUME_S turn the master-side / slave-side rules into
// assumptions, for formal runs where that side is a free input.
//   M1 req, addr, we, be, wdata held stable from req until gnt
//   S1 rvalid only for an accepted, not yet answered transaction
//   S2 at most one outstanding: no gnt while one is owed, unless its rvalid is now
// fired[] is sticky per rule, for negative tests that drive bad stimulus.
module obi_checker #(
  parameter bit ASSUME_M = 1'b0,
  parameter bit ASSUME_S = 1'b0
) (
  input logic        clk,
  input logic        rst,
  input logic        req,
  input logic        gnt,
  input logic [31:0] addr,
  input logic        we,
  input logic [3:0]  be,
  input logic [31:0] wdata,
  input logic        rvalid
);
  logic        req_q, gnt_q, we_q;
  logic [31:0] addr_q, wdata_q;
  logic [3:0]  be_q;
  logic        outst;  // one transaction owed a response

  always @(posedge clk) begin
    if (rst) begin
      req_q   <= 1'b0;
      gnt_q   <= 1'b0;
      we_q    <= 1'b0;
      addr_q  <= '0;
      wdata_q <= '0;
      be_q    <= '0;
      outst   <= 1'b0;
    end else begin
      req_q   <= req;
      gnt_q   <= gnt;
      we_q    <= we;
      addr_q  <= addr;
      wdata_q <= wdata;
      be_q    <= be;
      if (req && gnt) outst <= 1'b1;
      else if (rvalid) outst <= 1'b0;
    end
  end

  logic m1_ok, s1_ok, s2_ok;
  assign m1_ok = !(req_q && !gnt_q) ||
                 (req && addr == addr_q && we == we_q && be == be_q && wdata == wdata_q);
  assign s1_ok = !rvalid || outst;
  assign s2_ok = !(req && gnt && outst && !rvalid);

  generate
    if (ASSUME_M) begin : g_m_assume
      always @(posedge clk) if (!rst) obi_m1_hold: assume (m1_ok);
    end else begin : g_m_assert
      always @(posedge clk) if (!rst) obi_m1_hold: assert (m1_ok);
    end
    if (ASSUME_S) begin : g_s_assume
      always @(posedge clk) begin
        if (!rst) begin
          obi_s1_rvalid: assume (s1_ok);
          obi_s2_one_outstanding: assume (s2_ok);
        end
      end
    end else begin : g_s_assert
      always @(posedge clk) begin
        if (!rst) begin
          obi_s1_rvalid: assert (s1_ok);
          obi_s2_one_outstanding: assert (s2_ok);
        end
      end
    end
  endgenerate

`ifndef FORMAL
  logic [2:0] fired;
  always @(posedge clk) begin
    if (rst) fired <= '0;
    else fired <= fired | {!s2_ok, !s1_ok, !m1_ok};
  end
`endif
endmodule
