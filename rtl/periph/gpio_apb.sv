// GPIO APB4 slave. Register map (spec 8):
//   0x0 OUT      16 LED outputs (R/W).
//   0x4 IN       bits 15:0 switches, 20:16 buttons, through 2-flop synchronizers (RO).
//   0x8 OUT_SET  W: OUT |= wdata.   R: OUT.
//   0xC OUT_CLR  W: OUT &= ~wdata.  R: OUT.
// Writes act on the pstrb-enabled byte lanes only (spec 5).
module gpio_apb (
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
  input  logic [20:0] gpio_in,
  output logic [15:0] gpio_out
);
  logic rst;
  assign rst = !presetn;

  localparam logic [3:0] AddrOut = 4'h0, AddrIn = 4'h4, AddrSet = 4'h8, AddrClr = 4'hC;

  logic       acc_wr;
  logic [3:0] reg_a;
  assign acc_wr = psel && penable && pwrite;
  // Word decode: paddr[1:0] ignored (sub-word stores hit the register, spec 5);
  // offsets above 0xC map to no register (0xF), reading 0 and ignoring writes.
  assign reg_a  = (paddr[11:4] == 8'd0) ? {paddr[3:2], 2'b00} : 4'hF;

  logic [15:0] m, wd;  // enabled lanes of the 16-bit register, and the data on them
  assign m  = {{8{pstrb[1]}}, {8{pstrb[0]}}};
  assign wd = pwdata[15:0] & m;

  logic [20:0] in_s;
  sync2ff #(.WIDTH(21)) u_in_sync (.clk(pclk), .rst, .d(gpio_in), .q(in_s));

  always_ff @(posedge pclk) begin
    if (rst) begin
      gpio_out <= '0;
    end else if (acc_wr) begin
      unique case (reg_a)
        AddrOut: gpio_out <= (gpio_out & ~m) | wd;
        AddrSet: gpio_out <= gpio_out | wd;
        AddrClr: gpio_out <= gpio_out & ~wd;
        default: ;
      endcase
    end
  end

  always_comb begin
    unique case (reg_a)
      AddrOut, AddrSet, AddrClr: prdata = {16'd0, gpio_out};
      AddrIn:                    prdata = {11'd0, in_s};
      default:                   prdata = 32'd0;
    endcase
  end

  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  logic unused;
  assign unused = ^{paddr[1:0], pwdata[31:16], pstrb[3:2], pprot};
endmodule
