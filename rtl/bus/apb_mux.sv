// APB response mux: AND-OR select of prdata/pready by the one-hot psel.
// With no slot selected the result is 0 / not ready.
module apb_mux #(
  parameter int NSLV = 16
) (
  input  logic [NSLV-1:0]       psel,
  input  logic [NSLV-1:0][31:0] prdata,
  input  logic [NSLV-1:0]       pready,
  output logic [31:0]           prdata_sel,
  output logic                  pready_sel
);
  always_comb begin
    prdata_sel = '0;
    for (int i = 0; i < NSLV; i++) begin
      prdata_sel = prdata_sel | (prdata[i] & {32{psel[i]}});
    end
  end

  assign pready_sel = |(psel & pready);
endmodule
