// OBI slave to AXI4-Lite master bridge (spec 12). One transaction at a time:
// grant -> AW+W (each dropped on its own ready) -> B, or AR -> R -> rvalid.
// A new request is granted in the rvalid cycle. AxPROT = 0, WSTRB = be.
// A SLVERR / DECERR response still completes the OBI access (OBI has no
// error signal); a failed read returns 0.
module obi2axil (
  input  logic        clk,
  input  logic        rst,
  // OBI slave
  input  logic        req,
  output logic        gnt,
  input  logic [31:0] addr,
  input  logic        we,
  input  logic [3:0]  be,
  input  logic [31:0] wdata,
  output logic        rvalid,
  output logic [31:0] rdata,
  // AXI4-Lite master
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_awaddr,
  output logic [2:0]  m_awprot,
  output logic        m_wvalid,
  input  logic        m_wready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  input  logic        m_bvalid,
  output logic        m_bready,
  input  logic [1:0]  m_bresp,
  output logic        m_arvalid,
  input  logic        m_arready,
  output logic [31:0] m_araddr,
  output logic [2:0]  m_arprot,
  input  logic        m_rvalid,
  output logic        m_rready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp
);
  localparam logic [1:0] SIdle = 2'd0, SWrite = 2'd1, SRead = 2'd2, SResp = 2'd3;

  logic [1:0]  state;
  logic        aw_pend, w_pend, ar_pend;
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic [3:0]  be_q;
  logic        hs;

  assign gnt = req && (state == SIdle || state == SResp);
  assign hs  = req && gnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      state   <= SIdle;
      aw_pend <= 1'b0;
      w_pend  <= 1'b0;
      ar_pend <= 1'b0;
      addr_q  <= '0;
      wdata_q <= '0;
      be_q    <= '0;
      rdata_q <= '0;
    end else begin
      unique case (state)
        SWrite: begin
          if (m_awready) aw_pend <= 1'b0;
          if (m_wready) w_pend <= 1'b0;
          if (m_bvalid) begin
            state   <= SResp;
            rdata_q <= '0;
          end
        end
        SRead: begin
          if (m_arready) ar_pend <= 1'b0;
          if (m_rvalid) begin
            state   <= SResp;
            rdata_q <= (m_rresp[1] == 1'b0) ? m_rdata : 32'd0;
          end
        end
        default: state <= SIdle;  // IDLE, RESP
      endcase
      if (hs) begin
        addr_q  <= addr;
        wdata_q <= wdata;
        be_q    <= be;
        state   <= we ? SWrite : SRead;
        aw_pend <= we;
        w_pend  <= we;
        ar_pend <= !we;
      end
    end
  end

  assign m_awvalid = aw_pend;
  assign m_awaddr  = addr_q;
  assign m_awprot  = 3'b000;
  assign m_wvalid  = w_pend;
  assign m_wdata   = wdata_q;
  assign m_wstrb   = be_q;
  assign m_bready  = (state == SWrite);
  assign m_arvalid = ar_pend;
  assign m_araddr  = addr_q;
  assign m_arprot  = 3'b000;
  assign m_rready  = (state == SRead);

  assign rvalid = (state == SResp);
  assign rdata  = rdata_q;

  logic unused;
  assign unused = ^{m_bresp, m_rresp[0]};
endmodule
