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
  No latches, no `initial` in RTL (formal-only code under `ifdef FORMAL`).
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
rtl/bus/    obi_decoder, obi2apb, apb_mux
rtl/periph/ uart_apb, gpio_apb, timer_apb, simctrl_apb, sync2ff, fifo
rtl/mem/    dp_ram
rtl/soc_top.sv
fpga/       Basys 3 top, XDC, build scripts
model/      rv32_iss.py, random program generator
sw/         common/, isa/, c/
tb/         core/, periph/, soc/ (cocotb)
formal/     .sby files
```

## 12. Accelerator

The p1-attention engine (`attention_top`, one attention head, D = 16,
N = 4..64 in steps of 4, int8 Q1.6 in and out, bit-exact against p1
`model/attn.py attn_fixed`) as a memory-mapped peripheral at 0x2000_0000.

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
