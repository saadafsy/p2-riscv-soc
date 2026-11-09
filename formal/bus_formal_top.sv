// Formal harness: obi_decoder with obi2apb on its APB port, RAM port left as
// a free slave. Free inputs are constrained only by protocol assumptions;
// every link the design drives is checked by assertions.
module bus_formal_top (
  input logic              clk,
  input logic              rst,
  // core data port (free master)
  input logic              m_req,
  input logic [31:0]       m_addr,
  input logic              m_we,
  input logic [3:0]        m_be,
  input logic [31:0]       m_wdata,
  // RAM port B (free slave)
  input logic              ram_gnt,
  input logic              ram_rvalid,
  input logic [31:0]       ram_rdata,
  // APB slaves (free)
  input logic [15:0][31:0] prdata,
  input logic [15:0]       pready
);
  logic        m_gnt, m_rvalid;
  logic [31:0] m_rdata;
  logic        ram_req, ram_we;
  logic [31:0] ram_addr, ram_wdata;
  logic [3:0]  ram_be;
  logic        br_req, br_gnt, br_we, br_rvalid;
  logic [31:0] br_addr, br_wdata, br_rdata;
  logic [3:0]  br_be;
  logic [15:0] psel;
  logic        penable, pwrite;
  logic [11:0] paddr;
  logic [31:0] pwdata;
  logic [3:0]  pstrb;
  logic [2:0]  pprot;

  obi_decoder u_dec (
    .clk, .rst,
    .m_req, .m_gnt, .m_addr, .m_we, .m_be, .m_wdata, .m_rvalid, .m_rdata,
    .ram_req, .ram_gnt, .ram_addr, .ram_we, .ram_be, .ram_wdata, .ram_rvalid, .ram_rdata,
    .apb_req(br_req), .apb_gnt(br_gnt), .apb_addr(br_addr), .apb_we(br_we),
    .apb_be(br_be), .apb_wdata(br_wdata), .apb_rvalid(br_rvalid), .apb_rdata(br_rdata)
  );

  obi2apb u_br (
    .clk, .rst,
    .req(br_req), .gnt(br_gnt), .addr(br_addr), .we(br_we), .be(br_be), .wdata(br_wdata),
    .rvalid(br_rvalid), .rdata(br_rdata),
    .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .prdata, .pready
  );

  // Core side: master rules assumed, decoder's slave behaviour asserted.
  obi_checker #(.ASSUME_M(1'b1)) chk_core (
    .clk, .rst, .req(m_req), .gnt(m_gnt), .addr(m_addr), .we(m_we), .be(m_be),
    .wdata(m_wdata), .rvalid(m_rvalid)
  );
  // RAM side: decoder's master behaviour asserted, RAM responses assumed.
  obi_checker #(.ASSUME_S(1'b1)) chk_ram (
    .clk, .rst, .req(ram_req), .gnt(ram_gnt), .addr(ram_addr), .we(ram_we), .be(ram_be),
    .wdata(ram_wdata), .rvalid(ram_rvalid)
  );
  // Decoder to bridge: both sides are design, everything asserted.
  obi_checker chk_br (
    .clk, .rst, .req(br_req), .gnt(br_gnt), .addr(br_addr), .we(br_we), .be(br_be),
    .wdata(br_wdata), .rvalid(br_rvalid)
  );
  apb_checker chk_apb (
    .clk, .rst, .psel, .penable, .pwrite, .paddr, .pwdata, .pstrb, .pprot, .pready
  );

  initial assume (rst);

  // A peripheral read with a wait state, reaching the core as rvalid.
  logic apb_waited, apb_done, def_owed;
  always @(posedge clk) begin
    if (rst) begin
      apb_waited <= 1'b0;
      apb_done   <= 1'b0;
      def_owed   <= 1'b0;
    end else begin
      if (penable && !(|(psel & pready))) apb_waited <= 1'b1;
      if (apb_waited && penable && |(psel & pready) && !pwrite) apb_done <= 1'b1;
      if (m_req && m_gnt) def_owed <= (m_addr[31:28] > 4'h1);
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      cov_apb_xfer: cover (penable && |(psel & pready));
      cov_apb_subword_write: cover (penable && pwrite && pstrb != 4'h0 && pstrb != 4'hF);
      cov_apb_read_waited_to_core: cover (apb_done && m_rvalid);
      cov_ram_back_to_back: cover (m_rvalid && m_req && m_gnt && m_addr[31:28] == 4'h0);
      cov_default_slave: cover (m_rvalid && def_owed);
    end
  end
endmodule
