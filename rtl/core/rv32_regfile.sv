// 32 x 32 register file, x0 reads 0. Two async read ports with write-through
// so an ID read in the same cycle as the WB write sees the new value.
module rv32_regfile (
    input  logic        clk,
    input  logic        rst,
    input  logic [ 4:0] raddr1,
    output logic [31:0] rdata1,
    input  logic [ 4:0] raddr2,
    output logic [31:0] rdata2,
    input  logic        we,
    input  logic [ 4:0] waddr,
    input  logic [31:0] wdata
);

  logic [31:0] regs[32];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'h0;
    end else if (we && waddr != 5'd0) begin
      regs[waddr] <= wdata;
    end
  end

  assign rdata1 = (raddr1 == 5'd0) ? 32'h0 :
                  (we && waddr == raddr1) ? wdata : regs[raddr1];
  assign rdata2 = (raddr2 == 5'd0) ? 32'h0 :
                  (we && waddr == raddr2) ? wdata : regs[raddr2];

endmodule
