// Protocol checkers from rtl/bus, bound into the DUT wrapper so they run in
// every test (compiled with --assert). obi_checker watches the OBI port the
// UVM driver talks to; apb_checker watches the APB bus as the bridge drives
// and sees it (m_pready includes injected wait states).
bind apb_sub_wrap obi_checker u_obi_chk (
  .clk(clk), .rst(rst), .req(req), .gnt(gnt), .addr(addr), .we(we), .be(be),
  .wdata(wdata), .rvalid(rvalid)
);

bind apb_sub_wrap apb_checker #(.NSEL(16), .AW(12)) u_apb_chk (
  .clk(clk), .rst(rst), .psel(m_psel), .penable(m_penable), .pwrite(m_pwrite),
  .paddr(m_paddr), .pwdata(m_pwdata), .pstrb(m_pstrb), .pprot(m_pprot), .pready(m_pready)
);
