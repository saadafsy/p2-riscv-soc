// p2_scoreboard: in-order checker of the OBI -> APB -> OBI path against
// p2_reg_model.
//   OBI request  -> queued with the APB transfer it must cause (or none, for
//                   an unpopulated slot: rdata 0 one cycle later).
//   APB transfer -> must match the head request: psel slot = addr[15:12],
//                   paddr = addr[11:0], pwrite = we, pstrb = we ? be : 0,
//                   pwdata = wdata on the be lanes (writes), pprot = 0,
//                   SETUP the edge after the handshake; prdata (reads) and
//                   the pins gpio_out / irq_timer / uart_irq in the ACCESS
//                   cycle must match the model. Then the model applies it.
//   OBI response -> rvalid the edge after the ACCESS (or after the
//                   handshake, unpopulated slot), rdata = predicted read
//                   value, 0 for writes.
// End of test: nothing outstanding, SIMCTRL exit_seen/exit_code/putc_count
// equal the model, and at least one read was checked.
`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_rsp)
`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_rx)

class sb_pend;
  obi_item req;
  bit      mapped;
  bit      apb_done;
  bit [31:0] exp_rdata;
  longint unsigned apb_cyc;
endclass

class p2_scoreboard extends uvm_component;
  `uvm_component_utils(p2_scoreboard)
  uvm_analysis_imp_req #(obi_item, p2_scoreboard) req_imp;
  uvm_analysis_imp_rsp #(obi_item, p2_scoreboard) rsp_imp;
  uvm_analysis_imp_apb #(apb_xfer, p2_scoreboard) apb_imp;
  uvm_analysis_imp_rx  #(uart_rx_frame, p2_scoreboard) rx_imp;
  virtual apb_if avif;

  p2_reg_model model;
  sb_pend pend[$];
  int unsigned n_req, n_apb, n_rsp, n_rd_checked, n_pin_checks, n_rx;
  int unsigned e_apb_fields, e_apb_prdata, e_obi_rdata, e_pins, e_order, e_timing, e_end;
  int unsigned max_print = 20;

  // Model-state coverage (sampled here, where the prediction lives).
  int cv_txn;
  bit cv_drop, cv_clear;
  int cv_rxn;
  bit [3:0] cv_status;
  bit cv_irq_t;
  covergroup cg_model;
    option.per_instance = 1;
    cp_tx_level_on_push: coverpoint cv_txn {
      bins empty = {0};
      bins partial = {[1:15]};
      bins full = {16};
    }
    cp_push_dropped: coverpoint cv_drop { bins dropped = {1}; }
  endgroup
  covergroup cg_status;
    option.per_instance = 1;
    cp_tx_full: coverpoint cv_status[0];
    cp_tx_empty: coverpoint cv_status[1];
    cp_rx_valid: coverpoint cv_status[2];
    cp_overrun: coverpoint cv_status[3];
  endgroup
  covergroup cg_rx;
    option.per_instance = 1;
    cp_rx_level_on_pop: coverpoint cv_rxn {
      bins empty = {0};
      bins partial = {[1:15]};
      bins full = {16};
    }
  endgroup
  covergroup cg_misc;
    option.per_instance = 1;
    cp_overrun_cleared: coverpoint cv_clear { bins cleared = {1}; }
    cp_irq_timer: coverpoint cv_irq_t;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
    apb_imp = new("apb_imp", this);
    rx_imp  = new("rx_imp", this);
    model = new();
    cg_model = new();
    cg_status = new();
    cg_rx = new();
    cg_misc = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual apb_if)::get(this, "", "apb_vif", avif))
      `uvm_fatal("SB", "apb_vif not set")
  endfunction

  function void mismatch(ref int unsigned ctr, input string what);
    ctr++;
    if (e_apb_fields + e_apb_prdata + e_obi_rdata + e_pins + e_order + e_timing + e_end <= max_print)
      `uvm_error("SB_MISMATCH", what)
  endfunction

  function void write_req(obi_item t);
    sb_pend p = new();
    n_req++;
    p.req = t;
    p.mapped = (slot_idx(t.addr[15:12]) >= 0);
    p.exp_rdata = 32'd0;
    p.apb_done = !p.mapped;
    pend.push_back(p);
  endfunction

  function void write_apb(apb_xfer x);
    sb_pend p;
    obi_item r;
    bit [31:0] mask, exp_pw, exp_rd;
    bit exp_it, exp_iu;
    n_apb++;
    if (pend.size() == 0 || pend[0].apb_done) begin
      mismatch(e_order, $sformatf("APB transfer with no pending OBI request: %s", x.convert2string()));
      return;
    end
    p = pend[0];
    r = p.req;
    mask = {{8{r.be[3]}}, {8{r.be[2]}}, {8{r.be[1]}}, {8{r.be[0]}}};
    exp_pw = r.wdata & mask;
    if (x.slot != int'(r.addr[15:12]) || x.paddr != r.addr[11:0] || x.pwrite != r.we ||
        x.pstrb != (r.we ? r.be : 4'b0000) || x.pprot != 3'b000 || (r.we && x.pwdata != exp_pw))
      mismatch(e_apb_fields, $sformatf("APB fields: got %s, OBI %s (exp pstrb=%b pwdata=%08h)",
               x.convert2string(), r.convert2string(), r.we ? r.be : 4'b0000, exp_pw));
    if (x.setup_cyc != r.cyc + 1)
      mismatch(e_timing, $sformatf("SETUP at %0d, expected handshake+1 = %0d", x.setup_cyc, r.cyc + 1));
    // pins in the ACCESS cycle, before the access acts
    model.advance(x.cyc);
    exp_it = model.exp_irq_timer(x.cyc);
    exp_iu = model.exp_uart_irq();
    n_pin_checks++;
    if (x.gpio_out != model.gpio_out || x.irq_timer != exp_it || x.uart_irq != exp_iu)
      mismatch(e_pins, $sformatf("pins @%0d: gpio_out %04h/%04h irq_timer %0d/%0d uart_irq %0d/%0d (dut/model)",
               x.cyc, x.gpio_out, model.gpio_out, x.irq_timer, exp_it, x.uart_irq, exp_iu));
    // model-state coverage, pre-access
    if (x.slot == 0 && x.paddr[11:4] == 0 && x.paddr[3:2] == 2'd0) begin
      if (r.we && r.be[0]) begin
        cv_txn = model.txn;
        cv_drop = (model.txn == 16);
        cg_model.sample();
      end
      if (!r.we) begin
        cv_rxn = model.rxq.size();
        cg_rx.sample();
      end
    end
    cv_irq_t = exp_it;
    // predict with the request's lanes (what the bridge must have put on
    // the bus), so a wrong pstrb/pwdata also shows up as wrong state later
    exp_rd = model.access(int'(r.addr[15:12]), r.addr[11:0], r.we, r.we ? r.be : 4'b0000,
                          exp_pw, x.cyc, x.in_d2);
    cv_clear = model.last_ovr_clear;
    cg_misc.sample();
    if (!r.we) begin
      n_rd_checked++;
      if (x.prdata != exp_rd)
        mismatch(e_apb_prdata, $sformatf("prdata %s @%0d: dut %08h model %08h",
                 reg_name(r.reg_id()), x.cyc, x.prdata, exp_rd));
      if (r.reg_id() == 1) begin
        cv_status = exp_rd[3:0];
        cg_status.sample();
      end
    end
    p.exp_rdata = exp_rd;
    p.apb_done = 1;
    p.apb_cyc = x.cyc;
  endfunction

  function void write_rsp(obi_item t);
    sb_pend p;
    longint unsigned exp_c;
    n_rsp++;
    if (pend.size() == 0) begin
      mismatch(e_order, $sformatf("OBI rvalid with nothing outstanding: %s", t.convert2string()));
      return;
    end
    p = pend.pop_front();
    if (!p.apb_done) begin
      mismatch(e_order, $sformatf("OBI rvalid before the APB transfer of %s", p.req.convert2string()));
      return;
    end
    exp_c = p.mapped ? p.apb_cyc + 1 : p.req.cyc + 1;
    if (t.cyc != exp_c)
      mismatch(e_timing, $sformatf("rvalid at %0d, expected %0d for %s", t.cyc, exp_c, p.req.convert2string()));
    if (t.rdata != p.exp_rdata)
      mismatch(e_obi_rdata, $sformatf("OBI rdata %s: dut %08h model %08h",
               p.req.convert2string(), t.rdata, p.exp_rdata));
  endfunction

  function void write_rx(uart_rx_frame f);
    n_rx++;
    model.rx_frame(f.data);
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pend.size() != 0)
      mismatch(e_end, $sformatf("%0d OBI transactions still outstanding at end", pend.size()));
    if (avif.sim_exit_seen !== model.exit_seen || avif.sim_exit_code !== model.exit_code ||
        avif.sim_putc_count !== model.putc_count)
      mismatch(e_end, $sformatf("SIMCTRL exit_seen/exit_code/putc_count dut %0d/%08h/%0d model %0d/%08h/%0d",
               avif.sim_exit_seen, avif.sim_exit_code, avif.sim_putc_count,
               model.exit_seen, model.exit_code, model.putc_count));
    if (n_rd_checked == 0) mismatch(e_end, "no read was checked: the test proved nothing");
  endfunction

  function void report_phase(uvm_phase phase);
    int unsigned tot = e_apb_fields + e_apb_prdata + e_obi_rdata + e_pins + e_order + e_timing + e_end;
    `uvm_info("SB", $sformatf("checked: obi_req=%0d apb=%0d obi_rsp=%0d reads=%0d pin_checks=%0d rx_frames=%0d tx_pushed=%0d tx_dropped=%0d",
              n_req, n_apb, n_rsp, n_rd_checked, n_pin_checks, n_rx, model.tx_pushed, model.tx_dropped), UVM_NONE)
    `uvm_info("SB", $sformatf("mismatches: total=%0d apb_fields=%0d apb_prdata=%0d obi_rdata=%0d pins=%0d order=%0d timing=%0d end=%0d",
              tot, e_apb_fields, e_apb_prdata, e_obi_rdata, e_pins, e_order, e_timing, e_end), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_model %.1f", cg_model.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_status %.1f", cg_status.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_rx %.1f", cg_rx.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("COVERAGE cg_misc %.1f", cg_misc.get_inst_coverage()), UVM_NONE)
  endfunction
endclass
