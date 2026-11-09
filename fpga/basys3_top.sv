`timescale 1ns / 1ps
// basys3_top: soc_top on the Digilent Basys 3. 100 MHz board clock drives the
// SoC directly (CLK_HZ must match). btnC is the reset; the other four buttons
// and the 16 switches are GPIO inputs, the 16 LEDs are GPIO outputs, and the
// USB-UART bridge is the SoC UART at 115200 baud.
module basys3_top #(
    // verilog_lint: waive explicit-parameter-storage-type
    parameter     INIT_FILE = "firmware.hex",
    parameter int CLK_HZ    = 100_000_000
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

  // Reset: synchronize the button, then hold reset for 16 cycles after release
  // so every block sees a clean synchronous reset.
  logic [1:0] btn_sync;
  logic [3:0] rst_cnt;
  logic       rst;

  always_ff @(posedge clk100) begin
    btn_sync <= {btn_sync[0], btn_c};
    if (btn_sync[1]) begin
      rst_cnt <= '0;
      rst     <= 1'b1;
    end else if (rst_cnt != 4'hF) begin
      rst_cnt <= rst_cnt + 4'd1;
      rst     <= 1'b1;
    end else begin
      rst <= 1'b0;
    end
  end

  soc_top #(
      .INIT_FILE     (INIT_FILE),
      .FINISH_ON_EXIT(1'b0),
      .UART_DIV      (UartDiv)
  ) u_soc (
      .clk     (clk100),
      .rst     (rst),
      .uart_rx (uart_rx),
      .uart_tx (uart_tx),
      .gpio_in ({btn_d, btn_r, btn_l, btn_u, btn_c, sw}),
      .gpio_out(led)
  );

endmodule
