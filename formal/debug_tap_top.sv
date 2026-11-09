// Formal harness for jtag_tap. tck is a free input (multiclock, because TDO
// is a falling-edge flop); the TAP starts in an arbitrary state with no
// reset, so the reset property holds from every state:
//   five rising edges with TMS=1 (or one with TRST) leave the TAP in
//   Test-Logic-Reset with IDCODE in the IR,
// and the user DR strobes are exclusive and only active for USER_IR.
// Cover: every one of the 16 states is reachable after such a reset.
module debug_tap_top (
  input logic tck,
  input logic trst,
  input logic tms,
  input logic tdi,
  input logic user_tdo
);
  localparam logic [4:0] UserIr = 5'h18;

  logic       tdo, tdo_oe, user_sel, user_capture, user_shift, user_update, user_tdi;
  logic [3:0] state;
  logic [4:0] ir;

  jtag_tap #(.USER_IR(UserIr)) dut (
    .tck, .trst, .tms, .tdi, .tdo, .tdo_oe,
    .user_sel, .user_capture, .user_shift, .user_update, .user_tdi, .user_tdo,
    .state, .ir
  );

  // Rising edges since the TAP was last forced toward reset, saturating at 5.
  logic [2:0] ones = 3'd0;
  always @(posedge tck) begin
    if (trst)               ones <= 3'd5;
    else if (!tms)          ones <= 3'd0;
    else if (ones != 3'd5)  ones <= ones + 3'd1;
  end

  logic was_reset = 1'b0;
  always @(posedge tck) if (ones == 3'd5) was_reset <= 1'b1;

  // Induction strengthening: the states reachable after k edges with TMS=1
  // (T1 = image of all 16 states, T(k+1) = image of Tk), so ones == 4 cannot
  // start from an arbitrary state.
  logic in_t1, in_t2, in_t3, in_t4;
  assign in_t4 = state == 4'hF || state == 4'h4;
  assign in_t3 = in_t4 || state == 4'h7;
  assign in_t2 = in_t3 || state == 4'h5 || state == 4'hD;
  assign in_t1 = in_t2 || state == 4'h1 || state == 4'h0 || state == 4'h9 || state == 4'h8;

  always @* begin
    if (ones >= 3'd1) assert (in_t1);
    if (ones >= 3'd2) assert (in_t2);
    if (ones >= 3'd3) assert (in_t3);
    if (ones >= 3'd4) assert (in_t4);
    if (ones >= 3'd1 && state == 4'hF) assert (ir == 5'h01);
    if (ones == 3'd5) assert (state == 4'hF && ir == 5'h01);
    assert (user_capture + user_shift + user_update <= 2'd1);
    if (user_capture || user_shift || user_update) assert (user_sel && ir == UserIr);
  end

  generate
    for (genvar s = 0; s < 16; s++) begin : g_cov
      always @* cover (was_reset && state == 4'(s));
    end
  endgenerate
endmodule
