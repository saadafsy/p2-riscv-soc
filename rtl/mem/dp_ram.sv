// Dual-port RAM, 2^AW 32-bit words, written as the Xilinx true-dual-port
// block RAM template (READ_FIRST, byte-write enables on port B).
// Both ports are OBI slaves that grant immediately and respond next cycle.
// Port A (instruction fetch) is read-only. Addresses are byte addresses;
// bits [1:0] and bits above AW+1 are ignored (the decoder aliases the 64 KB).
module dp_ram #(
  parameter int AW        = 14,
  // Untyped: yosys does not accept "parameter string".
  // verilog_lint: waive explicit-parameter-storage-type
  parameter     INIT_FILE = ""
) (
  input  logic        clk,
  input  logic        rst,
  // port A: read-only
  input  logic        a_req,
  output logic        a_gnt,
  input  logic [31:0] a_addr,
  output logic        a_rvalid,
  output logic [31:0] a_rdata,
  // port B: read/write
  input  logic        b_req,
  output logic        b_gnt,
  input  logic [31:0] b_addr,
  input  logic        b_we,
  input  logic [3:0]  b_be,
  input  logic [31:0] b_wdata,
  output logic        b_rvalid,
  output logic [31:0] b_rdata
);
  logic [31:0] mem [2**AW];

  // The one initial block allowed in RTL (spec 6): BRAM initialization.
  generate
    if (INIT_FILE != "") begin : g_init
      initial $readmemh(INIT_FILE, mem);
    end
  endgenerate

  logic [AW-1:0] a_idx, b_idx;
  assign a_idx = a_addr[AW+1:2];
  assign b_idx = b_addr[AW+1:2];

  assign a_gnt = a_req;
  assign b_gnt = b_req;

  // Read registers use the BRAM output-latch synchronous reset.
  always_ff @(posedge clk) begin
    if (rst) a_rdata <= '0;
    else if (a_req) a_rdata <= mem[a_idx];
  end

  always_ff @(posedge clk) begin
    if (b_req) begin
      for (int i = 0; i < 4; i++) begin
        if (b_we && b_be[i]) mem[b_idx][8*i +: 8] <= b_wdata[8*i +: 8];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) b_rdata <= '0;
    else if (b_req) b_rdata <= mem[b_idx];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      a_rvalid <= 1'b0;
      b_rvalid <= 1'b0;
    end else begin
      a_rvalid <= a_req;
      b_rvalid <= b_req;
    end
  end

  logic unused;
  assign unused = ^{a_addr[31:AW+2], a_addr[1:0], b_addr[31:AW+2], b_addr[1:0]};
endmodule
