// UART 8N1 APB4 slave. Register map (spec 8):
//   0x0 DATA     W: push TX FIFO when pstrb[0] (dropped when full). R: pop RX FIFO,
//                bit 8 = valid; reads 0 when the RX FIFO is empty.
//   0x4 STATUS   bit0 tx_full, bit1 tx_empty, bit2 rx_valid, bit3 rx_overrun (W1C).
//   0x8 DIVISOR  clk cycles per bit (16 bits, reset 868); values below 2 act as 2.
//   0xC IRQ_EN   bit0 rx interrupt enable.
// Writes act on the pstrb-enabled byte lanes only (spec 5).
// tx_empty means FIFO empty and the shifter idle, so firmware can wait for
// the line to drain before exiting.
module uart_apb #(
  parameter logic [15:0] DIV_RESET = 16'd868
) (
  input  logic        pclk,
  input  logic        presetn,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic [2:0]  pprot,   // unused (lint waiver: folded into `unused`)
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  input  logic        rx,
  output logic        tx,
  output logic        irq
);
  logic rst;
  assign rst = !presetn;

  localparam logic [3:0] AddrData = 4'h0, AddrStatus = 4'h4, AddrDiv = 4'h8, AddrIrqEn = 4'hC;

  logic       acc_wr, acc_rd;
  logic [3:0] reg_a;
  assign acc_wr = psel && penable && pwrite;
  assign acc_rd = psel && penable && !pwrite;
  // Word decode: paddr[1:0] ignored (sub-word stores hit the register, spec 5);
  // offsets above 0xC map to no register (0xF), reading 0 and ignoring writes.
  assign reg_a  = (paddr[11:4] == 8'd0) ? {paddr[3:2], 2'b00} : 4'hF;

  logic [15:0] divisor;
  logic        irq_en;
  logic        overrun;

  // ---------------- FIFOs ----------------
  logic       txf_push, txf_pop, txf_full, txf_empty;
  logic [7:0] txf_rdata;
  logic       rxf_push, rxf_pop, rxf_full, rxf_empty;
  logic [7:0] rxf_wdata, rxf_rdata;
  logic [4:0] txf_count, rxf_count;

  assign txf_push = acc_wr && (reg_a == AddrData) && pstrb[0];
  assign rxf_pop  = acc_rd && (reg_a == AddrData);

  sync_fifo #(.WIDTH(8), .DEPTH(16)) u_txf (
    .clk(pclk), .rst, .push(txf_push), .wdata(pwdata[7:0]), .pop(txf_pop),
    .rdata(txf_rdata), .full(txf_full), .empty(txf_empty), .count(txf_count)
  );
  sync_fifo #(.WIDTH(8), .DEPTH(16)) u_rxf (
    .clk(pclk), .rst, .push(rxf_push), .wdata(rxf_wdata), .pop(rxf_pop),
    .rdata(rxf_rdata), .full(rxf_full), .empty(rxf_empty), .count(rxf_count)
  );

  // Divisor below 2 would make the half-bit RX delay zero.
  logic [15:0] div_eff, half_eff;
  assign div_eff  = (divisor < 16'd2) ? 16'd2 : divisor;
  assign half_eff = div_eff >> 1;

  // ---------------- TX ----------------
  logic        tx_busy;
  logic [15:0] tx_cnt;
  logic [3:0]  tx_bit;     // 0 start, 1..8 data, 9 stop
  logic [8:0]  tx_shift;   // {stop, data} shifted out LSB first after start

  assign txf_pop = !tx_busy && !txf_empty;

  always_ff @(posedge pclk) begin
    if (rst) begin
      tx_busy  <= 1'b0;
      tx_cnt   <= '0;
      tx_bit   <= '0;
      tx_shift <= '1;
      tx       <= 1'b1;
    end else if (!tx_busy) begin
      tx <= 1'b1;
      if (!txf_empty) begin
        tx_busy  <= 1'b1;
        tx_shift <= {1'b1, txf_rdata};
        tx_bit   <= '0;
        tx_cnt   <= '0;
        tx       <= 1'b0;
      end
    end else if (tx_cnt == div_eff - 16'd1) begin
      tx_cnt <= '0;
      if (tx_bit == 4'd9) begin
        tx_busy <= 1'b0;
        tx      <= 1'b1;
      end else begin
        tx_bit   <= tx_bit + 4'd1;
        tx       <= tx_shift[0];
        tx_shift <= {1'b1, tx_shift[8:1]};
      end
    end else begin
      tx_cnt <= tx_cnt + 16'd1;
    end
  end

  // ---------------- RX ----------------
  logic rx_s;
  sync2ff #(.WIDTH(1), .RESET_VAL(1'b1)) u_rx_sync (.clk(pclk), .rst, .d(rx), .q(rx_s));

  logic        rx_busy;
  logic [15:0] rx_cnt;
  logic [3:0]  rx_bit;     // 0 start, 1..8 data, 9 stop
  logic [7:0]  rx_shift;

  // Sample points are mid-bit: half a bit after the start edge, then every bit.
  always_ff @(posedge pclk) begin
    if (rst) begin
      rx_busy  <= 1'b0;
      rx_cnt   <= '0;
      rx_bit   <= '0;
      rx_shift <= '0;
    end else if (!rx_busy) begin
      if (!rx_s) begin
        rx_busy <= 1'b1;
        rx_cnt  <= '0;
        rx_bit  <= '0;
      end
    end else if (rx_cnt == ((rx_bit == 4'd0) ? half_eff - 16'd1 : div_eff - 16'd1)) begin
      rx_cnt <= '0;
      if (rx_bit == 4'd0) begin
        if (rx_s) rx_busy <= 1'b0;  // glitch, not a start bit
        else rx_bit <= 4'd1;
      end else if (rx_bit == 4'd9) begin
        rx_busy <= 1'b0;            // back to hunting at mid-stop for back-to-back frames
      end else begin
        rx_shift <= {rx_s, rx_shift[7:1]};
        rx_bit   <= rx_bit + 4'd1;
      end
    end else begin
      rx_cnt <= rx_cnt + 16'd1;
    end
  end

  logic rx_stop_ok;
  assign rx_stop_ok = rx_busy && (rx_bit == 4'd9) && (rx_cnt == div_eff - 16'd1) && rx_s;
  // A frame with a bad stop bit is discarded.
  assign rxf_push  = rx_stop_ok;
  assign rxf_wdata = rx_shift;

  // ---------------- registers ----------------
  always_ff @(posedge pclk) begin
    if (rst) begin
      divisor <= DIV_RESET;
      irq_en  <= 1'b0;
      overrun <= 1'b0;
    end else begin
      if (acc_wr && reg_a == AddrDiv) begin
        if (pstrb[0]) divisor[7:0]  <= pwdata[7:0];
        if (pstrb[1]) divisor[15:8] <= pwdata[15:8];
      end
      if (acc_wr && reg_a == AddrIrqEn && pstrb[0]) irq_en <= pwdata[0];
      if (rx_stop_ok && rxf_full) overrun <= 1'b1;  // byte dropped; set wins over clear
      else if (acc_wr && reg_a == AddrStatus && pstrb[0] && pwdata[3]) overrun <= 1'b0;
    end
  end

  logic tx_empty;
  assign tx_empty = txf_empty && !tx_busy;

  always_comb begin
    unique case (reg_a)
      AddrData:   prdata = rxf_empty ? 32'd0 : {23'd0, 1'b1, rxf_rdata};
      AddrStatus: prdata = {28'd0, overrun, !rxf_empty, tx_empty, txf_full};
      AddrDiv:    prdata = {16'd0, divisor};
      AddrIrqEn:  prdata = {31'd0, irq_en};
      default:    prdata = 32'd0;
    endcase
  end

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign irq     = irq_en && !rxf_empty;

  logic unused;
  assign unused = ^{paddr[1:0], pwdata[31:16], pstrb[3:2], pprot, txf_count, rxf_count};
endmodule
