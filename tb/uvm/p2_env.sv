// p2_env: OBI agent (active), APB agent (passive monitor), pin driver
// (wait states, gpio_in), UART RX driver, scoreboard with register model,
// coverage.
class p2_env extends uvm_env;
  `uvm_component_utils(p2_env)
  obi_agent      obi_agt;
  apb_agent      apb_agt;
  pin_driver     pins;
  uart_rx_driver rx_drv;
  p2_scoreboard  sb;
  p2_coverage    cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    obi_agt = obi_agent::type_id::create("obi_agt", this);
    apb_agt = apb_agent::type_id::create("apb_agt", this);
    pins    = pin_driver::type_id::create("pins", this);
    rx_drv  = uart_rx_driver::type_id::create("rx_drv", this);
    sb      = p2_scoreboard::type_id::create("sb", this);
    cov     = p2_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    obi_agt.mon.req_ap.connect(sb.req_imp);
    obi_agt.mon.rsp_ap.connect(sb.rsp_imp);
    obi_agt.mon.req_ap.connect(cov.req_imp);
    apb_agt.mon.ap.connect(sb.apb_imp);
    apb_agt.mon.ap.connect(cov.apb_imp);
    rx_drv.ap.connect(sb.rx_imp);
  endfunction
endclass
