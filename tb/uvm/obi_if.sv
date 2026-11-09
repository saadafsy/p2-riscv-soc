`timescale 1ns / 1ps
// obi_if: OBI master-side interface for the APB subsystem UVM bench.
// drv_cb drives 1 ns after the edge, mon_cb samples just before it, so
// neither races the DUT. cyc counts non-reset edges; at edge N the sampled
// cyc is N (the edges before it), the same counter apb_if keeps, so both
// monitors stamp transactions on one time base.
interface obi_if (
    input logic clk,
    input logic rst
);
  logic        req = 1'b0;
  logic        gnt;
  logic [31:0] addr = '0;
  logic        we = 1'b0;
  logic [ 3:0] be = '0;
  logic [31:0] wdata = '0;
  logic        rvalid;
  logic [31:0] rdata;

  longint unsigned cyc = 0;
  always @(posedge clk) begin
    if (rst) cyc <= 0;
    else cyc <= cyc + 1;
  end

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output req, addr, we, be, wdata;
    input gnt, rvalid, rdata, cyc;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, req, gnt, addr, we, be, wdata, rvalid, rdata, cyc;
  endclocking
endinterface
