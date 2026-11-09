// System control APB4 slave at APB slot 3 (spec 13.2): core hold, the
// accelerator clock gate enable, and the MBIST control and status.
//   0x00 CTRL        [0] CORE_HOLD (RW, reset 0), [1] ACCEL_CLK_EN (RW, reset 1)
//   0x04 STATUS      [0] CORE_HELD, [1] ACCEL_CLK_ON (RO)
//   0x08 BIST_CTRL   [0] START (write 1; taken only while CORE_HELD and not busy)
//   0x0C BIST_STATUS [0] BUSY, [1] DONE, [2] FAIL, [6:4] FAIL_ELEM, [10:8] FAIL_BG (RO)
//   0x10 BIST_FAIL_ADDR, 0x14 BIST_FAIL_SYN (RO), 0x1C ID = "SYSC"
// The core is put into reset (core_hold) only in a cycle where it is not
// waiting for a data-port grant (core_quiet), so its OBI request is never
// withdrawn before the grant. A granted access still in flight completes on
// the bus; its response reaches the core while it is held in reset and is
// dropped. MBIST busy also holds the core, so the RAM under test is never
// fetched from.
module sysctl_apb (
  input  logic        pclk,
  input  logic        presetn,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic [2:0]  pprot,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  // core hold
  input  logic        core_quiet,
  output logic        core_hold,
  // accelerator clock gate
  output logic        accel_clk_en,
  input  logic        accel_clk_on,  // enable as used in the accel domain (async)
  // MBIST
  output logic        bist_start,
  input  logic        bist_busy,
  input  logic        bist_done,
  input  logic        bist_fail,
  input  logic [31:0] bist_fail_addr,
  input  logic [2:0]  bist_fail_elem,
  input  logic [2:0]  bist_fail_bg,
  input  logic [31:0] bist_fail_syn
);
  logic rst;
  assign rst = !presetn;

  localparam logic [2:0] RCtrl = 3'd0, RStatus = 3'd1, RBistCtrl = 3'd2, RBistStatus = 3'd3,
                         RFailAddr = 3'd4, RFailSyn = 3'd5, RId = 3'd7;
  localparam logic [31:0] IdValue = 32'h5359_5343;  // "SYSC"

  logic       acc_wr, mapped;
  logic [2:0] r;
  assign acc_wr = psel && penable && pwrite;
  assign mapped = (paddr[11:5] == 7'd0);
  assign r      = paddr[4:2];

  logic hold_q, clk_en_q, held_q;
  logic clk_on_s;

  sync2ff #(.WIDTH(1), .RESET_VAL(1'b1)) u_clk_on_sync (
    .clk(pclk), .rst, .d(accel_clk_on), .q(clk_on_s)
  );

  always_ff @(posedge pclk) begin
    if (rst) begin
      hold_q   <= 1'b0;
      clk_en_q <= 1'b1;
      held_q   <= 1'b0;
    end else begin
      if (acc_wr && mapped && r == RCtrl && pstrb[0]) begin
        hold_q   <= pwdata[0];
        clk_en_q <= pwdata[1];
      end
      if (!(hold_q || bist_busy)) held_q <= 1'b0;
      else if (core_quiet)        held_q <= 1'b1;
    end
  end

  assign core_hold    = held_q;
  assign accel_clk_en = clk_en_q;
  assign bist_start   = acc_wr && mapped && r == RBistCtrl && pstrb[0] && pwdata[0] &&
                        held_q && !bist_busy;

  always_comb begin
    prdata = 32'd0;
    if (mapped) begin
      unique case (r)
        RCtrl:       prdata = {30'd0, clk_en_q, hold_q};
        RStatus:     prdata = {30'd0, clk_on_s, held_q};
        RBistStatus: prdata = {21'd0, bist_fail_bg, 1'b0, bist_fail_elem, 1'b0,
                               bist_fail, bist_done, bist_busy};
        RFailAddr:   prdata = bist_fail_addr;
        RFailSyn:    prdata = bist_fail_syn;
        RId:         prdata = IdValue;
        default:     prdata = 32'd0;  // BIST_CTRL reads 0, 0x18 reserved
      endcase
    end
  end

  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  logic unused;
  assign unused = ^{paddr[1:0], pwdata[31:2], pstrb[3:1], pprot};
endmodule
