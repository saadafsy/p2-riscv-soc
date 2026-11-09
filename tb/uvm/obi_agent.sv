// OBI master agent: sequencer, driver (randomized request timing), monitor.
typedef uvm_sequencer #(obi_item) obi_sequencer;

// obi_driver: one item per OBI transaction. Holds req/addr/we/be/wdata
// stable until gnt (OBI M1). Returns item_done at the handshake, so a
// pipe = 1 item raises req while the previous transaction is still in its
// APB phases and is granted in the rvalid cycle (zero-gap back-to-back).
class obi_driver extends uvm_driver #(obi_item);
  `uvm_component_utils(obi_driver)
  virtual obi_if vif;
  int unsigned n_hs = 0;   // handshakes
  int unsigned n_rsp = 0;  // rvalids

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual obi_if)::get(this, "", "obi_vif", vif))
      `uvm_fatal("DRV", "obi_vif not set")
  endfunction

  task track_rsp();
    forever begin
      @(vif.drv_cb);
      if (vif.drv_cb.rvalid) n_rsp++;
    end
  endtask

  // Blocks until every granted transaction has its rvalid.
  task wait_idle();
    while (n_rsp < n_hs) @(vif.drv_cb);
  endtask

  task run_phase(uvm_phase phase);
    vif.drv_cb.req <= 1'b0;
    while (vif.rst !== 1'b0) @(vif.drv_cb);
    fork
      track_rsp();
    join_none
    forever begin
      seq_item_port.get_next_item(req);
      if (!req.pipe) begin
        while (n_rsp < n_hs) @(vif.drv_cb);
        repeat (req.delay) @(vif.drv_cb);
      end
      vif.drv_cb.req   <= 1'b1;
      vif.drv_cb.addr  <= req.addr;
      vif.drv_cb.we    <= req.we;
      vif.drv_cb.be    <= req.be;
      vif.drv_cb.wdata <= req.wdata;
      forever begin
        @(vif.drv_cb);
        if (vif.drv_cb.gnt) break;
`ifdef INJECT_BUG_OBI
        // bench bug: wdata changes while waiting for gnt (violates OBI M1)
        vif.drv_cb.wdata <= ~req.wdata;
`endif
      end
      n_hs++;
      vif.drv_cb.req <= 1'b0;
      seq_item_port.item_done();
    end
  endtask
endclass

// obi_monitor: publishes every handshake on req_ap (with gnt wait and the
// gap since the previous rvalid) and every rvalid on rsp_ap. A response is
// written before a request seen on the same edge (in-order matching).
class obi_monitor extends uvm_monitor;
  `uvm_component_utils(obi_monitor)
  virtual obi_if vif;
  uvm_analysis_port #(obi_item) req_ap;
  uvm_analysis_port #(obi_item) rsp_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_ap = new("req_ap", this);
    rsp_ap = new("rsp_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual obi_if)::get(this, "", "obi_vif", vif))
      `uvm_fatal("MON", "obi_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    longint unsigned c, req_start = 0, last_rsp = 0;
    bit req_pending = 0, have_rsp = 0;
    obi_item t;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rst) begin
        req_pending = 0;
        have_rsp = 0;
        continue;
      end
      c = vif.mon_cb.cyc;
      if (vif.mon_cb.rvalid) begin
        t = obi_item::type_id::create("rsp");
        t.is_rsp = 1;
        t.rdata = vif.mon_cb.rdata;
        t.cyc = c;
        rsp_ap.write(t);
        last_rsp = c;
        have_rsp = 1;
      end
      if (vif.mon_cb.req && !req_pending) begin
        req_pending = 1;
        req_start = c;
      end
      if (vif.mon_cb.req && vif.mon_cb.gnt) begin
        t = obi_item::type_id::create("req");
        t.set_addr(vif.mon_cb.addr);
        t.we = vif.mon_cb.we;
        t.be = vif.mon_cb.be;
        t.wdata = vif.mon_cb.wdata;
        t.cyc = c;
        t.gnt_wait = int'(c - req_start);
        t.first = !have_rsp;
        t.gap = have_rsp ? int'(c - last_rsp) : 0;
        req_ap.write(t);
        req_pending = 0;
      end
    end
  endtask
endclass

class obi_agent extends uvm_agent;
  `uvm_component_utils(obi_agent)
  obi_sequencer sqr;
  obi_driver    drv;
  obi_monitor   mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = obi_sequencer::type_id::create("sqr", this);
    drv = obi_driver::type_id::create("drv", this);
    mon = obi_monitor::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// apb_monitor: passive. Tracks SETUP -> ACCESS (+waits) on the one-hot
// psel bus and publishes each transfer at its completing ACCESS edge.
class apb_monitor extends uvm_monitor;
  `uvm_component_utils(apb_monitor)
  virtual apb_if vif;
  uvm_analysis_port #(apb_xfer) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", vif))
      `uvm_fatal("APBMON", "apb_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    bit [20:0] h1 = '0, h2 = '0;   // gpio_in sampled 1 and 2 edges ago
    longint unsigned setup_cyc = 0;
    int unsigned waits = 0;
    int s;
    apb_xfer x;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rst) begin
        h1 = '0;
        h2 = '0;
        continue;
      end
      if (vif.mon_cb.psel != 16'd0) begin
        s = 0;
        for (int i = 0; i < 16; i++) if (vif.mon_cb.psel[i]) s = i;
        if (!vif.mon_cb.penable) begin
          setup_cyc = vif.mon_cb.cyc;
          waits = 0;
        end else if (!vif.mon_cb.pready[s]) begin
          waits++;
        end else begin
          x = apb_xfer::type_id::create("x");
          x.slot      = s;
          x.paddr     = vif.mon_cb.paddr;
          x.pwrite    = vif.mon_cb.pwrite;
          x.pwdata    = vif.mon_cb.pwdata;
          x.pstrb     = vif.mon_cb.pstrb;
          x.pprot     = vif.mon_cb.pprot;
          x.prdata    = vif.mon_cb.prdata[s];
          x.cyc       = vif.mon_cb.cyc;
          x.setup_cyc = setup_cyc;
          x.waits     = waits;
          x.gpio_out  = vif.mon_cb.gpio_out;
          x.irq_timer = vif.mon_cb.irq_timer;
          x.uart_irq  = vif.mon_cb.uart_irq;
          x.in_d2     = h2;
          ap.write(x);
        end
      end
      h2 = h1;
      h1 = vif.mon_cb.gpio_in;
    end
  endtask
endclass

class apb_agent extends uvm_agent;
  `uvm_component_utils(apb_agent)
  apb_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = apb_monitor::type_id::create("mon", this);
  endfunction
endclass

// pin_driver: per-cycle wait-state requests (stall with wait_pct percent
// probability) and slowly changing gpio_in (new random value with
// probability 1/gpio_period per cycle).
class pin_driver extends uvm_component;
  `uvm_component_utils(pin_driver)
  virtual apb_if vif;
  int unsigned wait_pct = 0;
  int unsigned gpio_period = 64;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", vif))
      `uvm_fatal("PINS", "apb_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.drv_cb);
      vif.drv_cb.stall <= ($urandom_range(99) < wait_pct);
      if (gpio_period != 0 && $urandom_range(gpio_period - 1) == 0)
        vif.drv_cb.gpio_in <= 21'($urandom);
    end
  endtask
endclass

// uart_rx_driver: serializes 8N1 frames onto uart_rx at a given divisor
// (clock cycles per bit) and, once all frames and the receiver's sampling
// latency are over, publishes each byte on ap for the predictor. Callers
// must keep the OBI port idle while send() runs (rx timing is not modeled
// cycle by cycle; the predictor applies the frames as a batch afterwards).
class uart_rx_driver extends uvm_component;
  `uvm_component_utils(uart_rx_driver)
  virtual apb_if vif;
  uvm_analysis_port #(uart_rx_frame) ap;
  int unsigned n_sent = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", vif))
      `uvm_fatal("RXDRV", "apb_vif not set")
  endfunction

  task send(bit [7:0] bytes[$], int unsigned div);
    bit [9:0] f;
    uart_rx_frame fr;
    foreach (bytes[k]) begin
      f = {1'b1, bytes[k], 1'b0};  // stop, data LSB first, start
      for (int b = 0; b < 10; b++) begin
        vif.drv_cb.uart_rx <= f[b];
        repeat (div) @(vif.drv_cb);
      end
      repeat (div) @(vif.drv_cb);  // idle gap
    end
    vif.drv_cb.uart_rx <= 1'b1;
    repeat (2 * div + 8) @(vif.drv_cb);
    foreach (bytes[k]) begin
      fr = uart_rx_frame::type_id::create("fr");
      fr.data = bytes[k];
      ap.write(fr);
      n_sent++;
    end
  endtask
endclass
