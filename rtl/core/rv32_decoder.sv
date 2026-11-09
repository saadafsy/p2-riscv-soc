// RV32IM + Zicsr + MRET/WFI decoder. Register addresses of unused operands
// are forced to 0 so hazard checks and the RVFI trace need no extra gating.
module rv32_decoder (
    input  logic [31:0] insn,
    output logic [ 4:0] rs1,
    output logic [ 4:0] rs2,
    output logic [ 4:0] rd,
    output logic        rd_we,
    output logic [31:0] imm,
    output logic [ 3:0] alu_op,     // {sub/sra, funct3}
    output logic        a_pc,       // ALU operand A = pc
    output logic        a_zero,     // ALU operand A = 0
    output logic        b_imm,      // ALU operand B = imm
    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr,
    output logic        is_load,
    output logic        is_store,
    output logic        is_csr,
    output logic        is_mret,
    output logic        is_md,      // M extension, funct3 selects the operation
    output logic        illegal,
    output logic        is_ecall,
    output logic        is_ebreak
);

  localparam logic [6:0] OpLui    = 7'b0110111;
  localparam logic [6:0] OpAuipc  = 7'b0010111;
  localparam logic [6:0] OpJal    = 7'b1101111;
  localparam logic [6:0] OpJalr   = 7'b1100111;
  localparam logic [6:0] OpBranch = 7'b1100011;
  localparam logic [6:0] OpLoad   = 7'b0000011;
  localparam logic [6:0] OpStore  = 7'b0100011;
  localparam logic [6:0] OpImm    = 7'b0010011;
  localparam logic [6:0] OpOp     = 7'b0110011;
  localparam logic [6:0] OpFence  = 7'b0001111;
  localparam logic [6:0] OpSystem = 7'b1110011;

  logic [6:0] opcode, funct7;
  logic [2:0] funct3;
  logic use1, use2, wr;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode = insn[6:0];
  assign funct3 = insn[14:12];
  assign funct7 = insn[31:25];

  assign imm_i  = {{20{insn[31]}}, insn[31:20]};
  assign imm_s  = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_b  = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  assign imm_u  = {insn[31:12], 12'h000};
  assign imm_j  = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  always_comb begin
    use1      = 1'b0;
    use2      = 1'b0;
    wr        = 1'b0;
    imm       = imm_i;
    alu_op    = 4'b0000;
    a_pc      = 1'b0;
    a_zero    = 1'b0;
    b_imm     = 1'b0;
    is_branch = 1'b0;
    is_jal    = 1'b0;
    is_jalr   = 1'b0;
    is_load   = 1'b0;
    is_store  = 1'b0;
    is_csr    = 1'b0;
    is_mret   = 1'b0;
    is_md     = 1'b0;
    is_ecall  = 1'b0;
    is_ebreak = 1'b0;
    illegal   = 1'b0;

    unique case (opcode)
      OpLui: begin
        wr     = 1'b1;
        imm    = imm_u;
        a_zero = 1'b1;
        b_imm  = 1'b1;
      end
      OpAuipc: begin
        wr    = 1'b1;
        imm   = imm_u;
        a_pc  = 1'b1;
        b_imm = 1'b1;
      end
      OpJal: begin
        wr     = 1'b1;
        imm    = imm_j;
        is_jal = 1'b1;
      end
      OpJalr: begin
        illegal = funct3 != 3'b000;
        use1    = 1'b1;
        wr      = 1'b1;
        is_jalr = 1'b1;
      end
      OpBranch: begin
        illegal   = funct3[2:1] == 2'b01;
        use1      = 1'b1;
        use2      = 1'b1;
        imm       = imm_b;
        is_branch = 1'b1;
      end
      OpLoad: begin
        illegal = funct3 == 3'b011 || funct3[2:1] == 2'b11;
        use1    = 1'b1;
        wr      = 1'b1;
        b_imm   = 1'b1;
        is_load = 1'b1;
      end
      OpStore: begin
        illegal  = funct3[2] || funct3[1:0] == 2'b11;
        use1     = 1'b1;
        use2     = 1'b1;
        imm      = imm_s;
        b_imm    = 1'b1;
        is_store = 1'b1;
      end
      OpImm: begin
        use1  = 1'b1;
        wr    = 1'b1;
        b_imm = 1'b1;
        if (funct3 == 3'b001) begin
          illegal = funct7 != 7'b0000000;
          alu_op  = {1'b0, funct3};
        end else if (funct3 == 3'b101) begin
          illegal = funct7 != 7'b0000000 && funct7 != 7'b0100000;
          alu_op  = {funct7[5], funct3};
        end else begin
          alu_op = {1'b0, funct3};
        end
      end
      OpOp: begin
        use1    = 1'b1;
        use2    = 1'b1;
        wr      = 1'b1;
        alu_op  = {funct7[5], funct3};
        is_md   = funct7 == 7'b0000001;
        illegal = !(funct7 == 7'b0000000 || funct7 == 7'b0000001 ||
                    (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101)));
      end
      OpFence: begin
        // FENCE is a no-op on this in-order, single-master core; FENCE.I is not supported.
        illegal = funct3 != 3'b000;
      end
      OpSystem: begin
        if (funct3 == 3'b000) begin
          unique case (insn)
            32'h0000_0073: is_ecall = 1'b1;
            32'h0010_0073: is_ebreak = 1'b1;
            32'h3020_0073: is_mret = 1'b1;
            32'h1050_0073: ;  // WFI: no-op
            default:       illegal = 1'b1;
          endcase
        end else if (funct3 == 3'b100) begin
          illegal = 1'b1;
        end else begin
          is_csr = 1'b1;
          use1   = !funct3[2];
          wr     = 1'b1;
        end
      end
      default: illegal = 1'b1;
    endcase

    if (insn[1:0] != 2'b11) illegal = 1'b1;
    if (illegal) begin
      use1      = 1'b0;
      use2      = 1'b0;
      wr        = 1'b0;
      is_branch = 1'b0;
      is_jal    = 1'b0;
      is_jalr   = 1'b0;
      is_load   = 1'b0;
      is_store  = 1'b0;
      is_csr    = 1'b0;
      is_mret   = 1'b0;
      is_md     = 1'b0;
      is_ecall  = 1'b0;
      is_ebreak = 1'b0;
    end
  end

  assign rs1   = use1 ? insn[19:15] : 5'd0;
  assign rs2   = use2 ? insn[24:20] : 5'd0;
  assign rd_we = wr && insn[11:7] != 5'd0;
  assign rd    = rd_we ? insn[11:7] : 5'd0;

endmodule
