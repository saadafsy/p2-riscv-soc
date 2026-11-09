// obi_item: one OBI data-port access to the APB window (0x1xxx_xxxx), plus
// its request timing. The address is composed from rand fields so each
// variable carries at most one dist (Verilator: no dist and == on the same
// variable): kind picks register / unmapped offset / unmapped slot, slot is
// the APB slot addr[15:12], off is addr[11:0], alias_v fills addr[27:16]
// (ignored by the bridge, spec 7).
// Timing: pipe = 1 raises req the cycle after the previous handshake (so it
// waits for gnt and is granted in the rvalid cycle: back-to-back); pipe = 0
// waits for the previous rvalid and then `delay` idle cycles.
// The same class carries observed requests/responses from the monitor.
typedef enum bit [1:0] {K_REG = 2'd0, K_UNMAP_OFF = 2'd1, K_UNMAP_SLOT = 2'd2} obi_kind_e;

// Register ids for coverage and messages: 0..13 named registers,
// 14..17 unmapped offset inside UART/GPIO/TIMER/SIMCTRL, 18 unmapped slot.
localparam int NREG = 14;
localparam int RID_UNMAP_SLOT = 18;

function automatic string reg_name(int id);
  string n[19] = '{"UART.DATA", "UART.STATUS", "UART.DIVISOR", "UART.IRQ_EN",
                   "GPIO.OUT", "GPIO.IN", "GPIO.OUT_SET", "GPIO.OUT_CLR",
                   "TIMER.MTIME_LO", "TIMER.MTIME_HI", "TIMER.MTIMECMP_LO", "TIMER.MTIMECMP_HI",
                   "SIMCTRL.EXIT", "SIMCTRL.PUTC",
                   "UART.unmapped", "GPIO.unmapped", "TIMER.unmapped", "SIMCTRL.unmapped",
                   "unmapped_slot"};
  if (id < 0 || id > 18) return "?";
  return n[id];
endfunction

// slot -> peripheral index 0..3 (UART, GPIO, TIMER, SIMCTRL), -1 if unpopulated
function automatic int slot_idx(bit [3:0] slot);
  case (slot)
    4'd0: return 0;
    4'd1: return 1;
    4'd2: return 2;
    4'd15: return 3;
    default: return -1;
  endcase
endfunction

class obi_item extends uvm_sequence_item;
  rand obi_kind_e   kind;
  rand bit [3:0]    slot;
  rand bit [11:0]   off;
  rand bit          use_alias;
  rand bit [11:0]   alias_v;
  rand bit          lsb_mode;    // 1: addr[1:0] random (slaves ignore it)
  rand bit          we;
  rand bit [3:0]    be;
  rand bit [31:0]   wdata;
  rand bit          small_div;   // keep UART DIVISOR writes small so TX drains
  rand bit          small_cmp;   // MTIMECMP writes near mtime
  rand int unsigned delay;
  rand bit          pipe;

  bit [31:0]        addr;
  // observed (monitor)
  bit               is_rsp;
  bit [31:0]        rdata;
  longint unsigned  cyc;         // handshake (request) or rvalid (response) edge
  int unsigned      gnt_wait;    // cycles req was high before gnt
  int unsigned      gap;         // handshake edge - previous rvalid edge (0 = back-to-back)
  bit               first;       // no previous response

  constraint c_kind { kind dist {K_REG := 88, K_UNMAP_OFF := 6, K_UNMAP_SLOT := 6}; }
  constraint c_slot {
    (kind == K_UNMAP_SLOT) -> (slot inside {[4'd3:4'd14]});
    (kind != K_UNMAP_SLOT) -> (slot inside {4'd0, 4'd1, 4'd2, 4'd15});
  }
  constraint c_off {
    (kind == K_UNMAP_OFF) -> (off[11:4] != 8'd0);
    (kind != K_UNMAP_OFF) -> (off[11:4] == 8'd0);
    (kind == K_REG && slot == 4'd15) -> (off[3] == 1'b0);
    (!lsb_mode) -> (off[1:0] == 2'b00);
  }
  constraint c_alias {
    use_alias dist {1 := 5, 0 := 95};
    (!use_alias) -> (alias_v == 12'd0);
  }
  constraint c_lsb { lsb_mode dist {1 := 5, 0 := 95}; }
  constraint c_we { we dist {1 := 55, 0 := 45}; }
  // all legal byte / half / word lane patterns
  constraint c_be {
    be dist {4'b1111 := 4, 4'b0011 := 2, 4'b1100 := 2,
             4'b0001 := 1, 4'b0010 := 1, 4'b0100 := 1, 4'b1000 := 1};
  }
  // DIVISOR: uart_apb compares tx_cnt == div-1, so lowering the divisor
  // below the running count mid-character stalls TX until tx_cnt wraps
  // (65536 cycles). A fixed small value keeps TX draining; 5% random values.
  constraint c_div {
    small_div dist {1 := 95, 0 := 5};
    (small_div && kind == K_REG && slot == 4'd0 && off[3:2] == 2'd2) -> (wdata[15:0] == 16'd3);
  }
  // MTIMECMP: half the writes small so irq_timer actually asserts
  constraint c_cmp {
    small_cmp dist {1 := 50, 0 := 50};
    (small_cmp && kind == K_REG && slot == 4'd2 && off[3:2] == 2'd3) -> (wdata == 32'd0);
    (small_cmp && kind == K_REG && slot == 4'd2 && off[3:2] == 2'd2) -> (wdata < 32'h0001_0000);
  }
  // PUTC prints its byte: keep it printable
  constraint c_putc { (kind == K_REG && slot == 4'd15 && off[3:2] == 2'd1) -> (wdata[7:0] inside {[8'd65:8'd90]}); }
  constraint c_delay { delay dist {0 := 40, [1:2] := 30, [3:8] := 20, [9:20] := 10}; }
  constraint c_pipe { pipe dist {1 := 35, 0 := 65}; }

  `uvm_object_utils_begin(obi_item)
    `uvm_field_int(addr, UVM_ALL_ON)
    `uvm_field_int(we, UVM_ALL_ON)
    `uvm_field_int(be, UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
    `uvm_field_int(rdata, UVM_ALL_ON)
    `uvm_field_int(delay, UVM_ALL_ON)
    `uvm_field_int(pipe, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "obi_item");
    super.new(name);
  endfunction

  function void compose();
    addr = {4'h1, alias_v, slot, off};
  endfunction

  function void post_randomize();
    if (!(be inside {4'b1111, 4'b0011, 4'b1100, 4'b0001, 4'b0010, 4'b0100, 4'b1000}))
      `uvm_fatal("ITEM", $sformatf("solver produced illegal be %b", be))
    compose();
  endfunction

  // Directed / observed: derive the fields from a full address.
  function void set_addr(bit [31:0] a);
    addr    = a;
    slot    = a[15:12];
    off     = a[11:0];
    alias_v = a[27:16];
    if (slot_idx(slot) < 0) kind = K_UNMAP_SLOT;
    else if (off[11:4] != 0 || (slot == 4'd15 && off[3])) kind = K_UNMAP_OFF;
    else kind = K_REG;
  endfunction

  function int reg_id();
    int s = slot_idx(addr[15:12]);
    bit [11:0] o = addr[11:0];
    if (s < 0) return RID_UNMAP_SLOT;
    if (o[11:4] != 0) return 14 + s;
    if (s == 3) return o[3] ? 17 : 12 + int'(o[2]);
    return s * 4 + int'(o[3:2]);
  endfunction

  function string convert2string();
    if (is_rsp) return $sformatf("rsp @%0d rdata=%08h", cyc, rdata);
    return $sformatf("%s %s(%08h) be=%b wdata=%08h @%0d", we ? "WR" : "RD",
                     reg_name(reg_id()), addr, be, wdata, cyc);
  endfunction
endclass

// apb_xfer: one completed APB transfer (the ACCESS cycle with pready), with
// the peripheral pins sampled in that same cycle (pre-edge values).
class apb_xfer extends uvm_sequence_item;
  int               slot;        // index of the one-hot psel
  bit [11:0]        paddr;
  bit               pwrite;
  bit [31:0]        pwdata;
  bit [3:0]         pstrb;
  bit [2:0]         pprot;
  bit [31:0]        prdata;
  longint unsigned  cyc;         // completing ACCESS edge
  longint unsigned  setup_cyc;
  int unsigned      waits;       // ACCESS cycles with pready low
  bit [15:0]        gpio_out;
  bit               irq_timer;
  bit               uart_irq;
  bit [20:0]        in_d2;       // gpio_in sampled two edges earlier (2-flop sync)

  `uvm_object_utils(apb_xfer)

  function new(string name = "apb_xfer");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("APB slot%0d %s paddr=%03h pstrb=%b pwdata=%08h prdata=%08h waits=%0d @%0d",
                     slot, pwrite ? "WR" : "RD", paddr, pstrb, pwdata, prdata, waits, cyc);
  endfunction
endclass

// uart_rx_frame: a byte the bench serialized onto uart_rx (complete frame).
class uart_rx_frame extends uvm_sequence_item;
  bit [7:0] data;
  `uvm_object_utils(uart_rx_frame)
  function new(string name = "uart_rx_frame");
    super.new(name);
  endfunction
endclass
