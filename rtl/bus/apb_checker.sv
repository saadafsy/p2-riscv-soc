// APB4 master-side protocol checker for a bus with a one-hot psel vector.
// Same style as obi_checker: clocked immediate assertions over history
// registers, valid in Verilator (--assert) and SymbiYosys. ASSUME_M turns
// the rules into assumptions when the master is a free formal input.
//   A1 psel is one-hot or zero
//   A2 penable only with a psel
//   A3 a SETUP cycle (psel, !penable) is followed by ACCESS on the same psel
//   A4 penable only after a SETUP cycle or a waited ACCESS cycle
//   A5 psel, paddr, pwrite, pwdata (writes) stable from SETUP until pready
//   A6 ACCESS without pready stays in ACCESS
//   A7 penable drops after the completing ACCESS cycle
//   A8 pstrb and pprot stable from SETUP until pready
//   A9 pstrb is 0 during a read transfer
// pready is the per-slot vector; the selected slot's bit is what counts.
module apb_checker #(
  parameter int NSEL     = 16,
  parameter int AW       = 12,
  parameter bit ASSUME_M = 1'b0
) (
  input logic            clk,
  input logic            rst,
  input logic [NSEL-1:0] psel,
  input logic            penable,
  input logic            pwrite,
  input logic [AW-1:0]   paddr,
  input logic [31:0]     pwdata,
  input logic [3:0]      pstrb,
  input logic [2:0]      pprot,
  input logic [NSEL-1:0] pready
);
  logic [NSEL-1:0] psel_q;
  logic            penable_q, pwrite_q, rdy_q;
  logic [AW-1:0]   paddr_q;
  logic [31:0]     pwdata_q;
  logic [3:0]      pstrb_q;
  logic [2:0]      pprot_q;
  logic            rdy;

  assign rdy = |(psel & pready);

  always @(posedge clk) begin
    if (rst) begin
      psel_q    <= '0;
      penable_q <= 1'b0;
      pwrite_q  <= 1'b0;
      rdy_q     <= 1'b0;
      paddr_q   <= '0;
      pwdata_q  <= '0;
      pstrb_q   <= '0;
      pprot_q   <= '0;
    end else begin
      psel_q    <= psel;
      penable_q <= penable;
      pwrite_q  <= pwrite;
      rdy_q     <= rdy;
      paddr_q   <= paddr;
      pwdata_q  <= pwdata;
      pstrb_q   <= pstrb;
      pprot_q   <= pprot;
    end
  end

  logic sel_q, setup_q, wait_q, done_q;
  assign sel_q   = |psel_q;
  assign setup_q = sel_q && !penable_q;
  assign wait_q  = penable_q && !rdy_q;
  assign done_q  = penable_q && rdy_q;

  logic in_xfer;  // this cycle continues a transfer that started earlier
  assign in_xfer = sel_q && !done_q;

  logic [8:0] ok;
  assign ok[0] = (psel & (psel - 1'b1)) == '0;
  assign ok[1] = !penable || |psel;
  assign ok[2] = !setup_q || (penable && psel == psel_q);
  assign ok[3] = !penable || setup_q || wait_q;
  assign ok[4] = !in_xfer ||
                 (psel == psel_q && paddr == paddr_q && pwrite == pwrite_q &&
                  (!pwrite_q || pwdata == pwdata_q));
  assign ok[5] = !wait_q || penable;
  assign ok[6] = !done_q || !penable;
  assign ok[7] = !in_xfer || (pstrb == pstrb_q && pprot == pprot_q);
  assign ok[8] = !(|psel && !pwrite) || pstrb == 4'b0000;

  generate
    if (ASSUME_M) begin : g_assume
      always @(posedge clk) begin
        if (!rst) begin
          apb_a1_onehot: assume (ok[0]);
          apb_a2_en_sel: assume (ok[1]);
          apb_a3_setup_access: assume (ok[2]);
          apb_a4_en_after_setup: assume (ok[3]);
          apb_a5_stable: assume (ok[4]);
          apb_a6_wait: assume (ok[5]);
          apb_a7_end: assume (ok[6]);
          apb_a8_strb_prot_stable: assume (ok[7]);
          apb_a9_strb_read_zero: assume (ok[8]);
        end
      end
    end else begin : g_assert
      always @(posedge clk) begin
        if (!rst) begin
          apb_a1_onehot: assert (ok[0]);
          apb_a2_en_sel: assert (ok[1]);
          apb_a3_setup_access: assert (ok[2]);
          apb_a4_en_after_setup: assert (ok[3]);
          apb_a5_stable: assert (ok[4]);
          apb_a6_wait: assert (ok[5]);
          apb_a7_end: assert (ok[6]);
          apb_a8_strb_prot_stable: assert (ok[7]);
          apb_a9_strb_read_zero: assert (ok[8]);
        end
      end
    end
  endgenerate

`ifndef FORMAL
  logic [8:0] fired;
  always @(posedge clk) begin
    if (rst) fired <= '0;
    else fired <= fired | ~ok;
  end
`endif
endmodule
