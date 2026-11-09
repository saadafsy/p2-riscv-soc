// RV32I integer ALU; op = {funct7[5] for SUB/SRA, funct3}.
module rv32_alu (
    input  logic [ 3:0] op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);

  always_comb begin
    unique case (op[2:0])
      3'b000:  y = op[3] ? a - b : a + b;
      3'b001:  y = a << b[4:0];
      3'b010:  y = {31'b0, $signed(a) < $signed(b)};
      3'b011:  y = {31'b0, a < b};
      3'b100:  y = a ^ b;
      3'b101:  y = op[3] ? 32'($signed(a) >>> b[4:0]) : a >> b[4:0];
      3'b110:  y = a | b;
      default: y = a & b;
    endcase
  end

endmodule
