// Instruction fetch: one OBI request per cycle, a 2-entry fall-through queue
// that also serves as the IF/ID register.
module rv32_fetch #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst,
    // OBI instruction port
    output logic        i_req,
    input  logic        i_gnt,
    output logic [31:0] i_addr,
    input  logic        i_rvalid,
    input  logic [31:0] i_rdata,
    // control from the pipeline
    input  logic        redirect,
    input  logic [31:0] redirect_pc,
    input  logic        pop,
    // instruction presented to ID
    output logic        id_valid,
    output logic [31:0] id_pc,
    output logic [31:0] id_insn
);

  logic [31:0] fetch_pc, out_pc, redir_pc;
  logic        outstanding, out_kill, redir_pend, req_hold;
  logic [ 1:0] count;
  logic [31:0] q0_pc, q0_insn, q1_pc, q1_insn;

  logic resp_ok, push, hs, room;

  // A response for a request made before a redirect is wrong-path.
  assign resp_ok = i_rvalid && outstanding && !out_kill;
  assign push    = resp_ok && !redirect;
  assign hs      = i_req && i_gnt;

  // Each request reserves a queue slot so a stalled ID never drops a response.
  assign room    = ({1'b0, count} + {2'b00, outstanding}) < 3'd2;
  // OBI: once req is up it stays up (same address) until gnt.
  assign i_req   = req_hold || ((!outstanding || i_rvalid) && room);
  assign i_addr  = fetch_pc;

  assign id_valid = (count != 2'd0) || resp_ok;
  assign id_pc    = (count != 2'd0) ? q0_pc : out_pc;
  assign id_insn  = (count != 2'd0) ? q0_insn : i_rdata;

  always_ff @(posedge clk) begin
    if (rst) begin
      fetch_pc    <= RESET_PC;
      out_pc      <= 32'h0;
      redir_pc    <= 32'h0;
      outstanding <= 1'b0;
      out_kill    <= 1'b0;
      redir_pend  <= 1'b0;
      req_hold    <= 1'b0;
    end else begin
      req_hold <= i_req && !i_gnt;
      if (hs) begin
        outstanding <= 1'b1;
        out_pc      <= fetch_pc;
        out_kill    <= redirect || redir_pend;
        redir_pend  <= 1'b0;
        if (redirect) fetch_pc <= redirect_pc;
        else if (redir_pend) fetch_pc <= redir_pc;
        else fetch_pc <= fetch_pc + 32'd4;
      end else begin
        if (i_rvalid) begin
          outstanding <= 1'b0;
          out_kill    <= 1'b0;
        end else if (redirect && outstanding) begin
          out_kill <= 1'b1;
        end
        if (redirect) begin
          // A held request must keep its address; apply the target after gnt.
          if (i_req) begin
            redir_pend <= 1'b1;
            redir_pc   <= redirect_pc;
          end else begin
            fetch_pc <= redirect_pc;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst || redirect) begin
      count <= 2'd0;
    end else begin
      unique case ({push, pop})
        2'b10:   count <= count + 2'd1;
        2'b01:   count <= count - 2'd1;
        default: ;
      endcase
    end
  end

  // The data slots ignore redirect (timing): a slot is read only while count
  // covers it, and every counted slot is written after the last redirect, so
  // they update on resp_ok (push without !redirect); wrong-path writes are
  // never observed.
  always_ff @(posedge clk) begin
    if (rst) begin
      q0_pc   <= 32'h0;
      q0_insn <= 32'h0;
      q1_pc   <= 32'h0;
      q1_insn <= 32'h0;
    end else begin
      unique case ({resp_ok, pop})
        2'b10: begin
          if (count == 2'd0) begin
            q0_pc   <= out_pc;
            q0_insn <= i_rdata;
          end else begin
            q1_pc   <= out_pc;
            q1_insn <= i_rdata;
          end
        end
        2'b01: begin
          q0_pc   <= q1_pc;
          q0_insn <= q1_insn;
        end
        2'b11: begin
          // count == 0 is pure fall-through: nothing stored
          if (count == 2'd1) begin
            q0_pc   <= out_pc;
            q0_insn <= i_rdata;
          end else if (count == 2'd2) begin
            q0_pc   <= q1_pc;
            q0_insn <= q1_insn;
            q1_pc   <= out_pc;
            q1_insn <= i_rdata;
          end
        end
        default: ;
      endcase
    end
  end

endmodule
