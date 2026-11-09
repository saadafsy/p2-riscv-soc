// p2_uvm_pkg: APB peripheral subsystem UVM environment, in dependency order.
package p2_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "obi_item.sv"
  `include "obi_agent.sv"
  `include "p2_reg_model.sv"
  `include "p2_scoreboard.sv"
  `include "p2_coverage.sv"
  `include "p2_seqs.sv"
  `include "p2_env.sv"
  `include "p2_tests.sv"
endpackage
