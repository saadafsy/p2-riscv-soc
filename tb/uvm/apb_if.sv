`timescale 1ns / 1ps
// apb_if: the APB4 bus between the bridge and the four slaves (observed
// passively), the testbench wait-state request, and the peripheral pins.
// pready is the per-slot vector the bridge sees (slave pready AND NOT stall).
// sim_* are hierarchical taps of simctrl_apb's exit_seen/exit_code/putc_count.
interface apb_if (
    input logic clk,
    input logic rst
);
  logic [15:0]       psel;
  logic              penable;
  logic              pwrite;
  logic [11:0]       paddr;
  logic [31:0]       pwdata;
  logic [ 3:0]       pstrb;
  logic [ 2:0]       pprot;
  logic [15:0][31:0] prdata;
  logic [15:0]       pready;

  // testbench-driven
  logic              stall = 1'b0;     // 1: hold the ACCESS phase (wait state)
  logic [20:0]       gpio_in = '0;
  logic              uart_rx = 1'b1;   // idle high

  // pins and simctrl taps
  logic [15:0]       gpio_out;
  logic              uart_tx;
  logic              uart_irq;
  logic              irq_timer;
  logic              sim_exit_seen;
  logic [31:0]       sim_exit_code;
  logic [15:0]       sim_putc_count;

  longint unsigned cyc = 0;
  always @(posedge clk) begin
    if (rst) cyc <= 0;
    else cyc <= cyc + 1;
  end

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output stall, gpio_in, uart_rx;
    input cyc;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, psel, penable, pwrite, paddr, pwdata, pstrb, pprot, prdata, pready;
    input gpio_in, gpio_out, uart_tx, uart_irq, irq_timer, cyc;
  endclocking
endinterface
