// Forwarding selects for the EX operands and the load-use stall.
// Register addresses are 0 when unused or not written (see rv32_decoder),
// so a match on a non-zero address is a real dependency.
// The selects are computed one cycle early from the next-cycle ID/EX, EX/MEM
// and MEM/WB contents and registered in rv32_core (timing): this keeps the
// rd/rs compares out of EX.
module rv32_hazard (
    input  logic       id_valid,
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,
    input  logic       ex_valid,
    input  logic       ex_is_load,
    input  logic [4:0] ex_rd,
    input  logic [4:0] ex_rs1,
    input  logic [4:0] ex_rs2,
    input  logic       mem_valid,
    input  logic [4:0] mem_rd,
    input  logic       wb_valid,
    input  logic [4:0] wb_rd,
    // pipeline register updates this cycle
    input  logic       ex_adv,      // ID/EX takes id_rs1/id_rs2
    input  logic       mem_adv,     // EX/MEM takes ex_go, ex_kill ? 0 : ex_rd
    input  logic       wb_adv,      // MEM/WB takes wb_in_valid, mem_rd
    input  logic       ex_go,
    input  logic       ex_kill,
    input  logic       wb_in_valid,
    output logic       load_use,
    output logic [1:0] fwd_a_nxt,   // next-cycle select: 0 ID/EX, 1 EX/MEM, 2 MEM/WB
    output logic [1:0] fwd_b_nxt
);

  // Load data arrives in WB, so a consumer directly behind a load waits one cycle.
  assign load_use = id_valid && ex_valid && ex_is_load && ex_rd != 5'd0 &&
                    (id_rs1 == ex_rd || id_rs2 == ex_rd);

  // Select for the source register EX holds next cycle; the younger producer
  // (EX/MEM) wins over MEM/WB. The compares use current flops only and the
  // advance signals pick among them.
  function automatic logic [1:0] fwd_next(input logic [4:0] id_rs, input logic [4:0] ex_rs);
    logic nz, hit_mem, hit_wb;
    nz      = ex_adv ? id_rs != 5'd0 : ex_rs != 5'd0;
    // ex_kill writes rd = 0, which never matches a non-zero source.
    hit_mem = mem_adv ? ex_go && !ex_kill && (ex_adv ? ex_rd == id_rs : ex_rd == ex_rs)
                      : mem_valid && (ex_adv ? mem_rd == id_rs : mem_rd == ex_rs);
    hit_wb  = wb_adv ? wb_in_valid && (ex_adv ? mem_rd == id_rs : mem_rd == ex_rs)
                     : wb_valid && (ex_adv ? wb_rd == id_rs : wb_rd == ex_rs);
    if (nz && hit_mem) fwd_next = 2'd1;
    else if (nz && hit_wb) fwd_next = 2'd2;
    else fwd_next = 2'd0;
  endfunction

  assign fwd_a_nxt = fwd_next(id_rs1, ex_rs1);
  assign fwd_b_nxt = fwd_next(id_rs2, ex_rs2);

endmodule
