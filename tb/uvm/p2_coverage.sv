// p2_coverage: functional coverage of observed OBI requests and APB transfers.
//   cg_access  register (14 named) x access type x strobe pattern (7 legal),
//              plus unmapped offsets per peripheral / unmapped slot x access,
//              address aliases (addr[27:16] != 0) and sub-word addr[1:0].
//   cg_b2b     gap from the previous rvalid to the handshake (0 = back to
//              back) x direction pair (RR/RW/WR/WW), same/different slave,
//              and R->W / W->R transitions.
//   cg_gnt     cycles req waited for gnt.
//   cg_wait    APB wait states per transfer x peripheral x direction.
class p2_coverage extends uvm_component;
  `uvm_component_utils(p2_coverage)
  uvm_analysis_imp_req #(obi_item, p2_coverage) req_imp;
  uvm_analysis_imp_apb #(apb_xfer, p2_coverage) apb_imp;

  int rid;
  bit we;
  bit [3:0] be;
  bit alias_hit, lsb_hit;
  int unsigned gap, gnt_wait, waits;
  bit [1:0] dir;
  bit same_slave;
  int pidx;
  bit pwr;
  bit have_prev = 0;
  bit prev_we;
  bit [3:0] prev_slot;

  covergroup cg_access;
    option.per_instance = 1;
    cp_reg: coverpoint rid {
      bins uart_data = {0};
      bins uart_status = {1};
      bins uart_divisor = {2};
      bins uart_irq_en = {3};
      bins gpio_out = {4};
      bins gpio_in = {5};
      bins gpio_out_set = {6};
      bins gpio_out_clr = {7};
      bins timer_mtime_lo = {8};
      bins timer_mtime_hi = {9};
      bins timer_mtimecmp_lo = {10};
      bins timer_mtimecmp_hi = {11};
      bins sim_exit = {12};
      bins sim_putc = {13};
    }
    cp_rw: coverpoint we { bins rd = {0}; bins wr = {1}; }
    cp_be: coverpoint be {
      bins b0 = {4'b0001};
      bins b1 = {4'b0010};
      bins b2 = {4'b0100};
      bins b3 = {4'b1000};
      bins h0 = {4'b0011};
      bins h1 = {4'b1100};
      bins w  = {4'b1111};
    }
    cx_reg_rw_be: cross cp_reg, cp_rw, cp_be;
    cp_unmapped: coverpoint rid {
      bins uart_off = {14};
      bins gpio_off = {15};
      bins timer_off = {16};
      bins sim_off = {17};
      bins no_slave = {18};
    }
    cx_unmapped_rw: cross cp_unmapped, cp_rw;
    cp_alias: coverpoint alias_hit { bins aliased = {1}; }  // 'alias' is a keyword
    cp_lsb: coverpoint lsb_hit { bins nonzero_addr_lsbs = {1}; }
  endgroup

  covergroup cg_b2b;
    option.per_instance = 1;
    cp_gap: coverpoint gap {
      bins back_to_back = {0};
      bins one = {1};
      bins short_2_4 = {[2:4]};
      bins long_5plus = {[5:$]};
    }
    cp_dir: coverpoint dir { bins rr = {2'b00}; bins rw = {2'b01}; bins wr = {2'b10}; bins ww = {2'b11}; }
    cx_gap_dir: cross cp_gap, cp_dir;
    cp_same: coverpoint same_slave { bins same = {1}; bins other = {0}; }
    cx_gap_same: cross cp_gap, cp_same;
    cp_we_trans: coverpoint we { bins r_to_w = (0 => 1); bins w_to_r = (1 => 0); bins w_to_w = (1 => 1); }
  endgroup

  covergroup cg_gnt;
    option.per_instance = 1;
    // obi2apb grants only in IDLE or RESP: a request raised during a mapped
    // transfer waits SETUP + ACCESS (2) plus APB waits; 1 is unreachable.
    cp_gnt_wait: coverpoint gnt_wait {
      bins immediate = {0};
      bins two = {2};
      bins three = {3};
      bins four_plus = {[4:$]};
      ignore_bins unreachable_one = {1};
    }
  endgroup

  covergroup cg_wait;
    option.per_instance = 1;
    cp_waits: coverpoint waits {
      bins none = {0};
      bins one = {1};
      bins two = {2};
      bins three_plus = {[3:$]};
    }
    cp_periph: coverpoint pidx { bins uart = {0}; bins gpio = {1}; bins timer = {2}; bins simctrl = {3}; }
    cp_pwrite: coverpoint pwr;
    cx_wait_periph_dir: cross cp_waits, cp_periph, cp_pwrite;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    apb_imp = new("apb_imp", this);
    cg_access = new();
    cg_b2b = new();
    cg_gnt = new();
    cg_wait = new();
  endfunction

  function void write_req(obi_item t);
    rid = t.reg_id();
    we = t.we;
    be = t.be;
    alias_hit = (t.addr[27:16] != 12'd0);
    lsb_hit = (t.addr[1:0] != 2'd0);
    cg_access.sample();
    gnt_wait = t.gnt_wait;
    cg_gnt.sample();
    if (have_prev && !t.first) begin
      gap = t.gap;
      dir = {prev_we, t.we};
      same_slave = (prev_slot == t.addr[15:12]);
      cg_b2b.sample();
    end
    have_prev = 1;
    prev_we = t.we;
    prev_slot = t.addr[15:12];
  endfunction

  function void write_apb(apb_xfer x);
    waits = x.waits;
    pidx = slot_idx(4'(x.slot));
    pwr = x.pwrite;
    cg_wait.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("COVERAGE cg_access %.1f", cg_access.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_access.cx_reg_rw_be %.1f", cg_access.cx_reg_rw_be.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_b2b %.1f", cg_b2b.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_gnt %.1f", cg_gnt.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_wait %.1f", cg_wait.get_inst_coverage()), UVM_NONE)
  endfunction
endclass
