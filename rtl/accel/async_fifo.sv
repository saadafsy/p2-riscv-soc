// Dual-clock FIFO, 2**AW entries (spec 12). Binary pointers with a wrap bit
// are published in gray code and cross through 2-flop synchronizers, so the
// other side sees a pointer that is stale but never torn: full and empty are
// conservative, never wrong. Each side has its own synchronous reset; both
// must be asserted together (each for at least one edge of its clock).
// rdata is the head entry, valid while !rempty.
module async_fifo #(
  parameter int W  = 8,
  parameter int AW = 2   // >= 2
) (
  input  logic         wclk,
  input  logic         wrst,
  input  logic         winc,
  input  logic [W-1:0] wdata,
  output logic         wfull,
  input  logic         rclk,
  input  logic         rrst,
  input  logic         rinc,
  output logic [W-1:0] rdata,
  output logic         rempty
);
  localparam int Depth = 1 << AW;

  logic [W-1:0] mem[Depth];
  logic [AW:0]  wbin, wgray, rbin, rgray;
  logic [AW:0]  wbin_n, wgray_n, rbin_n, rgray_n;
  logic [AW:0]  rgray_w, wgray_r;  // the other side's pointer, synchronized

  sync2ff #(.WIDTH(AW + 1)) u_r2w (.clk(wclk), .rst(wrst), .d(rgray), .q(rgray_w));
  sync2ff #(.WIDTH(AW + 1)) u_w2r (.clk(rclk), .rst(rrst), .d(wgray), .q(wgray_r));

  // Write side. Full: write pointer one lap ahead of the read pointer, which
  // in gray code is the top two bits inverted and the rest equal.
  assign wbin_n  = wbin + {{AW{1'b0}}, winc && !wfull};
  assign wgray_n = (wbin_n >> 1) ^ wbin_n;

  always_ff @(posedge wclk) begin
    if (wrst) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
      for (int i = 0; i < Depth; i++) mem[i] <= '0;
    end else begin
      if (winc && !wfull) mem[wbin[AW-1:0]] <= wdata;
      wbin  <= wbin_n;
      wgray <= wgray_n;
      wfull <= (wgray_n == {~rgray_w[AW:AW-1], rgray_w[AW-2:0]});
    end
  end

  // Read side.
  assign rbin_n  = rbin + {{AW{1'b0}}, rinc && !rempty};
  assign rgray_n = (rbin_n >> 1) ^ rbin_n;

  always_ff @(posedge rclk) begin
    if (rrst) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_n;
      rgray  <= rgray_n;
      rempty <= (rgray_n == wgray_r);
    end
  end

  assign rdata = mem[rbin[AW-1:0]];
endmodule
