// Simulation control APB4 slave (spec 8). Reads return 0.
//   0x0 EXIT  W: end the simulation; 0 = pass. A nonzero code ends it through
//             $fatal so the simulator process exits with an error status.
//             Code = pwdata on the pstrb-enabled lanes (others 0); pstrb 0 is no write.
//   0x4 PUTC  W: print the low byte to the console, only when pstrb[0] is set.
// Everything is compiled out under SYNTHESIS, leaving an inert APB slave.
// FINISH_ON_EXIT = 0 keeps the simulation running so a testbench can
// observe exit_seen/exit_code instead.
module simctrl_apb #(
  parameter bit FINISH_ON_EXIT = 1'b1
) (
  input  logic        pclk,
  input  logic        presetn,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic [2:0]  pprot,   // unused (lint waiver: folded into `unused`)
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr
);
  assign prdata  = 32'd0;
  assign pready  = 1'b1;
  assign pslverr = 1'b0;

`ifndef SYNTHESIS
  logic        exit_seen;
  logic [31:0] exit_code;
  logic [15:0] putc_count;
  logic [31:0] wd;
  assign wd = pwdata & {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};

  always_ff @(posedge pclk) begin
    if (!presetn) begin
      exit_seen  <= 1'b0;
      exit_code  <= '0;
      putc_count <= '0;
    end else if (psel && penable && pwrite) begin
      if (paddr[11:2] == 10'h000 && pstrb != 4'b0000) begin
        exit_seen  <= 1'b1;
        exit_code  <= wd;
        if (FINISH_ON_EXIT) begin
          if (wd == 32'd0) begin
            $display("[simctrl] EXIT 0 (pass)");
            $finish;
          end else begin
            $fatal(1, "[simctrl] EXIT %0d (fail)", wd);
          end
        end
      end else if (paddr[11:2] == 10'h001 && pstrb[0]) begin
        putc_count <= putc_count + 16'd1;
        $write("%c", pwdata[7:0]);
        $fflush;
      end
    end
  end

  // Observed by testbenches through the hierarchy.
  logic unused_tb;
  assign unused_tb = ^{exit_seen, exit_code, putc_count};
`endif

  logic unused;
  assign unused = ^{pclk, presetn, psel, penable, pwrite, paddr, pwdata, pstrb, pprot,
                    FINISH_ON_EXIT};
endmodule
