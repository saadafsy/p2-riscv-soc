// Two-flop synchronizer for asynchronous inputs (pins). Each bit is synchronized
// independently, so multi-bit inputs must be quasi-static or independent.
module sync2ff #(
  parameter int          WIDTH     = 1,
  parameter logic [WIDTH-1:0] RESET_VAL = '0
) (
  input  logic             clk,
  input  logic             rst,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] meta;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta <= RESET_VAL;
      sync <= RESET_VAL;
    end else begin
      meta <= d;
      sync <= meta;
    end
  end

  assign q = sync;
endmodule
