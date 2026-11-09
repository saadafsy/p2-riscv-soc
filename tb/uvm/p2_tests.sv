// Tests (select with +UVM_TESTNAME):
//   p2_smoke_test   directed: reset values, every strobe pattern on R/W
//                   registers, OUT_SET/OUT_CLR, TX FIFO fill past 16,
//                   timer writes and compare irq, SIMCTRL EXIT/PUTC,
//                   unmapped offsets and slot, UART RX + overrun + W1C.
//   p2_random_test  constrained-random accesses with random timing and 25%
//                   wait-state probability, a UART RX burst (1..20 bytes,
//                   so overrun is reachable), more random traffic biased to
//                   UART DATA/STATUS reads, then a read sweep.
//                   +NUM_TXN=<n> (default 3000)
//   p2_stress_test  back-to-back only (pipe = 1, delay = 0): first with no
//                   wait states, then 60% wait states, UART DATA-heavy so
//                   the TX FIFO runs full. +NUM_TXN=<n> (default 4000)
// Every test ends with drain + sweep; tb_top turns any UVM error into $fatal.
class p2_base_test extends uvm_test;
  `uvm_component_utils(p2_base_test)
  p2_env env;
  int unsigned num_txn;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = p2_env::type_id::create("env", this);
  endfunction

  task drain();
    env.obi_agt.drv.wait_idle();
    repeat (4) @(env.obi_agt.drv.vif.drv_cb);
  endtask

  task play(obi_item items[$]);
    obi_list_seq s = obi_list_seq::type_id::create("list");
    s.items = items;
    s.start(env.obi_agt.sqr);
  endtask

  task wr(bit [31:0] a, bit [3:0] be, bit [31:0] d);
    obi_item q[$];
    q.push_back(mk_item(1, a, be, d));
    play(q);
  endtask

  task rd(bit [31:0] a, bit [3:0] be = 4'b1111);
    obi_item q[$];
    q.push_back(mk_item(0, a, be, 32'hDEAD_BEEF));
    play(q);
  endtask

  task sweep();
    obi_sweep_seq s = obi_sweep_seq::type_id::create("sweep");
    s.start(env.obi_agt.sqr);
  endtask

  task rx_burst(int unsigned nbytes, bit [15:0] div);
    bit [7:0] b[$];
    wr(32'h1000_0008, 4'b1111, {16'd0, div});
    drain();
    for (int i = 0; i < nbytes; i++) b.push_back(8'($urandom));
    env.rx_drv.send(b, (div < 2) ? 2 : div);
  endtask

  virtual task body();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    while (env.obi_agt.drv.vif.rst !== 1'b0) @(env.obi_agt.drv.vif.drv_cb);
    repeat (2) @(env.obi_agt.drv.vif.drv_cb);
    body();
    drain();
    sweep();
    drain();
    phase.drop_objection(this);
  endtask
endclass

class p2_smoke_test extends p2_base_test;
  `uvm_component_utils(p2_smoke_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task body();
    bit [3:0] pats[7] = '{4'b0001, 4'b0010, 4'b0100, 4'b1000, 4'b0011, 4'b1100, 4'b1111};
    env.pins.wait_pct = 20;
    sweep();                                      // reset values
    foreach (pats[i]) begin                       // GPIO OUT lanes
      wr(32'h1000_1000, pats[i], 32'hA5C3_0000 | (32'h1111 * (i + 1)));
      rd(32'h1000_1000);
    end
    wr(32'h1000_1008, 4'b0001, 32'h0000_00F0);    // OUT_SET low byte
    wr(32'h1000_1008, 4'b0010, 32'h0000_FF00);    // OUT_SET high byte
    wr(32'h1000_100C, 4'b0001, 32'hFFFF_FF0F);    // OUT_CLR low byte only
    rd(32'h1000_100C);
    rd(32'h1000_1004);                            // IN
    foreach (pats[i]) begin                       // TIMER MTIMECMP lanes
      wr(32'h1000_2008 + 4 * (i % 2), pats[i], 32'h0102_0304 * (i + 1));
      rd(32'h1000_2008 + 4 * (i % 2));
    end
    wr(32'h1000_2004, 4'b1111, 32'd0);            // compare low: irq_timer
    wr(32'h1000_200C, 4'b1111, 32'd0);
    wr(32'h1000_2008, 4'b1111, 32'd50);
    wr(32'h1000_2000, 4'b0010, 32'h0000_FF00);    // MTIME_LO byte 1
    rd(32'h1000_2000);
    rd(32'h1000_2004);
    wr(32'h1000_2000, 4'b1111, 32'hFFFF_FFF0);    // carry into MTIME_HI
    repeat (40) @(env.obi_agt.drv.vif.drv_cb);
    rd(32'h1000_2000);
    rd(32'h1000_2004);
    foreach (pats[i]) begin                       // UART DIVISOR / IRQ_EN lanes
      wr(32'h1000_0008, pats[i], 32'h1234_5678 + i);
      rd(32'h1000_0008);
      wr(32'h1000_000C, pats[i], 32'hFFFF_FFFF);
      rd(32'h1000_000C);
      wr(32'h1000_000C, 4'b1111, 32'h0);
    end
    wr(32'h1000_0008, 4'b0011, 32'd868);
    // 20 lane-0 pushes (19 queued after the first pop): 3 dropped when full
    for (int i = 0; i < 24; i++) wr(32'h1000_0000, (i % 6 == 5) ? 4'b0010 : 4'b0001, 32'h40 + i);
    rd(32'h1000_0004);                            // tx_full
    wr(32'h1000_F004, 4'b0001, "O");              // PUTC
    wr(32'h1000_F004, 4'b0001, "K");
    wr(32'h1000_F004, 4'b0010, 32'h0000_4100);    // lane 1 only: no print
    wr(32'h1000_F004, 4'b0001, 32'h0A);
    wr(32'h1000_F000, 4'b0100, 32'h0012_0000);    // EXIT code on lane 2 only
    rd(32'h1000_F000);
    wr(32'h1000_F000, 4'b1111, 32'd0);            // EXIT 0
    wr(32'h1000_3000, 4'b1111, 32'hFFFF_FFFF);    // unpopulated slot
    rd(32'h1000_3000);
    rd(32'h1000_E004);
    wr(32'h1000_1010, 4'b1111, 32'hFFFF);         // unmapped offset in GPIO
    rd(32'h1000_1010);
    rd(32'h1000_0FFC);
    rd(32'h1ABC_1000);                            // alias of GPIO OUT
    // UART RX: 3 bytes, read them, then 18 bytes -> overrun, W1C clear
    wr(32'h1000_0008, 4'b1111, 32'd4);            // drain TX fast
    repeat (900) @(env.obi_agt.drv.vif.drv_cb);
    wr(32'h1000_000C, 4'b0001, 32'd1);
    rx_burst(3, 16);
    rd(32'h1000_0004);
    for (int i = 0; i < 4; i++) rd(32'h1000_0000);
    rx_burst(18, 8);
    rd(32'h1000_0004);
    wr(32'h1000_0004, 4'b0010, 32'h0000_0808);    // lane 1 only: no clear
    rd(32'h1000_0004);
    wr(32'h1000_0004, 4'b0001, 32'h0000_0008);    // W1C
    rd(32'h1000_0004);
    for (int i = 0; i < 17; i++) rd(32'h1000_0000);
  endtask
endclass

class p2_random_test extends p2_base_test;
  `uvm_component_utils(p2_random_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task body();
    obi_rand_seq s;
    if (!$value$plusargs("NUM_TXN=%d", num_txn)) num_txn = 3000;
    env.pins.wait_pct = 25;
    wr(32'h1000_0008, 4'b0011, 32'd3);  // fast TX before any byte is queued
    s = obi_rand_seq::type_id::create("rand1");
    s.n = num_txn * 2 / 3;
    s.start(env.obi_agt.sqr);
    drain();
    rx_burst($urandom_range(20, 1), 16'($urandom_range(24, 4)));
    s = obi_rand_seq::type_id::create("rand2");
    s.n = num_txn / 3;
    s.rdbias = 20;
    s.start(env.obi_agt.sqr);
  endtask
endclass

class p2_stress_test extends p2_base_test;
  `uvm_component_utils(p2_stress_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task body();
    obi_rand_seq s;
    if (!$value$plusargs("NUM_TXN=%d", num_txn)) num_txn = 4000;
    env.pins.wait_pct = 0;
    wr(32'h1000_0008, 4'b0011, 32'd3);  // fast TX before any byte is queued
    s = obi_rand_seq::type_id::create("b2b_nowait");
    s.n = num_txn / 2;
    s.b2b = 1;
    s.uart_pct = 30;
    s.start(env.obi_agt.sqr);
    env.pins.wait_pct = 60;
    s = obi_rand_seq::type_id::create("b2b_wait");
    s.n = num_txn / 2;
    s.b2b = 1;
    s.uart_pct = 30;
    s.start(env.obi_agt.sqr);
  endtask
endclass
