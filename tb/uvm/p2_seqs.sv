// Sequences on the OBI sequencer.
//   obi_list_seq  directed: plays a prepared list of items
//   obi_rand_seq  constrained-random accesses with knobs:
//                 b2b       force pipe = 1, delay = 0 (back-to-back)
//                 uart_pct  percent of items rewritten to UART DATA writes
//                 rdbias    percent of items rewritten to UART DATA/STATUS reads
//   obi_sweep_seq reads every named register once (end-of-test check)
// Knobs are applied after randomize() by assignment, never as inline
// == constraints on dist variables (Verilator portability).
class obi_list_seq extends uvm_sequence #(obi_item);
  `uvm_object_utils(obi_list_seq)
  obi_item items[$];
  function new(string name = "obi_list_seq");
    super.new(name);
  endfunction
  task body();
    foreach (items[i]) begin
      start_item(items[i]);
      finish_item(items[i]);
    end
  endtask
endclass

function automatic obi_item mk_item(bit we, bit [31:0] addr, bit [3:0] be, bit [31:0] wdata,
                                    int unsigned delay = 1, bit pipe = 0);
  obi_item it = obi_item::type_id::create("dir");
  it.set_addr(addr);
  it.we = we;
  it.be = be;
  it.wdata = wdata;
  it.delay = delay;
  it.pipe = pipe;
  return it;
endfunction

class obi_rand_seq extends uvm_sequence #(obi_item);
  `uvm_object_utils(obi_rand_seq)
  int unsigned n = 1000;
  bit          b2b = 0;
  int unsigned uart_pct = 0;
  int unsigned rdbias = 0;
  function new(string name = "obi_rand_seq");
    super.new(name);
  endfunction
  task body();
    obi_item it;
    for (int unsigned i = 0; i < n; i++) begin
      it = obi_item::type_id::create($sformatf("r%0d", i));
      start_item(it);
      if (!it.randomize()) `uvm_fatal("SEQ", "randomize failed")
      if (b2b) begin
        it.pipe = 1;
        it.delay = 0;
      end
      if (uart_pct != 0 && $urandom_range(99) < uart_pct) begin
        it.kind = K_REG;
        it.slot = 4'd0;
        it.off = 12'h000;
        it.alias_v = 12'd0;
        it.we = 1;
        it.be = 4'b0001;
        it.compose();
      end else if (rdbias != 0 && $urandom_range(99) < rdbias) begin
        it.kind = K_REG;
        it.slot = 4'd0;
        it.off = $urandom_range(1) ? 12'h000 : 12'h004;
        it.alias_v = 12'd0;
        it.we = 0;
        it.compose();
      end
      finish_item(it);
    end
  endtask
endclass

class obi_sweep_seq extends uvm_sequence #(obi_item);
  `uvm_object_utils(obi_sweep_seq)
  function new(string name = "obi_sweep_seq");
    super.new(name);
  endfunction
  task body();
    bit [31:0] regs[] = '{32'h1000_0004, 32'h1000_0008, 32'h1000_000C,
                          32'h1000_1000, 32'h1000_1004, 32'h1000_1008, 32'h1000_100C,
                          32'h1000_2000, 32'h1000_2004, 32'h1000_2008, 32'h1000_200C,
                          32'h1000_F000, 32'h1000_F004};
    obi_item it;
    foreach (regs[i]) begin
      it = mk_item(0, regs[i], 4'b1111, 32'd0, 1, 0);
      start_item(it);
      finish_item(it);
    end
  endtask
endclass
