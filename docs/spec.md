# p2-riscv-soc: specification

A small RISC-V SoC for the Digilent Basys 3 (Artix-7 XC7A35T, 100 MHz
board clock): a 5-stage pipelined RV32IM core with machine-mode CSRs and
interrupts, on-chip RAM, an OBI interconnect, an AMBA APB peripheral bus
(UART, GPIO, timer, simulation control), C firmware built with clang, and
a Python instruction-set simulator as the golden model.

This file is the contract between blocks. If a block needs to deviate,
the spec changes first.

## 1. Conventions

- SystemVerilog, synthesizable, one clock (`clk`) and one synchronous
  active-high reset (`rst`) per block unless stated. Every flop is reset.
  No latches (the one exception is the behavioral clock-gate model,
  section 13.4), no `initial` in RTL (formal-only code under `ifdef FORMAL`).
- Little-endian, byte-addressed, 32-bit words.
- Lint clean with `verilator --lint-only -Wall` and `verible-verilog-lint`
  (100-column lines).
- Comments say why, briefly. No history narration.

## 2. ISA

RV32I base (all 37 user instructions plus FENCE as a no-op), the M
extension, Zicsr, and machine mode only.

M extension (OP opcode 0110011, funct7 = 0000001, funct3 selects): MUL
(000, low 32 bits of rs1 * rs2), MULH (001, high 32 bits, both signed),
MULHSU (010, high 32 bits, rs1 signed, rs2 unsigned), MULHU (011, high
32 bits, both unsigned), DIV (100), DIVU (101), REM (110), REMU (111).
Division rounds toward zero; the remainder has the sign of the dividend.
No M instruction traps. Divide by zero: DIV and DIVU return all ones
(0xFFFF_FFFF), REM and REMU return the dividend. Signed overflow
(rs1 = 0x8000_0000, rs2 = -1): DIV returns 0x8000_0000, REM returns 0.
Other funct7 values on OP are still illegal.

CSRs implemented: `mstatus` (MIE, MPIE; MPP reads as 2'b11), `misa`
(read-only, 0x4000_1100: MXL = 32, I and M), `mie` (MTIE bit 7, MEIE bit 11), `mip` (MTIP, MEIP,
read-only, reflect the irq inputs), `mtvec` (direct mode only, low 2 bits
read as 0), `mscratch`, `mepc` (bit 0 and 1 read as 0), `mcause`, `mtval`,
`mcycle`/`mcycleh`, `minstret`/`minstreth` (writable), read-only shadows
`cycle`/`cycleh`/`instret`/`instreth`, `mhartid` (0), `mvendorid`,
`marchid`, `mimpid` (0). Any other CSR address is an illegal instruction.

Traps (synchronous, take priority in this order): instruction address
misaligned (mcause 0, on a taken branch/jump to a non-4-byte-aligned
target; mtval = target), illegal instruction (2; mtval = instruction
bits), breakpoint EBREAK (3; mtval = 0), load address misaligned (4; mtval
= address), store address misaligned (6), ECALL from M-mode (11; mtval =
0). On a trap: mepc = pc of the trapping instruction, mcause set,
mstatus.MPIE = MIE, MIE = 0, pc = mtvec. MRET: pc = mepc, MIE = MPIE,
MPIE = 1. WFI executes as a no-op.

Interrupts: machine timer (mcause 0x80000007) and machine external
(0x8000000B), taken between instructions when mstatus.MIE and the
matching mie bit and mip bit are all set; external has priority. mepc =
pc of the next instruction that has not retired.

## 3. Core: `rv32_core`

```
module rv32_core #(parameter logic [31:0] RESET_PC = 32'h0000_0000) (
  input  logic        clk, rst,
  // instruction port (OBI, read-only)
  output logic        i_req,   input logic i_gnt,
  output logic [31:0] i_addr,
  input  logic        i_rvalid, input logic [31:0] i_rdata,
  // data port (OBI)
  output logic        d_req,   input logic d_gnt,
  output logic [31:0] d_addr,  output logic d_we, output logic [3:0] d_be,
  output logic [31:0] d_wdata,
  input  logic        d_rvalid, input logic [31:0] d_rdata,
  input  logic        irq_timer, irq_external,
  // retirement trace (RVFI subset), one retired instruction or trap per cycle max
  output logic        rvfi_valid, output logic [63:0] rvfi_order,
  output logic [31:0] rvfi_insn,  output logic rvfi_trap, output logic rvfi_intr,
  output logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr,
  output logic [31:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata,
  output logic [31:0] rvfi_pc_rdata, rvfi_pc_wdata,
  output logic [31:0] rvfi_mem_addr, output logic [3:0] rvfi_mem_rmask, rvfi_mem_wmask,
  output logic [31:0] rvfi_mem_rdata, rvfi_mem_wdata
);
```

Microarchitecture: IF, ID, EX, MEM, WB. Register file read in ID, written
in WB (x0 hard-wired to 0). Full forwarding EX/MEM and MEM/WB to EX;
one-cycle load-use stall. Branches and jumps resolve in EX; static
predict-not-taken; a taken branch flushes IF and ID (2-cycle penalty).
CSR instructions and MRET execute in EX and serialize the pipeline
(younger instructions flushed, refetch). Traps and interrupts are taken
at the MEM/WB boundary of the instruction they attach to (precise).

M instructions execute in EX in `rv32_muldiv` and hold EX (and so IF and
ID) until the result is ready; older instructions in MEM and WB keep
moving. The unit captures its operands (after forwarding) in the first EX
cycle in which MEM is not stalled, so a load followed by an M consumer
costs the usual one load-use stall. Latency, counted as cycles the
instruction spends in EX on an unstalled pipeline:
- MUL, MULH, MULHSU, MULHU: 4 (operands registered as 33-bit signed
  values; four 17 x 17 partial products registered; carry-save step,
  64-bit add and high/low word select registered; result into EX/MEM),
  so 3 stall cycles. In the sky130 flow a single-cycle 33 x 33 multiply
  measured 13.5 ns and the 3-cycle split 10.2 ns, against about 9 ns for
  the rest of the core, hence 4 cycles.
- DIV, DIVU, REM, REMU: 34 (operand magnitudes registered, 32 radix-2
  restoring steps, then sign fix into EX/MEM), so 33 stall cycles. The
  latency does not depend on the operands.
The result is written to EX/MEM like an ALU result and forwarded from
there, so back-to-back dependent M instructions need no extra stall
beyond the latency above. An interrupt that becomes pending while an M
instruction is in EX is taken at once: the instruction is abandoned
(mepc = its pc, no state changed) and executes again from the start after
MRET. A flush (trap commit) also abandons the operation. Consequence: a
divide only completes if no interrupt is taken during its 34 cycles, so
software that re-enables interrupts must not let a new one become pending
within 34 cycles of every MRET (true for any handler that clears its
source, since MIE stays 0 until MRET).

RVFI semantics follow riscv-formal: `rvfi_valid` pulses once per retired
instruction (including a trapping one, with `rvfi_trap = 1`, `rd_addr =
0`); `rvfi_intr` is set on the first instruction of a handler entered by
an interrupt or trap; `rvfi_order` counts from 0; `rd_addr` is 0 when
nothing is written; masks are byte masks of the access. `rvfi_pc_wdata`
is the next pc in program order.

Targets: CPI close to 1 on straight-line code; 100 MHz on the Basys 3
is the goal, 50 MHz the minimum.

## 4. OBI (Open Bus Interface, OpenHW Group), the subset used here

Address phase: master asserts `req` with `addr`, `we`, `be`, `wdata`
stable until the cycle `gnt` is high (handshake on `req && gnt`). Response
phase: `rvalid` with `rdata` (reads) one or more cycles after the
handshake, in order. At most one outstanding transaction per port, but a
master may issue the next request in the same cycle `rvalid` arrives. The
core's instruction port therefore fetches one instruction per cycle from
a slave that grants immediately and responds the next cycle. Writes also
get an `rvalid` (no data). No error signal.

## 5. Memory map

| Range | Size | Slave |
|---|---|---|
| 0x0000_0000 - 0x0000_FFFF | 64 KB | RAM (code and data), dual port: port A = core instruction port, port B = data port |
| 0x1000_0000 - 0x1000_0FFF | | UART |
| 0x1000_1000 - 0x1000_1FFF | | GPIO |
| 0x1000_2000 - 0x1000_2FFF | | TIMER (mtime / mtimecmp) |
| 0x1000_3000 - 0x1000_3FFF | | SYSCTL: core hold, accelerator clock gate, MBIST (section 13) |
| 0x1000_F000 - 0x1000_FFFF | | SIMCTRL (simulation only; reads 0 on hardware) |
| 0x2000_0000 - 0x2000_FFFF | | ATTN accelerator, AXI4-Lite, own clock domain (section 12) |

Data-port accesses decode on addr[31:28]: 0 = RAM, 1 = APB bridge,
anything else returns 0 on reads and drops writes (no trap; documented).
Peripheral registers are 32-bit, word-aligned. Sub-word stores to a
peripheral update only the enabled byte lanes (APB4 `pstrb`); the other
bytes of the register keep their value. Write-1 / action registers
(OUT_SET, OUT_CLR, STATUS clear bits, UART DATA push, SIMCTRL) act on the
enabled lanes only.

## 6. RAM: `dp_ram`

`dp_ram #(parameter int AW = 14, parameter INIT_FILE = "")`: 2^AW words,
two OBI slave ports (A read-only, B read/write with byte enables), each
grants immediately and responds the next cycle (BRAM template, READ_FIRST).
`INIT_FILE` is a `$readmemh` image (one 32-bit word per line); this is the
one place an initial block is allowed in RTL, because it is the
standard BRAM-initialization idiom on FPGAs and in simulation.

## 7. Interconnect

`obi_arb2` (section 13.1) merges the core data port and the JTAG debug
master into one OBI link in front of the decoder.
`obi_decoder`: data port to {RAM port B, APB bridge, default slave} by
addr[31:28], one outstanding transaction, response routed by a registered
select. `obi2apb`: OBI slave to AMBA APB4 master (SETUP then ACCESS phase,
waits for `pready`, `pslverr` ignored, `pstrb` = OBI `be` on writes and
4'b0000 on reads, `pprot` = 3'b000), `psel` one-hot per peripheral by
addr[15:12].

## 8. Peripherals (AMBA APB4 slaves)

Common APB slave ports: `pclk = clk`, `presetn` derived from `rst`,
`psel, penable, pwrite, paddr[11:0], pwdata[31:0], pstrb[3:0],
prdata[31:0], pready, pslverr (0)`. All respond with `pready = 1` in the
ACCESS phase. A write changes only the bytes whose `pstrb` bit is set.
UART DATA pushes a TX byte only when `pstrb[0]` is set.

UART (8N1): 0x0 DATA (write: push TX FIFO; read: pop RX FIFO, bit 8 =
valid), 0x4 STATUS (bit0 tx_full, bit1 tx_empty, bit2 rx_valid,
bit3 rx_overrun, write 1 to bit3 to clear), 0x8 DIVISOR (clk cycles per
bit, reset value 868 = 100 MHz / 115200), 0xC IRQ_EN (bit0 rx interrupt).
TX and RX FIFOs 16 deep. RX input passes through a 2-flop synchronizer.
Output `irq` = IRQ_EN.rx && rx_valid.

GPIO: 0x0 OUT (16 bits to LEDs), 0x4 IN (16 switches + 5 buttons in bits
20:16, through 2-flop synchronizers), 0x8 OUT_SET, 0xC OUT_CLR.

TIMER: 0x0 MTIME_LO, 0x4 MTIME_HI (64-bit counter, increments every clock
cycle, writable), 0x8 MTIMECMP_LO, 0xC MTIMECMP_HI (reset all-ones).
`irq_timer = (mtime >= mtimecmp)`.

SIMCTRL (simulation only, `ifndef SYNTHESIS`): 0x0 write EXIT: ends the
simulation with exit code = value (0 = pass); 0x4 write PUTC: prints the
low byte to the simulator console.

SYSCTL (core hold, accelerator clock gate, RAM BIST): section 13.2.

External interrupt line to the core = UART irq OR accelerator irq (section 12).

## 9. Software

Toolchain: lowRISC clang in `~/tools/riscv/bin` (`riscv32-unknown-elf-clang`,
`-march=rv32im_zicsr -mabi=ilp32`, lld). `sw/common/`: `crt0.S` (sets sp
to the top of RAM, clears .bss, copies nothing since code runs from RAM,
calls `main`, writes the return value to SIMCTRL EXIT, then loops),
`link.ld` (everything in RAM at 0x0), `soc.h` (register map), small
drivers (`uart.c`, `gpio.c`, `timer.c`), `printf`-lite. Build output per
program: `.elf`, `.bin`, `.hex` (`$readmemh` format, 32-bit words).

ISA tests (`sw/isa/`): one assembly file per instruction group, each
self-checking, ending by writing 0 (pass) or the failing test number to
SIMCTRL EXIT.

## 10. Golden model and verification

`model/rv32_iss.py`: an instruction-set simulator for exactly section 2
(RV32IM + Zicsr + M-mode traps and interrupts) and the memory map
(RAM, SIMCTRL; UART TX modeled as a byte sink), loading the same `.hex`.
It produces the same retirement trace fields as RVFI. Testbenches run
the RTL and the ISS in lockstep on the RVFI trace and fail on the first
mismatch. Interrupts are injected into the ISS at the retirement index
where the RTL took them (`rvfi_intr`).

Verification layers: per-block cocotb tests; directed ISA tests;
random instruction streams (generator in `model/`) checked in lockstep;
SVA on the OBI and APB protocols; SymbiYosys formal on the decoder,
bridge and selected core invariants; line and functional coverage gates;
later a UVM environment on the APB bus and riscv-formal on the core.

## 11. Repository layout

```
rtl/core/   rv32_core and its submodules (regfile, decoder, alu, csr, ...)
rtl/bus/    obi_decoder, obi_arb2, obi2apb, obi2axil, apb_mux, protocol checkers
rtl/periph/ uart_apb, gpio_apb, timer_apb, sysctl_apb, simctrl_apb, sync2ff, fifo
rtl/mem/    dp_ram
rtl/accel/  axil_attn, attn_seq, async_fifo, p1/ (section 12)
rtl/debug/  JTAG TAP, debug transport (OBI master), CDC handshake, BSCANE2 wrapper
rtl/dft/    mbist_marchc, bist_ram_mux
rtl/clk/    clk_gate (ICG)
rtl/soc_top.sv, rtl/soc.f (every SoC source outside rtl/core, soc_top last)
fpga/       Basys 3 top, XDC, build scripts
model/      rv32_iss.py, random program generator
sw/         common/, isa/, c/
tb/         core/, periph/, soc/, accel/, debug/, dft/, socdbg/ (cocotb)
formal/     .sby files
```

## 12. Accelerator

The p1-attention engine (`attention_top`, one attention head, D = 16,
N = 4..64 in steps of 4, int8 Q1.6 in and out, bit-exact against p1
`model/attn.py attn_fixed`) as a memory-mapped peripheral at 0x2000_0000.
`soc_top` parameter `ACCEL_EN` (default 1) can leave the accelerator out:
0x2000_0000 then behaves like any unmapped range (reads 0, writes
dropped) and the accelerator interrupt is 0. The Basys 3 top defaults to 0
(smaller, faster builds); the full SoC also fits the XC7A35T (15.3k LUTs,
72 of its 90 DSP48 slices with the MAC multipliers in LUTs) and is built
with ACCEL=1 (fpga/openxc7/build.sh, fpga/build.tcl).

Sources: `rtl/accel/p1/` holds p1's `mac_unit`, `matmul_tile`,
`exp_lut_1p`, `sync_ram`, `online_softmax`, `attention_top` byte-identical
to the commit named in `rtl/accel/p1/README.md`. The p1 files include
`"rtl/exp_lut.svh"`, so the header lives at `rtl/accel/p1/rtl/exp_lut.svh`
and every tool gets `+incdir+rtl/accel/p1`. Instantiated with
`PIPE_ROM = 1, PV_SPLIT = 0` (p1's FPGA configuration).

Path: core data port -> `obi_decoder` (addr[31:28] = 2, parameter
`AXI_EN = 1` in `soc_top`; with `AXI_EN = 0` nibble 2 stays on the default
slave) -> `obi2axil` (OBI slave to AXI4-Lite master, one transaction
outstanding, `bready = rready = 1`, AW and W issued together, AxPROT = 0,
WSTRB = OBI be; a SLVERR response completes the OBI transaction normally,
reads then return 0) -> `axil_attn`.

`axil_attn` (system clock `clk`, `rst`; accelerator clock `accel_clk`,
`accel_rst`, each reset synchronous to its own clock and both asserted
together at power-up):
- AXI4-Lite slave: AW, W, B, AR, R with full valid/ready handshakes. AW and
  W are accepted independently (one of each held); the write executes when
  both are held and B is free; B and R hold until `bready` / `rready`.
  OKAY for mapped registers, SLVERR for unmapped or misaligned offsets, for any address
  with addr[27:16] != 0, for LOAD or CTRL.START while busy, for START with
  an illegal N, and for LOAD / RD_ADDR writes without all four strobes.
  Writes to read-only bits are ignored (OKAY).
- Registers (32-bit, offset from 0x2000_0000):

| Off | Name | Bits |
|---|---|---|
| 0x00 | CTRL | [0] START (write 1: run, reads 0), [14:8] N_LEN (RW, reset 4) |
| 0x04 | STATUS | [0] BUSY (RO), [1] DONE (sticky, write 1 to clear), [2] IRQ_EN (RW), [3] ACCEL_BUSY (RO, attention_top busy through a 2-flop synchronizer) |
| 0x08 | LOAD | W: [7:0] data (Q1.6), [17:8] addr {row[5:0], col[3:0]}, [21:20] sel (0 Q, 1 K, 2 V); reads 0 |
| 0x0C | RD_ADDR | [9:0] output address {row, col}; a write requests that byte |
| 0x10 | RD_DATA | [7:0] the byte requested by the last RD_ADDR write; a read waits (R held) until it has arrived |
| 0x14 | CYCLES | attention_top `cycle_count` of the last finished run |
| 0x18 | IRQ | [0] pending = DONE & IRQ_EN (RO); write 1 clears DONE |
| 0x1C | ID | 0x4154_544E ("ATTN") |

- BUSY is set when START is accepted and cleared when the run's completion
  record arrives back in the system domain, so a read after START never
  sees an idle accelerator that has not started yet.
- `irq` = DONE & IRQ_EN, ORed into the core's external interrupt with the
  UART irq (the handler tells them apart by reading the two status
  registers).

Clock-domain crossing (`rtl/accel/async_fifo.sv`, depth 4, gray-coded
pointers through 2-flop synchronizers, every flop reset):
- Command FIFO, system -> accelerator: {op, payload} with op LOAD (sel,
  addr, data), START (n_len), READ (rd_addr). A full FIFO stalls the AXI
  write (B is delayed), it never drops a command.
- Response FIFO, accelerator -> system: {kind, data[31:0]} with kind READ
  (rd_data) or DONE (cycle_count). DONE travels through the FIFO rather
  than as a pulse synchronizer so that CYCLES is always updated in the same
  system cycle as DONE. The system side pops every cycle, so it never
  back-pressures the accelerator for long.
- ACCEL_BUSY is the only signal on a plain 2-flop synchronizer (a level,
  informational).
- The accelerator-side sequencer executes one command at a time: LOAD is a
  one-cycle write strobe, START a one-cycle start pulse, READ drives
  rd_addr and pushes rd_data two cycles later; done pushes {DONE,
  cycle_count}.

Software contract: load Q, K, V for rows 0..N-1 while idle, write CTRL
with N_LEN and START, wait for DONE (poll STATUS or take the interrupt),
then write RD_ADDR / read RD_DATA per output byte. `attention_top` cycle
count is nblk * (16 nblk + 156) + 1 accelerator cycles, nblk = N / 4.

Golden model: the ISS cannot model the accelerator. Reads of 0x2000_0000 -
0x2000_FFFF are flagged `nondet` (value 0 in the ISS), writes are dropped,
and the lockstep bench compares every field except the read value for
that range. `sw/c/attn_test.c` therefore checks the accelerator in software
against a bit-exact C port of attn_fixed, and exits 0 without testing when
ID does not read "ATTN" (a standalone ISS run).

## 13. Debug, core hold, memory BIST and accelerator clock gating

### 13.1 JTAG debug master and the data-bus arbiter

`jtag_debug` (rtl/debug: `jtag_tap` + `jtag_obi_master` + `cdc_req_ack`,
scan protocol in `rtl/debug/README.md`) is a second OBI master on the data
side. `soc_top` ports: `tck`, `trst`, `tms`, `tdi`, `tdo`, `tdo_oe`, and
`dbg_rst`, the reset of the transport's `clk` side. `dbg_rst` and `trst` must
come from the same power-on event and never from a button or a
debugger-controlled reset (a toggle handshake reset on one side only can
replay or drop a request); in simulation `dbg_rst` is tied to `rst`. With
parameter `JTAG_BSCAN = 1` (Basys 3, define `FPGA_XC7`) the transport sits
behind the FPGA's BSCANE2 (Xilinx USER4, IR 0x23 on the XC7A35T) instead of
`jtag_tap`, and the pin inputs are unused.

`obi_arb2` sits between the masters and `obi_decoder`:
- Policy: round-robin. A master requesting alone is forwarded
  combinationally (no extra latency for the core). When both request in the
  same cycle, the one that did not win the last handshake wins; the JTAG
  master wins the first tie after reset. A waiting master is passed over by
  at most one handshake of the other.
- A request presented to the decoder without a grant locks the choice until
  the grant, so the decoder sees addr / we / be / wdata held (OBI rule M1).
- One transaction on the shared link at a time (the decoder enforces it);
  the response goes to the master registered at the handshake.

JTAG reaches everything the core's data port reaches: RAM (port B),
every APB peripheral including SYSCTL, and the accelerator. Debug accesses
are word-only (`be = 4'hF`). While the core runs, debug accesses interleave
with its loads and stores; programs are unaffected unless they share the
addresses. The core's instruction fetch (RAM port A) is never arbitrated.

### 13.2 SYSCTL (APB slot 3, 0x1000_3000)

| Off | Name | Bits |
|---|---|---|
| 0x00 | CTRL | [0] CORE_HOLD (RW, reset 0), [1] ACCEL_CLK_EN (RW, reset 1) |
| 0x04 | STATUS | [0] CORE_HELD (RO), [1] ACCEL_CLK_ON (RO) |
| 0x08 | BIST_CTRL | [0] START: write 1 to start the RAM BIST; taken only while CORE_HELD = 1 and BIST is not busy, ignored otherwise; reads 0 |
| 0x0C | BIST_STATUS | [0] BUSY, [1] DONE (until the next START), [2] FAIL (sticky until the next START), [6:4] FAIL_ELEM (March element 0..5), [10:8] FAIL_BG (background) |
| 0x10 | BIST_FAIL_ADDR | byte address of the first mismatch |
| 0x14 | BIST_FAIL_SYN | expected XOR read data of the first mismatch |
| 0x1C | ID | 0x5359_5343 ("SYSC") |

CTRL acts only when `pstrb[0]` is set. Other offsets read 0.

Core hold: the core is reset (`core_rst = rst | CORE_HELD`) while CORE_HOLD
is 1 or the BIST is busy. CORE_HELD rises only in a cycle where the core is
not waiting for a data-port grant, so the core never withdraws an
ungranted OBI request; an access already granted completes on the bus and
its response is dropped by the core in reset. Releasing CORE_HOLD restarts
the core at `RESET_PC`. The JTAG boot flow: write CTRL = HOLD, poll STATUS
until CORE_HELD, write the program image over JTAG, write CTRL = 0 (keeping
ACCEL_CLK_EN as wanted). The core may also hold itself; then only JTAG or
`rst` releases it.

### 13.3 RAM BIST

`mbist_marchc` (`AW = 14`, `BASE = 0`, `NBG = BIST_NBG`, default 1: the
solid background, which detects stuck-at, transition, address-decoder and
inter-word coupling faults) tests the whole 64 KB data RAM through port B:
10 x 2^14 x NBG word accesses, two cycles each (327,680 cycles with
NBG = 1, 3.3 ms at 100 MHz). `bist_ram_mux` gives port B to the BIST while it
is busy; the data bus then gets no grant on RAM and its RAM requests wait.
The select only changes with nothing outstanding on either side: BIST starts
from an APB write (the single-transaction data bus has no RAM access in
flight then) and ends after its last response.

The core is kept off the RAM by the hold: START is ignored unless
CORE_HELD = 1, and BIST busy keeps the core in reset even if CORE_HOLD is
cleared meanwhile. The test is destructive: afterwards the RAM holds the
background (all zeros with NBG = 1), so the program must be reloaded (JTAG)
or the SoC reset with an `INIT_FILE` image. Poll BIST_STATUS over JTAG
(APB, not RAM) until BUSY is 0; a JTAG RAM access during the test waits
until the test ends.

### 13.4 Accelerator clock gate

`axil_attn`'s accelerator domain runs on `accel_gclk`, the output of
`clk_gate` on `accel_clk`. SYSCTL.ACCEL_CLK_EN (system clock) passes a 2-flop
synchronizer on `accel_clk` (reset value 1, so the domain is clocked while
`accel_rst` is applied) into the gate's enable; STATUS.ACCEL_CLK_ON is that
synchronized enable brought back through a 2-flop synchronizer, so software
knows when the clock has actually stopped or restarted.

`clk_gate` is an integrated clock gate (enable captured while the clock is
low, output = clock AND captured enable; no glitches):
- `SKY130`: the `sky130_fd_sc_hd__dlclkp` cell.
- `FPGA_XC7`: a BUFGCE.
- otherwise a behavioral model: an explicit `always_latch` plus an AND. This
  is the one deliberate latch in the RTL (exception to section 1); the
  synthesis check counts exactly one latch in `soc_top` with the model and
  none with the sky130 cell.

While the clock is stopped the accelerator domain freezes in place: a run
in progress pauses and continues on restart with the same result and cycle
count (attention_top counts its own clock), commands keep queuing in the
command FIFO (a full FIFO delays the AXI write response, the bus waits) and
nothing is lost. Software contract: stop the clock when idle (STATUS.BUSY =
0) to save power, wait for ACCEL_CLK_ON = 0; to restart, set ACCEL_CLK_EN and
wait for ACCEL_CLK_ON = 1 before relying on accelerator timing. Stopping
the clock mid-run is allowed but the run then takes longer.

### 13.5 Verification

- `tb/soc` lockstep: JTAG idle (TAP in Test-Logic-Reset, no TCK), every
  program including `sw/c/clkgate_test.c`, at both accelerator clock
  ratios, plus the random programs.
- `tb/socdbg` (cocotb on `tb_soc_dbg`: `soc_top` with OBI checkers on the
  core port, the JTAG port, the arbiter output, the BIST port and RAM port
  B): JTAG traffic to RAM, GPIO, TIMER, SYSCTL and the accelerator while
  `bench` runs in lockstep with the ISS (cycles with both masters requesting
  are counted and must occur); JTAG hold, program load and release with
  `hello` in lockstep after the release; BIST START ignored while the core
  runs, BIST pass on the RAM, BIST fail on a forced stuck-at-1 bit with the
  expected address, element, background and syndrome; `clkgate_test` in
  lockstep with no gated-clock edge while the enable is low and the frozen
  run's output equal to p1 `attn_fixed`.
- `formal/arb_bmc.sby`: BMC (depth 32) and cover on `obi_arb2` with the OBI
  checkers on all three links plus exclusive grants, forwarding, response
  routing and fairness.
- Lint (`tb/socdbg/lint.sh`, verilator `-Wall` and verible, including the
  board top against primitive stubs) and the latch check
  (`tb/socdbg/synth.sh`).
