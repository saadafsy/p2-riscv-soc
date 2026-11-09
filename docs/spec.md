# p2-riscv-soc: specification

A small RISC-V SoC for the Digilent Basys 3 (Artix-7 XC7A35T, 100 MHz
board clock): a 5-stage pipelined RV32I core with machine-mode CSRs and
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

RV32I base (all 37 user instructions plus FENCE as a no-op), Zicsr, and
machine mode only.

CSRs implemented: `mstatus` (MIE, MPIE; MPP reads as 2'b11), `misa`
(read-only, RV32I), `mie` (MTIE bit 7, MEIE bit 11), `mip` (MTIP, MEIP,
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
| 0x2000_0000 - 0x2000_FFFF | | reserved: accelerator (later, AXI4-Lite) |

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

External interrupt line to the core = UART irq.

## 9. Software

Toolchain: lowRISC clang in `~/tools/riscv/bin` (`riscv32-unknown-elf-clang`,
`-march=rv32i_zicsr -mabi=ilp32`, lld). `sw/common/`: `crt0.S` (sets sp
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
(RV32I + Zicsr + M-mode traps and interrupts) and the memory map
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
