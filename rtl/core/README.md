# rv32_core

5-stage in-order RV32I + Zicsr core, machine mode only (spec sections 2 and 3).

```
          +--------+    +--------+    +---------+    +---------+    +--------+
 i_* <--> |   IF   | -> |   ID   | -> |   EX    | -> |   MEM   | -> |   WB   | -> RVFI reg
          | fetch  |    | decode |    | ALU     |    | d_req   |    | d_rvalid|
          | 2-entry|    | regfile|    | branch  |    | (addr   |    | load    |
          | queue  |    | read   |    | CSR/MRET|    | phase)  |    | align,  |
          +--------+    +--------+    +---------+    +---------+    | rd write|
              ^              ^          |   ^  ^         |  trap      +--------+
              |   redirect   |          |   |  +-- fwd EX/MEM            |
              +--------------+----------+   +----- fwd MEM/WB -----------+
```

Files: `rv32_core.sv` (pipeline, stalls, traps, RVFI), `rv32_fetch.sv` (OBI fetch and
the IF/ID queue), `rv32_decoder.sv`, `rv32_alu.sv`, `rv32_regfile.sv` (write-through),
`rv32_csr.sv`, `rv32_hazard.sv`; file list `core.f`.

## Hazard and control rules

- Forwarding into EX from EX/MEM (ALU, link and CSR results) and from MEM/WB (including
  load data straight from `d_rdata`); the younger producer wins. ID reads the register
  file with write-through, so a WB write in the same cycle is seen.
- Load-use: a consumer directly behind a load stalls one cycle in ID.
- Branches and jumps resolve in EX, predict not taken; a taken one flushes IF and ID
  and costs 2 cycles.
- CSR instructions wait in EX until MEM and WB are empty (so counters read exactly), then
  execute and refetch pc+4. MRET executes in EX and redirects to mepc.
- Interrupts attach to the instruction leaving EX, which then has no effect. Synchronous
  traps are detected in ID or EX. Both commit when the instruction moves MEM -> WB:
  mepc/mcause/mtval are written, younger instructions are flushed, and fetch restarts at
  mtvec.
- Data port: MEM issues the request; WB waits for `d_rvalid` (stores too). The next
  request may go out in the cycle the previous `rvalid` arrives, so loads and stores
  stream at one per cycle.
- Fetch: one request per cycle; each request reserves a queue slot so a stalled ID
  never drops a response. Responses to requests made before a redirect are discarded.
  The queue falls through when empty, so the fetch-to-decode path costs no cycle.
- Timing structure (no behavior change): forwarding selects are computed from the
  next-cycle pipeline state and registered (a FORMAL assert ties them to the direct
  rd/rs compare); load lane and sign selects are decoded in MEM; load/store misalignment
  uses `rs1[1:0] + imm[1:0]`; a redirect clears only the fetch queue count, not its data.

## Conventions shared with model/rv32_iss.py

RVFI memory fields use the word-aligned address with byte-lane masks and lane-positioned
data. Illegal instructions report no rs fields. Trapping instructions report pc_wdata =
mtvec and do not count in minstret. A CSR write to a counter replaces that cycle's
increment. Writing a read-only CSR (addr[11:10] = 3) is illegal; misa and mip writes
are ignored.

## Measured (tb/core, fast memory)

| Kernel | Result |
|---|---|
| straight-line dependent ALU chain | CPI 1.00 |
| load + dependent use | 3 cycles per pair (1 stall) |
| taken jump | 3 cycles (2-cycle penalty) |

Synthesis (yosys `synth_xilinx`): about 3.5k LUTs and 2.8k flops, of which 1024 are the
register file (every flop is reset, so it is not in LUTRAM). sky130 timing: see
`synth/README.md`.

## Tests

```
cd tb/core
make            # cocotb on Verilator: own programs + sw/isa programs, fast and random latency
make lint       # verilator -Wall + verible (100 columns)
make formal     # formal/core_bmc.sby: bmc_fast, bmc_rand, cover
```

Each retirement is checked in lockstep against `model/rv32_iss.py` and against the
local model `tb/core/rv_ref.py`. Test programs are in `tb/core/progs` (assembled with
clang on demand). The `test_isa` cases need `build/sw/<name>/<name>.hex` from
`scripts/build_sw.sh`.
