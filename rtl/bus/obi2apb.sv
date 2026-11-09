// OBI slave to APB4 master bridge (spec 7). One transaction at a time:
// grant -> SETUP -> ACCESS (until pready) -> rvalid. A new request is granted
// in the rvalid cycle, so back-to-back accesses cost 3 cycles each.
// psel is one-hot by addr[15:12]; addr[27:16] are ignored (aliases).
// Slots not set in SLV_MASK have no slave: they never assert psel and
// complete immediately with rdata 0, so an unpopulated slot cannot hang the bus.
// pstrb = OBI be on writes, 0 on reads; pwdata lanes outside be are zeroed.
// pprot is always 0 (normal, secure, data). pslverr is ignored.
module obi2apb #(
  parameter logic [15:0] SLV_MASK = 16'h8007  // UART 0, GPIO 1, TIMER 2, SIMCTRL F
) (
  input  logic              clk,
  input  logic              rst,
  // OBI slave
  input  logic              req,
  output logic              gnt,
  input  logic [31:0]       addr,
  input  logic              we,
  input  logic [3:0]        be,
  input  logic [31:0]       wdata,
  output logic              rvalid,
  output logic [31:0]       rdata,
  // APB4 master
  output logic [15:0]       psel,
  output logic              penable,
  output logic              pwrite,
  output logic [11:0]       paddr,
  output logic [31:0]       pwdata,
  output logic [3:0]        pstrb,
  output logic [2:0]        pprot,
  input  logic [15:0][31:0] prdata,
  input  logic [15:0]       pready
);
  localparam logic [1:0] SIdle = 2'd0, SSetup = 2'd1, SAccess = 2'd2, SResp = 2'd3;

  logic [1:0]  state;
  logic [3:0]  slot;
  logic [31:0] rdata_q;

  logic [31:0] prdata_sel;
  logic        pready_sel;
  logic        hs;
  logic [31:0] wmask;

  assign gnt = req && (state == SIdle || state == SResp);
  assign hs  = req && gnt;
  assign wmask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};

  always_ff @(posedge clk) begin
    if (rst) begin
      state   <= SIdle;
      slot    <= '0;
      paddr   <= '0;
      pwrite  <= 1'b0;
      pwdata  <= '0;
      pstrb   <= '0;
      rdata_q <= '0;
    end else begin
      unique case (state)
        SSetup:  state <= SAccess;
        SAccess: begin
          if (pready_sel) begin
            state   <= SResp;
            rdata_q <= pwrite ? 32'd0 : prdata_sel;
          end
        end
        default: state <= SIdle;  // IDLE, RESP
      endcase
      if (hs) begin
        slot   <= addr[15:12];
        paddr  <= addr[11:0];
        pwrite <= we;
        pwdata <= wdata & wmask;
        pstrb  <= we ? be : 4'b0000;
        if (SLV_MASK[addr[15:12]]) begin
          state <= SSetup;
        end else begin
          state   <= SResp;
          rdata_q <= '0;
        end
      end
    end
  end

  always_comb begin
    psel = '0;
    if (state == SSetup || state == SAccess) psel[slot] = 1'b1;
  end
  assign penable = (state == SAccess);
  assign pprot   = 3'b000;

  apb_mux #(.NSLV(16)) u_mux (
    .psel, .prdata, .pready, .prdata_sel, .pready_sel
  );

  assign rvalid = (state == SResp);
  assign rdata  = rdata_q;

  logic unused;
  assign unused = ^addr[31:16];
endmodule
