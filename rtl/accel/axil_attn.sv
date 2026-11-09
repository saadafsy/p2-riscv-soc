// AXI4-Lite slave for the p1 attention engine (spec 12). Registers live on
// the system clock; attention_top and its sequencer (attn_seq) run on
// accel_clk. Commands cross in a 4-deep async FIFO, read data and the
// completion record (DONE + cycle_count) cross back in another, so CYCLES
// and DONE update together. Only attention_top's busy level uses a plain
// 2-flop synchronizer (STATUS.ACCEL_BUSY, informational).
module axil_attn #(
  parameter bit PIPE_ROM = 1'b1,
  parameter bit PV_SPLIT = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  // AXI4-Lite slave
  input  logic        awvalid,
  output logic        awready,
  input  logic [31:0] awaddr,
  input  logic [2:0]  awprot,
  input  logic        wvalid,
  output logic        wready,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  output logic        bvalid,
  input  logic        bready,
  output logic [1:0]  bresp,
  input  logic        arvalid,
  output logic        arready,
  input  logic [31:0] araddr,
  input  logic [2:0]  arprot,
  output logic        rvalid,
  input  logic        rready,
  output logic [31:0] rdata,
  output logic [1:0]  rresp,
  output logic        irq,
  // accelerator clock domain
  input  logic        accel_clk,
  input  logic        accel_rst
);
  localparam logic [1:0] Okay = 2'b00, SlvErr = 2'b10;
  localparam logic [2:0] RCtrl = 3'd0, RStatus = 3'd1, RLoad = 3'd2, RRdAddr = 3'd3,
                         RRdData = 3'd4, RCycles = 3'd5, RIrq = 3'd6, RId = 3'd7;
  localparam logic [31:0] IdValue = 32'h4154_544E;  // "ATTN"
  localparam logic [1:0] OpLoad = 2'd0, OpStart = 2'd1, OpRead = 2'd2;

  // ---------------------------------------------------------------- state
  logic        aw_v, w_v, ar_v;
  logic [31:0] aw_a, w_d, ar_a;
  logic [3:0]  w_s;
  logic [6:0]  n_len_q;
  logic        busy_q, done_q, irq_en_q;
  logic [9:0]  rd_addr_q;
  logic [7:0]  rd_data_q;
  logic [3:0]  rd_cnt;     // READ commands whose byte has not come back
  logic [31:0] cycles_q;
  logic        accel_busy_s;

  // Command / response FIFOs
  logic        cmd_push, cmd_full, cmd_pop, cmd_empty;
  logic [21:0] cmd_wdata, cmd_rdata;
  logic        rsp_push, rsp_full, rsp_empty;
  logic [32:0] rsp_wdata, rsp_rdata;
  logic        accel_busy;

  // ---------------------------------------------------------------- decode
  // Mapped: addr[27:16] = 0 (addr[31:28] is the decoder's), word aligned,
  // offset < 0x20.
  function automatic logic mapped(input logic [27:5] a_hi, input logic [1:0] a_lo);
    mapped = (a_hi == 23'd0) && (a_lo == 2'b00);
  endfunction

  function automatic logic n_ok(input logic [6:0] n);
    n_ok = (n[1:0] == 2'b00) && (n >= 7'd4) && (n <= 7'd64);
  endfunction

  // ---------------------------------------------------------------- write path
  logic        w_exec, w_map, full_word, start_req;
  logic [2:0]  w_reg;
  logic [6:0]  n_len_w;
  logic [1:0]  w_resp;
  logic        set_busy, clr_done_w, set_irq_en, irq_en_w, push_read;

  assign awready = !aw_v;
  assign wready  = !w_v;
  // A write executes once both halves are held, B is free and the command
  // FIFO has room (every command-producing write needs one slot).
  assign w_exec    = aw_v && w_v && !bvalid && !cmd_full && (rd_cnt != 4'hF);
  assign w_map     = mapped(aw_a[27:5], aw_a[1:0]);
  assign w_reg     = aw_a[4:2];
  assign full_word = (w_s == 4'hF);
  assign n_len_w   = w_s[1] ? w_d[14:8] : n_len_q;
  assign start_req = w_s[0] && w_d[0];

  always_comb begin
    w_resp     = Okay;
    cmd_push   = 1'b0;
    cmd_wdata  = '0;
    set_busy   = 1'b0;
    clr_done_w = 1'b0;
    set_irq_en = 1'b0;
    irq_en_w   = irq_en_q;
    push_read  = 1'b0;
    if (!w_map) begin
      w_resp = SlvErr;
    end else begin
      unique case (w_reg)
        RCtrl: begin
          if (start_req) begin
            if (busy_q || !n_ok(n_len_w)) begin
              w_resp = SlvErr;
            end else begin
              cmd_push   = 1'b1;
              cmd_wdata  = {OpStart, 13'd0, n_len_w};
              set_busy   = 1'b1;
              clr_done_w = 1'b1;
            end
          end
        end
        RStatus: begin
          if (w_s[0]) begin
            clr_done_w = w_d[1];
            set_irq_en = 1'b1;
            irq_en_w   = w_d[2];
          end
        end
        RLoad: begin
          if (busy_q || !full_word) begin
            w_resp = SlvErr;
          end else begin
            cmd_push  = 1'b1;
            cmd_wdata = {OpLoad, w_d[21:20], w_d[17:8], w_d[7:0]};
          end
        end
        RRdAddr: begin
          if (!full_word) begin
            w_resp = SlvErr;
          end else begin
            cmd_push  = 1'b1;
            cmd_wdata = {OpRead, 10'd0, w_d[9:0]};
            push_read = 1'b1;
          end
        end
        RIrq:    clr_done_w = w_s[0] && w_d[0];
        default: ;  // RD_DATA, CYCLES, ID are read-only
      endcase
    end
    if (!w_exec) begin
      cmd_push   = 1'b0;
      set_busy   = 1'b0;
      clr_done_w = 1'b0;
      set_irq_en = 1'b0;
      push_read  = 1'b0;
    end
  end

  // ---------------------------------------------------------------- read path
  logic        r_exec, r_map;
  logic [2:0]  r_reg;
  logic [31:0] r_val;

  assign arready = !ar_v;
  assign r_map   = mapped(ar_a[27:5], ar_a[1:0]);
  assign r_reg   = ar_a[4:2];
  // RD_DATA waits for every outstanding READ to come back.
  assign r_exec  = ar_v && !rvalid && !(r_map && r_reg == RRdData && rd_cnt != 4'd0);

  always_comb begin
    unique case (r_reg)
      RCtrl:   r_val = {17'd0, n_len_q, 8'd0};
      RStatus: r_val = {28'd0, accel_busy_s, irq_en_q, done_q, busy_q};
      RRdAddr: r_val = {22'd0, rd_addr_q};
      RRdData: r_val = {24'd0, rd_data_q};
      RCycles: r_val = cycles_q;
      RIrq:    r_val = {31'd0, irq};
      RId:     r_val = IdValue;
      default: r_val = 32'd0;  // LOAD
    endcase
    if (!r_map) r_val = 32'd0;
  end

  // ---------------------------------------------------------------- responses in
  logic rsp_rd, rsp_done;
  assign rsp_rd   = !rsp_empty && !rsp_rdata[32];
  assign rsp_done = !rsp_empty && rsp_rdata[32];

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_v      <= 1'b0;
      w_v       <= 1'b0;
      ar_v      <= 1'b0;
      aw_a      <= '0;
      w_d       <= '0;
      w_s       <= '0;
      ar_a      <= '0;
      bvalid    <= 1'b0;
      bresp     <= Okay;
      rvalid    <= 1'b0;
      rresp     <= Okay;
      rdata     <= '0;
      n_len_q   <= 7'd4;
      busy_q    <= 1'b0;
      done_q    <= 1'b0;
      irq_en_q  <= 1'b0;
      rd_addr_q <= '0;
      rd_data_q <= '0;
      rd_cnt    <= '0;
      cycles_q  <= '0;
    end else begin
      // AW / W capture, B
      if (awvalid && awready) begin
        aw_v <= 1'b1;
        aw_a <= awaddr;
      end
      if (wvalid && wready) begin
        w_v <= 1'b1;
        w_d <= wdata;
        w_s <= wstrb;
      end
      if (bvalid && bready) bvalid <= 1'b0;
      if (w_exec) begin
        aw_v   <= 1'b0;
        w_v    <= 1'b0;
        bvalid <= 1'b1;
        bresp  <= w_resp;
        if (w_map && w_reg == RCtrl && w_s[1] && w_resp == Okay) n_len_q <= w_d[14:8];
        if (push_read) rd_addr_q <= w_d[9:0];
      end

      // AR capture, R
      if (arvalid && arready) begin
        ar_v <= 1'b1;
        ar_a <= araddr;
      end
      if (rvalid && rready) rvalid <= 1'b0;
      if (r_exec) begin
        ar_v   <= 1'b0;
        rvalid <= 1'b1;
        rdata  <= r_val;
        rresp  <= r_map ? Okay : SlvErr;
      end

      // Status. A completion record wins over a same-cycle DONE clear.
      if (set_irq_en) irq_en_q <= irq_en_w;
      if (set_busy) busy_q <= 1'b1;
      if (clr_done_w) done_q <= 1'b0;
      if (rsp_done) begin
        busy_q   <= 1'b0;
        done_q   <= 1'b1;
        cycles_q <= rsp_rdata[31:0];
      end
      if (rsp_rd) rd_data_q <= rsp_rdata[7:0];
      rd_cnt <= rd_cnt + {3'd0, push_read} - {3'd0, rsp_rd};
    end
  end

  assign irq = done_q && irq_en_q;

  // ---------------------------------------------------------------- CDC
  async_fifo #(.W(22), .AW(2)) u_cmd (
    .wclk(clk), .wrst(rst), .winc(cmd_push), .wdata(cmd_wdata), .wfull(cmd_full),
    .rclk(accel_clk), .rrst(accel_rst), .rinc(cmd_pop), .rdata(cmd_rdata), .rempty(cmd_empty)
  );

  async_fifo #(.W(33), .AW(2)) u_rsp (
    .wclk(accel_clk), .wrst(accel_rst), .winc(rsp_push), .wdata(rsp_wdata), .wfull(rsp_full),
    .rclk(clk), .rrst(rst), .rinc(!rsp_empty), .rdata(rsp_rdata), .rempty(rsp_empty)
  );

  sync2ff u_busy_sync (.clk(clk), .rst(rst), .d(accel_busy), .q(accel_busy_s));

  attn_seq #(.PIPE_ROM(PIPE_ROM), .PV_SPLIT(PV_SPLIT)) u_seq (
    .clk(accel_clk), .rst(accel_rst),
    .cmd_empty, .cmd_data(cmd_rdata), .cmd_pop,
    .rsp_full, .rsp_push, .rsp_data(rsp_wdata),
    .busy(accel_busy)
  );

  logic unused;
  assign unused = ^{awprot, arprot, aw_a[31:28], ar_a[31:28], w_d[31:22], w_d[19:18]};
endmodule
