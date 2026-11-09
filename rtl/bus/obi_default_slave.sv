// OBI slave for unmapped addresses (spec 5): grants immediately, responds
// next cycle, reads return 0 and writes are dropped. No trap is raised.
module obi_default_slave (
  input  logic        clk,
  input  logic        rst,
  input  logic        req,
  output logic        gnt,
  output logic        rvalid,
  output logic [31:0] rdata
);
  assign gnt   = req;
  assign rdata = 32'd0;

  always_ff @(posedge clk) begin
    if (rst) rvalid <= 1'b0;
    else     rvalid <= req;
  end
endmodule
