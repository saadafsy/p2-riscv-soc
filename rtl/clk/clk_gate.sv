// Integrated clock gate (spec 13.4): gclk follows clk while en is high and
// stays low while it is low. en is captured while clk is low, so gclk never
// glitches; en must meet setup to the rising edge of clk.
//   SKY130       sky130_fd_sc_hd__dlclkp (latch + AND standard cell)
//   FPGA_XC7     BUFGCE (glitch-free enable of a global clock buffer)
//   otherwise    behavioral model: an explicit low-transparent latch and an
//                AND. This is the one deliberate latch in the RTL; synthesis
//                of the generic model is for checking only, a real flow must
//                use one of the two cells above.
module clk_gate (
  input  logic clk,
  input  logic en,
  output logic gclk
);
`ifdef SKY130
  sky130_fd_sc_hd__dlclkp u_icg (.CLK(clk), .GATE(en), .GCLK(gclk));
`elsif FPGA_XC7
  BUFGCE u_bufgce (.I(clk), .CE(en), .O(gclk));
`else
  logic en_l;
  always_latch begin
    if (!clk) en_l = en;
  end
  assign gclk = clk & en_l;
`endif
endmodule
