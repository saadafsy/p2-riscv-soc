// Data-port OBI decoder (spec 5, 7, 12): addr[31:28] 0 = RAM port B, 1 = APB
// bridge, 2 = AXI4-Lite bridge when AXI_EN (else the default slave), anything
// else = internal default slave (reads 0, writes dropped).
// One transaction outstanding; the response is routed by the target
// registered at the handshake. A new request may be forwarded in the cycle
// the previous response returns, so RAM accesses run back to back.
module obi_decoder #(
  parameter bit AXI_EN = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  // OBI slave port (core data port)
  input  logic        m_req,
  output logic        m_gnt,
  input  logic [31:0] m_addr,
  input  logic        m_we,
  input  logic [3:0]  m_be,
  input  logic [31:0] m_wdata,
  output logic        m_rvalid,
  output logic [31:0] m_rdata,
  // OBI master port to RAM port B
  output logic        ram_req,
  input  logic        ram_gnt,
  output logic [31:0] ram_addr,
  output logic        ram_we,
  output logic [3:0]  ram_be,
  output logic [31:0] ram_wdata,
  input  logic        ram_rvalid,
  input  logic [31:0] ram_rdata,
  // OBI master port to the APB bridge
  output logic        apb_req,
  input  logic        apb_gnt,
  output logic [31:0] apb_addr,
  output logic        apb_we,
  output logic [3:0]  apb_be,
  output logic [31:0] apb_wdata,
  input  logic        apb_rvalid,
  input  logic [31:0] apb_rdata,
  // OBI master port to the AXI4-Lite bridge (unused when !AXI_EN)
  output logic        axi_req,
  input  logic        axi_gnt,
  output logic [31:0] axi_addr,
  output logic        axi_we,
  output logic [3:0]  axi_be,
  output logic [31:0] axi_wdata,
  input  logic        axi_rvalid,
  input  logic [31:0] axi_rdata
);
  localparam logic [1:0] TgtRam = 2'd0, TgtApb = 2'd1, TgtDef = 2'd2, TgtAxi = 2'd3;

  logic [1:0] tgt, sel_q;
  logic       pend_q;
  logic       resp, can_issue, hs;
  logic       def_req, def_gnt, def_rvalid;
  logic [31:0] def_rdata;

  always_comb begin
    unique case (m_addr[31:28])
      4'h0:    tgt = TgtRam;
      4'h1:    tgt = TgtApb;
      4'h2:    tgt = AXI_EN ? TgtAxi : TgtDef;
      default: tgt = TgtDef;
    endcase
  end

  // Responses from a slave that is not the one owed are ignored.
  always_comb begin
    unique case (sel_q)
      TgtRam:  begin resp = pend_q && ram_rvalid; m_rdata = ram_rdata; end
      TgtApb:  begin resp = pend_q && apb_rvalid; m_rdata = apb_rdata; end
      TgtAxi:  begin resp = pend_q && axi_rvalid; m_rdata = axi_rdata; end
      default: begin resp = pend_q && def_rvalid; m_rdata = def_rdata; end
    endcase
  end

  assign can_issue = !pend_q || resp;

  assign ram_req = m_req && can_issue && (tgt == TgtRam);
  assign apb_req = m_req && can_issue && (tgt == TgtApb);
  assign axi_req = m_req && can_issue && (tgt == TgtAxi);
  assign def_req = m_req && can_issue && (tgt == TgtDef);

  always_comb begin
    unique case (tgt)
      TgtRam:  m_gnt = ram_req && ram_gnt;
      TgtApb:  m_gnt = apb_req && apb_gnt;
      TgtAxi:  m_gnt = axi_req && axi_gnt;
      default: m_gnt = def_req && def_gnt;
    endcase
  end

  assign hs       = m_req && m_gnt;
  assign m_rvalid = resp;

  always_ff @(posedge clk) begin
    if (rst) begin
      pend_q <= 1'b0;
      sel_q  <= TgtRam;
    end else begin
      if (hs) begin
        pend_q <= 1'b1;
        sel_q  <= tgt;
      end else if (resp) begin
        pend_q <= 1'b0;
      end
    end
  end

  assign ram_addr  = m_addr;
  assign ram_we    = m_we;
  assign ram_be    = m_be;
  assign ram_wdata = m_wdata;
  assign apb_addr  = m_addr;
  assign apb_we    = m_we;
  assign apb_be    = m_be;
  assign apb_wdata = m_wdata;
  assign axi_addr  = m_addr;
  assign axi_we    = m_we;
  assign axi_be    = m_be;
  assign axi_wdata = m_wdata;

  obi_default_slave u_def (
    .clk, .rst, .req(def_req), .gnt(def_gnt), .rvalid(def_rvalid), .rdata(def_rdata)
  );
endmodule
