// Machine timer APB4 slave. Register map (spec 8):
//   0x0 MTIME_LO, 0x4 MTIME_HI        64-bit counter, +1 every clock, writable.
//   0x8 MTIMECMP_LO, 0xC MTIMECMP_HI  reset all-ones so irq_timer stays low.
// Writes change only the pstrb-enabled bytes (spec 5). A write to one half of
// mtime replaces those bytes and skips that cycle's increment, so no carry
// crosses into the half being written.
module timer_apb (
  input  logic        pclk,
  input  logic        presetn,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic [2:0]  pprot,   // unused (lint waiver: folded into `unused`)
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  output logic        irq_timer
);
  logic rst;
  assign rst = !presetn;

  localparam logic [3:0] AddrTimeLo = 4'h0, AddrTimeHi = 4'h4, AddrCmpLo = 4'h8, AddrCmpHi = 4'hC;

  logic       acc_wr;
  logic [3:0] reg_a;
  // pstrb 0 writes nothing, so it must not skip the mtime increment either.
  assign acc_wr = psel && penable && pwrite && (pstrb != 4'b0000);
  // Word decode: paddr[1:0] ignored (sub-word stores hit the register, spec 5);
  // offsets above 0xC map to no register (0xF), reading 0 and ignoring writes.
  assign reg_a  = (paddr[11:4] == 8'd0) ? {paddr[3:2], 2'b00} : 4'hF;

  logic [31:0] m, wd;
  assign m  = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};
  assign wd = pwdata & m;

  logic [63:0] mtime, mtimecmp;

  always_ff @(posedge pclk) begin
    if (rst) begin
      mtime    <= '0;
      mtimecmp <= '1;
    end else begin
      if (acc_wr && reg_a == AddrTimeLo) begin
        mtime[31:0]  <= (mtime[31:0] & ~m) | wd;
      end else if (acc_wr && reg_a == AddrTimeHi) begin
        mtime[63:32] <= (mtime[63:32] & ~m) | wd;
      end else begin
        mtime <= mtime + 64'd1;
      end
      if (acc_wr && reg_a == AddrCmpLo) mtimecmp[31:0]  <= (mtimecmp[31:0] & ~m) | wd;
      if (acc_wr && reg_a == AddrCmpHi) mtimecmp[63:32] <= (mtimecmp[63:32] & ~m) | wd;
    end
  end

  always_comb begin
    unique case (reg_a)
      AddrTimeLo: prdata = mtime[31:0];
      AddrTimeHi: prdata = mtime[63:32];
      AddrCmpLo:  prdata = mtimecmp[31:0];
      AddrCmpHi:  prdata = mtimecmp[63:32];
      default:    prdata = 32'd0;
    endcase
  end

  assign irq_timer = (mtime >= mtimecmp);
  assign pready    = 1'b1;
  assign pslverr   = 1'b0;

  logic unused;
  assign unused = ^{paddr[1:0], pprot};
endmodule
