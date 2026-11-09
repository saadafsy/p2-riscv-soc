// Simulation-only OBI slave memory with one injectable fault (spec 4 timing:
// gnt combinational from req, rvalid at least one cycle after the
// handshake, READ_FIRST data). gnt_ok / rsp_ok are driven at random by the
// testbench to add grant and response latency.
//
// Fault on victim bit (f_vaddr, f_vbit); coupling and address faults also
// use the aggressor (f_aaddr, f_abit). Applied on every write, in this
// order, and mirrored exactly by FaultMem in march_ref.py:
//   1 SA0, 2 SA1          victim bit always stores 0 / 1
//   3 TF_UP, 4 TF_DN      victim bit cannot rise / cannot fall
//   5 CFIN                aggressor transition (f_up: 0->1, else 1->0) inverts victim
//   6 CFID                aggressor transition forces victim to f_val
//   7 CFST                while aggressor bit == f_up, victim is forced to f_val
//   8 AF                  accesses to f_vaddr land on f_aaddr instead
module fault_mem #(
  parameter int AW = 6
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          req,
  output logic          gnt,
  input  logic [31:0]   addr,
  input  logic          we,
  input  logic [3:0]    be,
  input  logic [31:0]   wdata,
  output logic          rvalid,
  output logic [31:0]   rdata,
  input  logic          gnt_ok,
  input  logic          rsp_ok,
  input  logic          clr,     // zero the array (reference model starts from 0)
  input  logic [3:0]    f_type,
  input  logic [AW-1:0] f_vaddr,
  input  logic [4:0]    f_vbit,
  input  logic [AW-1:0] f_aaddr,
  input  logic [4:0]    f_abit,
  input  logic          f_up,
  input  logic          f_val
);
  logic [31:0] m [2**AW];
  logic        pend;
  logic [31:0] rdata_q;

  initial for (int i = 0; i < 2**AW; i++) m[i] = 32'h0;

  assign gnt    = req && gnt_ok && (!pend || rvalid);
  assign rvalid = pend && rsp_ok;
  assign rdata  = rdata_q;

  function automatic logic [AW-1:0] remap(logic [AW-1:0] i);
    return (f_type == 4'd8 && i == f_vaddr) ? f_aaddr : i;
  endfunction

  task automatic do_write(logic [AW-1:0] i, logic [31:0] d);
    logic aold, anew, trans;
    aold = m[f_aaddr][f_abit];
    if (i == f_vaddr) begin
      unique case (f_type)
        4'd1: d[f_vbit] = 1'b0;
        4'd2: d[f_vbit] = 1'b1;
        4'd3: if (!m[i][f_vbit] && d[f_vbit]) d[f_vbit] = 1'b0;
        4'd4: if (m[i][f_vbit] && !d[f_vbit]) d[f_vbit] = 1'b1;
        default: ;
      endcase
    end
    m[i] = d;
    anew  = m[f_aaddr][f_abit];
    trans = f_up ? (!aold && anew) : (aold && !anew);
    if (i == f_aaddr && trans) begin
      if (f_type == 4'd5) m[f_vaddr][f_vbit] = !m[f_vaddr][f_vbit];
      if (f_type == 4'd6) m[f_vaddr][f_vbit] = f_val;
    end
    if (f_type == 4'd7 && m[f_aaddr][f_abit] == f_up) m[f_vaddr][f_vbit] = f_val;
  endtask

  always @(posedge clk) begin
    if (clr) for (int i = 0; i < 2**AW; i++) m[i] = 32'h0;
    if (rst) begin
      pend    <= 1'b0;
      rdata_q <= '0;
    end else begin
      if (req && gnt) begin
        logic [AW-1:0] i;
        logic [31:0]   d;
        i = remap(addr[AW+1:2]);
        rdata_q <= m[i];
        if (we) begin
          d = m[i];
          for (int b = 0; b < 4; b++) if (be[b]) d[8*b +: 8] = wdata[8*b +: 8];
          do_write(i, d);
        end
        pend <= 1'b1;
      end else if (rvalid) begin
        pend <= 1'b0;
      end
    end
  end
endmodule
