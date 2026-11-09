// Synchronous first-word-fall-through FIFO. DEPTH must be a power of two.
// Push when full and pop when empty are ignored, so callers can use the
// full/empty flags to detect drops (UART overrun).
module sync_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 16
) (
  input  logic             clk,
  input  logic             rst,
  input  logic             push,
  input  logic [WIDTH-1:0] wdata,
  input  logic             pop,
  output logic [WIDTH-1:0] rdata,
  output logic             full,
  output logic             empty,
  output logic [$clog2(DEPTH):0] count
);
  localparam int PW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PW:0]      wptr, rptr;  // extra MSB distinguishes full from empty

  logic do_push, do_pop;
  assign do_push = push && !full;
  assign do_pop  = pop && !empty;

  always_ff @(posedge clk) begin
    if (rst) begin
      wptr <= '0;
      rptr <= '0;
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else begin
      if (do_push) begin
        mem[wptr[PW-1:0]] <= wdata;
        wptr <= wptr + 1'b1;
      end
      if (do_pop) rptr <= rptr + 1'b1;
    end
  end

  assign count = wptr - rptr;
  assign empty = (wptr == rptr);
  assign full  = (wptr[PW-1:0] == rptr[PW-1:0]) && (wptr[PW] != rptr[PW]);
  assign rdata = mem[rptr[PW-1:0]];
endmodule
