// Accelerator-domain side of axil_attn (spec 12): pops commands from the
// command FIFO, drives attention_top, pushes read data and the completion
// record into the response FIFO. One command at a time; a READ holds the
// sequencer until its byte is queued.
//   command  [21:20] op: 0 LOAD {[19:18] sel, [17:8] addr, [7:0] data},
//                        1 START {[6:0] n_len}, 2 READ {[9:0] rd_addr}
//   response [32] kind: 0 READ {[7:0] rd_data}, 1 DONE {[31:0] cycle_count}
module attn_seq #(
  parameter bit PIPE_ROM = 1'b1,
  parameter bit PV_SPLIT = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        cmd_empty,
  input  logic [21:0] cmd_data,
  output logic        cmd_pop,
  input  logic        rsp_full,
  output logic        rsp_push,
  output logic [32:0] rsp_data,
  output logic        busy        // attention_top busy, for a synchronizer
);
  localparam logic [1:0] OpLoad = 2'd0, OpStart = 2'd1, OpRead = 2'd2;

  logic       we_q, start_q;
  logic [1:0] sel_q;
  logic [9:0] addr_q, rd_addr_q;
  logic [7:0] wdata_q, rd_data;
  logic [6:0] n_len_q;
  logic       done;
  logic [31:0] cycle_count;

  // rd_s1: rd_addr presented; rd_s2: rd_data valid, waiting to be queued.
  logic rd_s1, rd_s2, done_pend;
  logic rsp_v;
  logic [32:0] rsp_q;
  logic rsp_free, take_done, take_rd;

  attention_top #(.PIPE_ROM(PIPE_ROM), .PV_SPLIT(PV_SPLIT)) u_attn (
    .clk, .rst,
    .sel(sel_q), .addr(addr_q), .wdata(wdata_q), .we(we_q),
    .n_len(n_len_q), .start(start_q), .busy, .done,
    .rd_addr(rd_addr_q), .rd_data, .cycle_count
  );

  assign cmd_pop = !cmd_empty && !rd_s1 && !rd_s2;

  // One response register in front of the FIFO; DONE has priority.
  assign rsp_free  = !rsp_v || !rsp_full;
  assign take_done = rsp_free && done_pend;
  assign take_rd   = rsp_free && !done_pend && rd_s2;
  assign rsp_push  = rsp_v;
  assign rsp_data  = rsp_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      we_q      <= 1'b0;
      start_q   <= 1'b0;
      sel_q     <= 2'd3;
      addr_q    <= '0;
      wdata_q   <= '0;
      n_len_q   <= 7'd4;
      rd_addr_q <= '0;
      rd_s1     <= 1'b0;
      rd_s2     <= 1'b0;
      done_pend <= 1'b0;
      rsp_v     <= 1'b0;
      rsp_q     <= '0;
    end else begin
      we_q    <= 1'b0;
      start_q <= 1'b0;
      if (cmd_pop) begin
        unique case (cmd_data[21:20])
          OpLoad: begin
            we_q    <= 1'b1;
            sel_q   <= cmd_data[19:18];
            addr_q  <= cmd_data[17:8];
            wdata_q <= cmd_data[7:0];
          end
          OpStart: begin
            start_q <= 1'b1;
            n_len_q <= cmd_data[6:0];
          end
          OpRead: begin
            rd_addr_q <= cmd_data[9:0];
            rd_s1     <= 1'b1;
          end
          default: ;
        endcase
      end
      if (rd_s1) begin
        rd_s1 <= 1'b0;
        rd_s2 <= 1'b1;
      end

      if (rsp_v && !rsp_full) rsp_v <= 1'b0;
      if (take_done) begin
        rsp_v     <= 1'b1;
        rsp_q     <= {1'b1, cycle_count};
        done_pend <= 1'b0;
      end else if (take_rd) begin
        rsp_v <= 1'b1;
        rsp_q <= {1'b0, 24'd0, rd_data};
        rd_s2 <= 1'b0;
      end
      if (done) done_pend <= 1'b1;
    end
  end
endmodule
