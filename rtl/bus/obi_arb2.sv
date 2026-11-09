// Two-master OBI arbiter (spec 13.1): m0 = core data port, m1 = JTAG debug
// master, one slave port (the obi_decoder). Round-robin: when both request
// in the same cycle, the master that did not win the last handshake wins.
// A master that requests alone is forwarded combinationally, so the core
// alone sees no extra latency.
// Once a request has been presented downstream without a grant, the choice
// is locked until that grant (the slave sees addr/we/be/wdata held, OBI rule
// M1). The downstream link carries one transaction at a time (the decoder
// enforces it); the response goes to the master registered at the handshake.
module obi_arb2 (
  input  logic        clk,
  input  logic        rst,
  // master 0 (core data port)
  input  logic        m0_req,
  output logic        m0_gnt,
  input  logic [31:0] m0_addr,
  input  logic        m0_we,
  input  logic [3:0]  m0_be,
  input  logic [31:0] m0_wdata,
  output logic        m0_rvalid,
  output logic [31:0] m0_rdata,
  // master 1 (debug)
  input  logic        m1_req,
  output logic        m1_gnt,
  input  logic [31:0] m1_addr,
  input  logic        m1_we,
  input  logic [3:0]  m1_be,
  input  logic [31:0] m1_wdata,
  output logic        m1_rvalid,
  output logic [31:0] m1_rdata,
  // slave port
  output logic        s_req,
  input  logic        s_gnt,
  output logic [31:0] s_addr,
  output logic        s_we,
  output logic [3:0]  s_be,
  output logic [31:0] s_wdata,
  input  logic        s_rvalid,
  input  logic [31:0] s_rdata
);
  logic lock_q, lock_sel_q;  // a presented request is waiting for its grant
  logic prio_q;              // master that wins a tie
  logic owner_q;             // master owed the next response
  logic sel, hs;

  always_comb begin
    if (lock_q)              sel = lock_sel_q;
    else if (m0_req && m1_req) sel = prio_q;
    else                     sel = m1_req;
  end

  assign s_req   = sel ? m1_req   : m0_req;
  assign s_addr  = sel ? m1_addr  : m0_addr;
  assign s_we    = sel ? m1_we    : m0_we;
  assign s_be    = sel ? m1_be    : m0_be;
  assign s_wdata = sel ? m1_wdata : m0_wdata;

  assign hs     = s_req && s_gnt;
  assign m0_gnt = hs && !sel;
  assign m1_gnt = hs && sel;

  assign m0_rvalid = s_rvalid && !owner_q;
  assign m1_rvalid = s_rvalid && owner_q;
  assign m0_rdata  = s_rdata;
  assign m1_rdata  = s_rdata;

  always_ff @(posedge clk) begin
    if (rst) begin
      lock_q     <= 1'b0;
      lock_sel_q <= 1'b0;
      prio_q     <= 1'b1;  // the debug master wins the first tie
      owner_q    <= 1'b0;
    end else begin
      lock_q     <= s_req && !s_gnt;
      lock_sel_q <= sel;
      if (hs) begin
        prio_q  <= !sel;
        owner_q <= sel;
      end
    end
  end
endmodule
