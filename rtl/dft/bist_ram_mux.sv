// 2:1 OBI mux in front of dp_ram port B (spec 13.3). bist_sel = 1 gives the
// port to the MBIST master; the system side then sees no grant and no
// response, so its requests wait. bist_sel must only change while neither
// side has a transaction outstanding: soc_top drives it from mbist busy,
// which rises after the APB write that started the test (the data bus has
// no RAM access in flight then) and falls after the test's last response.
module bist_ram_mux (
  input  logic        bist_sel,
  // system side (obi_decoder RAM port)
  input  logic        sys_req,
  output logic        sys_gnt,
  input  logic [31:0] sys_addr,
  input  logic        sys_we,
  input  logic [3:0]  sys_be,
  input  logic [31:0] sys_wdata,
  output logic        sys_rvalid,
  output logic [31:0] sys_rdata,
  // MBIST side
  input  logic        bist_req,
  output logic        bist_gnt,
  input  logic [31:0] bist_addr,
  input  logic        bist_we,
  input  logic [3:0]  bist_be,
  input  logic [31:0] bist_wdata,
  output logic        bist_rvalid,
  output logic [31:0] bist_rdata,
  // to dp_ram port B
  output logic        ram_req,
  input  logic        ram_gnt,
  output logic [31:0] ram_addr,
  output logic        ram_we,
  output logic [3:0]  ram_be,
  output logic [31:0] ram_wdata,
  input  logic        ram_rvalid,
  input  logic [31:0] ram_rdata
);
  assign ram_req   = bist_sel ? bist_req   : sys_req;
  assign ram_addr  = bist_sel ? bist_addr  : sys_addr;
  assign ram_we    = bist_sel ? bist_we    : sys_we;
  assign ram_be    = bist_sel ? bist_be    : sys_be;
  assign ram_wdata = bist_sel ? bist_wdata : sys_wdata;

  assign sys_gnt     = !bist_sel && ram_gnt;
  assign sys_rvalid  = !bist_sel && ram_rvalid;
  assign bist_gnt    = bist_sel && ram_gnt;
  assign bist_rvalid = bist_sel && ram_rvalid;
  assign sys_rdata   = ram_rdata;
  assign bist_rdata  = ram_rdata;
endmodule
