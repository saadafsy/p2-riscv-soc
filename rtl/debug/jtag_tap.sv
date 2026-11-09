// IEEE 1149.1 TAP controller: 16-state FSM, 5-bit IR, IDCODE, BYPASS and one
// user data register exported on a BSCANE2-style interface (user_*), so the
// same user logic works behind this TAP or behind the Xilinx primitive.
//
// Instructions (IR = 5 bits, Capture-IR loads 5'b00001 as the standard
// requires the two LSBs to be 01):
//   5'h01 IDCODE  32-bit ID (IR value after Test-Logic-Reset)
//   USER_IR       user DR (default 5'h18, the debug transport)
//   5'h1F BYPASS  and every other code: 1-bit bypass register
// No boundary scan: EXTEST / SAMPLE / PRELOAD select BYPASS.
//
// Clocking and reset: everything is on tck. trst is a synchronous
// active-high reset in the tck domain (tie it to 0 if the board has no TRST
// pin; five tck cycles with TMS=1 reach Test-Logic-Reset from any state).
// TDO is launched on the falling edge of tck, as the standard requires, so
// the host samples it on the rising edge.
//
// User DR protocol (levels, sampled by user logic on posedge tck):
//   user_sel      IR == USER_IR
//   user_capture  user_sel and state Capture-DR: load the DR
//   user_shift    user_sel and state Shift-DR: shift right, user_tdi -> MSB
//   user_update   user_sel and state Update-DR: act on the DR
//   user_tdo      LSB of the user DR (input)
module jtag_tap #(
  // JEDEC-style IDCODE: version 1, part 0x0502, manufacturer field 0x000.
  // Manufacturer 0 is not a valid JEP106 code (bad parity), so this can
  // never alias a real vendor; replace it before any product use.
  parameter logic [31:0] IDCODE  = 32'h1050_2001,
  parameter logic [4:0]  USER_IR = 5'h18
) (
  input  logic       tck,
  input  logic       trst,
  input  logic       tms,
  input  logic       tdi,
  output logic       tdo,
  output logic       tdo_oe,  // high while shifting; drives a tri-state TDO pin

  output logic       user_sel,
  output logic       user_capture,
  output logic       user_shift,
  output logic       user_update,
  output logic       user_tdi,
  input  logic       user_tdo,

  output logic [3:0] state,  // for test and status only
  output logic [4:0] ir
);
  // Encoding from the 1149.1 annex (as used by many TAPs), so waveforms read
  // the same as vendor documentation.
  localparam logic [3:0] TLR   = 4'hF;
  localparam logic [3:0] RTI   = 4'hC;
  localparam logic [3:0] SELDR = 4'h7;
  localparam logic [3:0] CAPDR = 4'h6;
  localparam logic [3:0] SHDR  = 4'h2;
  localparam logic [3:0] EX1DR = 4'h1;
  localparam logic [3:0] PADR  = 4'h3;
  localparam logic [3:0] EX2DR = 4'h0;
  localparam logic [3:0] UPDR  = 4'h5;
  localparam logic [3:0] SELIR = 4'h4;
  localparam logic [3:0] CAPIR = 4'hE;
  localparam logic [3:0] SHIR  = 4'hA;
  localparam logic [3:0] EX1IR = 4'h9;
  localparam logic [3:0] PAIR  = 4'hB;
  localparam logic [3:0] EX2IR = 4'h8;
  localparam logic [3:0] UPIR  = 4'hD;

  localparam logic [4:0] IrIdcode = 5'h01;

  logic [3:0] nxt;
  always_comb begin
    unique case (state)
      TLR:     nxt = tms ? TLR   : RTI;
      RTI:     nxt = tms ? SELDR : RTI;
      SELDR:   nxt = tms ? SELIR : CAPDR;
      CAPDR:   nxt = tms ? EX1DR : SHDR;
      SHDR:    nxt = tms ? EX1DR : SHDR;
      EX1DR:   nxt = tms ? UPDR  : PADR;
      PADR:    nxt = tms ? EX2DR : PADR;
      EX2DR:   nxt = tms ? UPDR  : SHDR;
      UPDR:    nxt = tms ? SELDR : RTI;
      SELIR:   nxt = tms ? TLR   : CAPIR;
      CAPIR:   nxt = tms ? EX1IR : SHIR;
      SHIR:    nxt = tms ? EX1IR : SHIR;
      EX1IR:   nxt = tms ? UPIR  : PAIR;
      PAIR:    nxt = tms ? EX2IR : PAIR;
      EX2IR:   nxt = tms ? UPIR  : SHIR;
      UPIR:    nxt = tms ? SELDR : RTI;
      default: nxt = TLR;  // unreachable: all 16 codes are states
    endcase
  end

  always_ff @(posedge tck) begin
    if (trst) state <= TLR;
    else      state <= nxt;
  end

  // ---- instruction register
  logic [4:0] ir_sr;
  always_ff @(posedge tck) begin
    if (trst) begin
      ir_sr <= 5'b00001;
      ir    <= IrIdcode;
    end else begin
      unique case (state)
        CAPIR:   ir_sr <= 5'b00001;
        SHIR:    ir_sr <= {tdi, ir_sr[4:1]};
        default: ;
      endcase
      // The IR must already read IDCODE in Test-Logic-Reset, so load it on entry.
      if (nxt == TLR)         ir <= IrIdcode;
      else if (state == UPIR) ir <= ir_sr;
    end
  end

  // ---- IDCODE and BYPASS data registers
  logic [31:0] id_sr;
  logic        byp;
  logic        sel_id;
  assign sel_id   = (ir == IrIdcode);
  assign user_sel = (ir == USER_IR);

  always_ff @(posedge tck) begin
    if (trst) begin
      id_sr <= IDCODE;
      byp   <= 1'b0;
    end else begin
      if (sel_id && state == CAPDR)     id_sr <= IDCODE;
      else if (sel_id && state == SHDR) id_sr <= {tdi, id_sr[31:1]};
      // BYPASS captures 0 (1149.1 8.1.1).
      if (state == CAPDR)     byp <= 1'b0;
      else if (state == SHDR) byp <= tdi;
    end
  end

  assign user_capture = user_sel && (state == CAPDR);
  assign user_shift   = user_sel && (state == SHDR);
  assign user_update  = user_sel && (state == UPDR);
  assign user_tdi     = tdi;

  logic dr_out;
  always_comb begin
    if (sel_id)        dr_out = id_sr[0];
    else if (user_sel) dr_out = user_tdo;
    else               dr_out = byp;
  end

  // TDO launches on the falling edge; the reset term is sampled on negedge,
  // which is safe because trst only changes after a rising edge.
  always_ff @(negedge tck) begin
    if (trst) begin
      tdo    <= 1'b0;
      tdo_oe <= 1'b0;
    end else begin
      tdo    <= (state == SHIR) ? ir_sr[0] : dr_out;
      tdo_oe <= (state == SHIR) || (state == SHDR);
    end
  end
endmodule
