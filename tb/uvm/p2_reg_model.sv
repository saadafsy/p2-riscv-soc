// p2_reg_model: SystemVerilog mirror of every APB register (spec 5 and 8),
// cycle-accurate where the hardware is time-dependent.
//
// Time base: an access is applied at its completing APB ACCESS edge c (the
// apb_if cycle count). read() values are the registers during cycle c
// (before edge c); the write side effects happen at edge c, as in the RTL.
//
// Byte lanes: every write acts on the pstrb lanes only (m = lane mask).
// Write-1 action registers: OUT_SET (OUT |= d&m), OUT_CLR (OUT &= ~(d&m)),
// UART STATUS bit3 clears rx_overrun when lane 0 is enabled, UART DATA
// pushes TX when lane 0 is enabled, SIMCTRL EXIT needs a nonzero pstrb and
// takes the enabled lanes, PUTC needs lane 0.
//
// TIMER: exact prediction, no tolerance. mtime during cycle k is
// mt_base + (k - mt_base_cyc). A write to one half at edge c replaces the
// enabled bytes of mtime(c), skips that edge's increment, and re-anchors
// mt_base_cyc = c + 1. mtimecmp is plain storage (reset all-ones).
//
// UART TX: the 16-deep FIFO and the 10-bit shifter are stepped one edge
// at a time (lazily, up to the next access), using the divisor in force at
// each edge (div < 2 acts as 2): pop when the shifter is idle and the FIFO
// is non-empty, busy for 10 * div edges. So tx_full / tx_empty are exact.
// UART RX: frames from uart_rx_driver are applied as a batch while the OBI
// port is idle (push, or set rx_overrun when 16 are already queued).
class p2_reg_model;
  // GPIO
  bit [15:0] gpio_out;
  // TIMER
  bit [63:0] mt_base;
  longint unsigned mt_base_cyc;
  bit [63:0] mtimecmp;
  // UART
  bit [15:0] divisor;
  bit        irq_en;
  bit        overrun;
  int        txn;          // TX FIFO occupancy
  bit        tx_busy;
  bit [15:0] tx_cnt;
  bit [3:0]  tx_bit;
  bit [7:0]  rxq[$];
  longint unsigned model_cyc;  // state below is "during cycle model_cyc"
  int        tx_pushed, tx_dropped;
  // SIMCTRL
  bit        exit_seen;
  bit [31:0] exit_code;
  bit [15:0] putc_count;
  // last access, for coverage
  int        last_txn_pre;
  bit        last_push_drop;
  bit        last_ovr_clear;

  function new();
    reset();
  endfunction

  function void reset();
    gpio_out = '0;
    mt_base = '0;
    mt_base_cyc = 0;
    mtimecmp = '1;
    divisor = 16'd868;
    irq_en = 0;
    overrun = 0;
    txn = 0;
    tx_busy = 0;
    tx_cnt = '0;
    tx_bit = '0;
    rxq.delete();
    model_cyc = 0;
    tx_pushed = 0;
    tx_dropped = 0;
    exit_seen = 0;
    exit_code = '0;
    putc_count = '0;
  endfunction

  function bit [63:0] mtime_at(longint unsigned c);
    return mt_base + 64'(c - mt_base_cyc);
  endfunction

  function bit [15:0] div_eff();
    return (divisor < 16'd2) ? 16'd2 : divisor;
  endfunction

  // One clock edge of the TX FIFO + shifter, from the pre-edge state.
  function void tx_edge(bit push);
    bit empty, full, do_push, do_pop;
    empty = (txn == 0);
    full = (txn == 16);
    do_push = push && !full;
    do_pop = !tx_busy && !empty;
    if (!tx_busy) begin
      if (!empty) begin
        tx_busy = 1;
        tx_bit = '0;
        tx_cnt = '0;
      end
    end else if (tx_cnt >= div_eff() - 16'd1) begin  // mirrors uart_apb: >= after a divisor drop
      tx_cnt = '0;
      if (tx_bit == 4'd9) tx_busy = 0;
      else tx_bit = tx_bit + 4'd1;
    end else begin
      tx_cnt = tx_cnt + 16'd1;
    end
    txn = txn + int'(do_push) - int'(do_pop);
    if (do_push) tx_pushed++;
    if (push && full) tx_dropped++;
  endfunction

  function void advance(longint unsigned c);
    while (model_cyc < c) begin
      tx_edge(1'b0);
      model_cyc++;
    end
  endfunction

  // Pins during cycle c (call after advance(c)).
  function bit exp_irq_timer(longint unsigned c);
    return mtime_at(c) >= mtimecmp;
  endfunction
  function bit exp_uart_irq();
    return irq_en && (rxq.size() != 0);
  endfunction

  // Register read during cycle c (no side effects).
  function bit [31:0] peek(int slot, bit [11:0] off, longint unsigned c, bit [20:0] in_d2);
    bit [63:0] mt;
    if (off[11:4] != 8'd0) return 32'd0;
    case (slot)
      0: case (off[3:2])
           2'd0: return (rxq.size() == 0) ? 32'd0 : {23'd0, 1'b1, rxq[0]};
           2'd1: return {28'd0, overrun, rxq.size() != 0, (txn == 0) && !tx_busy, txn == 16};
           2'd2: return {16'd0, divisor};
           default: return {31'd0, irq_en};
         endcase
      1: return (off[3:2] == 2'd1) ? {11'd0, in_d2} : {16'd0, gpio_out};
      2: begin
        mt = mtime_at(c);
        case (off[3:2])
          2'd0: return mt[31:0];
          2'd1: return mt[63:32];
          2'd2: return mtimecmp[31:0];
          default: return mtimecmp[63:32];
        endcase
      end
      default: return 32'd0;  // SIMCTRL reads 0
    endcase
  endfunction

  // One APB access completing at edge c: returns the read value, applies
  // the edge-c side effects. Caller has checked the pins first.
  function bit [31:0] access(int slot, bit [11:0] off, bit we, bit [3:0] strb,
                             bit [31:0] pwdata, longint unsigned c, bit [20:0] in_d2);
    bit [31:0] rd, m, d;
    bit [15:0] m16, d16;
    bit [63:0] mt;
    bit hit, push;
    if (c < model_cyc) $fatal(1, "p2_reg_model: access at %0d before model time %0d", c, model_cyc);
    advance(c);
    rd = peek(slot, off, c, in_d2);
    m = {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
    d = pwdata & m;
    m16 = m[15:0];
    d16 = d[15:0];
    hit = (off[11:4] == 8'd0);
    push = we && slot == 0 && hit && off[3:2] == 2'd0 && strb[0];
    last_txn_pre = txn;
    last_push_drop = push && (txn == 16);
    last_ovr_clear = 0;
    // edge c: TX FIFO/shifter with the pre-edge divisor
    tx_edge(push);
    model_cyc = c + 1;
    case (slot)
      0: if (hit) begin
        if (!we && off[3:2] == 2'd0 && rxq.size() != 0) void'(rxq.pop_front());
        if (we && off[3:2] == 2'd1 && strb[0] && d[3]) begin
          last_ovr_clear = overrun;
          overrun = 0;
        end
        if (we && off[3:2] == 2'd2) divisor = (divisor & ~m16) | d16;
        if (we && off[3:2] == 2'd3 && strb[0]) irq_en = d[0];
      end
      1: if (hit && we) begin
        case (off[3:2])
          2'd0: gpio_out = (gpio_out & ~m16) | d16;
          2'd2: gpio_out = gpio_out | d16;
          2'd3: gpio_out = gpio_out & ~d16;
          default: ;
        endcase
      end
      2: if (hit && we && strb != 4'b0000) begin
        mt = mtime_at(c);
        case (off[3:2])
          2'd0: begin
            mt[31:0] = (mt[31:0] & ~m) | d;
            mt_base = mt;
            mt_base_cyc = c + 1;
          end
          2'd1: begin
            mt[63:32] = (mt[63:32] & ~m) | d;
            mt_base = mt;
            mt_base_cyc = c + 1;
          end
          2'd2: mtimecmp[31:0] = (mtimecmp[31:0] & ~m) | d;
          default: mtimecmp[63:32] = (mtimecmp[63:32] & ~m) | d;
        endcase
      end
      15: if (we) begin
        if (off[11:2] == 10'h000 && strb != 4'b0000) begin
          exit_seen = 1;
          exit_code = d;
        end else if (off[11:2] == 10'h001 && strb[0]) begin
          putc_count = putc_count + 16'd1;
        end
      end
      default: ;
    endcase
    return we ? 32'd0 : rd;
  endfunction

  function void rx_frame(bit [7:0] b);
    if (rxq.size() == 16) overrun = 1;
    else rxq.push_back(b);
  endfunction
endclass
