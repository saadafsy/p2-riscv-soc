// Lint/synth-check stand-in for the sky130 clock-gate cell used by
// rtl/clk/clk_gate.sv under SKY130 (ports as in sky130_fd_sc_hd). Yosys reads
// it as a blackbox; Verilator sees the AND only.
// verilator lint_off DECLFILENAME
(* blackbox *)
module sky130_fd_sc_hd__dlclkp (input logic CLK, input logic GATE, output logic GCLK);
`ifndef SYNTHESIS
  assign GCLK = CLK & GATE;
`endif
endmodule
// verilator lint_on DECLFILENAME
