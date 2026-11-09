`timescale 1ns / 1ps
// basys3_top: soc_top on the Digilent Basys 3. One MMCM (VCO = 100 MHz * 10)
// makes both clocks: the SoC at 1000 / 16 = 62.5 MHz (CLK_HZ must match) and
// the accelerator at 1000 / 20 = 50 MHz. The design treats them as unrelated
// (the CDC FIFOs assume nothing). The SoC is below its 100 MHz ASIC target
// because the FPGA route of the load-to-branch path closes at about 75 MHz.
// btnC is the reset; both domains stay in reset until the MMCM locks. The
// other four buttons and the 16 switches are GPIO inputs, the 16 LEDs are
// GPIO outputs, and the USB-UART bridge is the SoC UART at 115200 baud. The
// JTAG debug master is on the USB-JTAG cable through BSCANE2 (USER4); the
// accelerator clock is gated by a BUFGCE inside soc_top (clk_gate).
// ACCEL_EN defaults to 0 here: the full SoC with the attention accelerator
// needs about 20.7k LUTs (openXC7 count), the whole of the XC7A35T's 20,800,
// and does not route. Without it the SoC fits; ACCEL_EN = 1 suits a larger
// part such as the Nexys A7-100T.
module basys3_top #(
    // verilog_lint: waive explicit-parameter-storage-type
    parameter     INIT_FILE = "firmware.hex",
    parameter int CLK_HZ    = 62_500_000,
    parameter bit ACCEL_EN  = 1'b0
) (
    input  logic        clk100,
    input  logic        btn_c,      // reset, active high when pressed
    input  logic        btn_u, btn_l, btn_r, btn_d,
    input  logic [15:0] sw,
    output logic [15:0] led,
    input  logic        uart_rx,
    output logic        uart_tx
);

  localparam logic [15:0] UartDiv = 16'(CLK_HZ / 115200);

  // Clocks.
  logic clk_fb, accel_clk_unbuf, accel_clk, clk_unbuf, clk, locked;

  MMCME2_BASE #(
      .BANDWIDTH        ("OPTIMIZED"),
      .CLKFBOUT_MULT_F  (10.0),  // VCO 1000 MHz
      .CLKFBOUT_PHASE   (0.0),
      .CLKIN1_PERIOD    (10.0),
      .CLKOUT0_DIVIDE_F (20.0),  // 50 MHz
      .CLKOUT0_DUTY_CYCLE(0.5),
      .CLKOUT0_PHASE    (0.0),
      .CLKOUT1_DIVIDE   (16),  // 62.5 MHz
      .CLKOUT2_DIVIDE   (1),
      .CLKOUT3_DIVIDE   (1),
      .CLKOUT4_DIVIDE   (1),
      .CLKOUT5_DIVIDE   (1),
      .CLKOUT6_DIVIDE   (1),
      .CLKOUT4_CASCADE  ("FALSE"),
      .DIVCLK_DIVIDE    (1),
      .REF_JITTER1      (0.010),
      .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
      .CLKIN1   (clk100),
      .CLKFBIN  (clk_fb),
      .CLKFBOUT (clk_fb),
      .CLKFBOUTB(),
      .CLKOUT0  (accel_clk_unbuf),
      .CLKOUT0B (),
      .CLKOUT1  (clk_unbuf),
      .CLKOUT1B (),
      .CLKOUT2  (),
      .CLKOUT2B (),
      .CLKOUT3  (),
      .CLKOUT3B (),
      .CLKOUT4  (),
      .CLKOUT5  (),
      .CLKOUT6  (),
      .LOCKED   (locked),
      .PWRDWN   (1'b0),
      .RST      (1'b0)
  );

  BUFG u_accel_bufg (.I(accel_clk_unbuf), .O(accel_clk));
  BUFG u_soc_bufg (.I(clk_unbuf), .O(clk));

  // SoC reset: synchronize the button, then hold reset for 16 cycles after
  // release (and while the MMCM is unlocked).
  logic [1:0] btn_sync;
  logic [1:0] lock_sync;
  logic [3:0] rst_cnt;
  logic       rst;

  always_ff @(posedge clk) begin
    btn_sync  <= {btn_sync[0], btn_c};
    lock_sync <= {lock_sync[0], locked};
    if (btn_sync[1] || !lock_sync[1]) begin
      rst_cnt <= '0;
      rst     <= 1'b1;
    end else if (rst_cnt != 4'hF) begin
      rst_cnt <= rst_cnt + 4'd1;
      rst     <= 1'b1;
    end else begin
      rst <= 1'b0;
    end
  end

  // Accelerator reset: the SoC reset, synchronized into accel_clk.
  logic [1:0] arst_sync;
  logic       accel_rst;
  always_ff @(posedge accel_clk) arst_sync <= {arst_sync[0], rst};
  assign accel_rst = arst_sync[1];

  // Debug transport reset: power-on only (MMCM lock), never the button, so a
  // btnC press cannot replay or drop a JTAG request (rtl/debug/README.md).
  logic [3:0] dbg_cnt;
  logic       dbg_rst;
  always_ff @(posedge clk) begin
    if (!lock_sync[1]) begin
      dbg_cnt <= '0;
      dbg_rst <= 1'b1;
    end else if (dbg_cnt != 4'hF) begin
      dbg_cnt <= dbg_cnt + 4'd1;
      dbg_rst <= 1'b1;
    end else begin
      dbg_rst <= 1'b0;
    end
  end

  // JTAG goes through BSCANE2 (USER4 on the board's USB-JTAG), so the pin
  // inputs of soc_top are tied off.
  soc_top #(
      .INIT_FILE     (INIT_FILE),
      .FINISH_ON_EXIT(1'b0),
      .UART_DIV      (UartDiv),
      .JTAG_BSCAN    (1'b1),
      .ACCEL_EN      (ACCEL_EN)
  ) u_soc (
      .clk      (clk),
      .rst      (rst),
      .accel_clk(accel_clk),
      .accel_rst(accel_rst),
      .uart_rx  (uart_rx),
      .uart_tx  (uart_tx),
      .gpio_in  ({btn_d, btn_r, btn_l, btn_u, btn_c, sw}),
      .gpio_out (led),
      .dbg_rst  (dbg_rst),
      .tck      (1'b0),
      .trst     (1'b0),
      .tms      (1'b0),
      .tdi      (1'b0),
      .tdo      (),
      .tdo_oe   ()
  );

endmodule
