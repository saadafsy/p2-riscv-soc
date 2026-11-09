# tb/uvm: UVM environment for the APB4 peripheral subsystem

A UVM bench for `obi2apb` plus the four APB4 slaves (`uart_apb`,
`gpio_apb`, `timer_apb`, `simctrl_apb` with `FINISH_ON_EXIT = 0`), driven
from the OBI side. It sits beside the cocotb suites in tb/periph, which stay
the per-block regression. Simulator: Verilator 5.053 (oss-cad-suite) with
Accellera UVM 1800.2-2017-1.0 from `~/tools/uvm`, `+define+UVM_NO_DPI`.

## Structure

```
 tb_top
  |-- obi_if ------------------------------+      +--------------- apb_if --------------+
  |                                        |      |  (bus taps, pins, stall, sim taps)  |
  |  apb_sub_wrap (DUT)                    v      v                                     |
  |   OBI --> obi2apb --APB4 bus--+--> uart_apb (slot 0)   rx/tx/irq                    |
  |            |   ^   pstrb/pwdata shim   +--> gpio_apb (slot 1)   gpio_in/gpio_out    |
  |            |   |   (INJECT_BUG_*)      +--> timer_apb (slot 2)  irq_timer           |
  |            |   +-- pready & !stall     +--> simctrl_apb (slot 15, FINISH_ON_EXIT=0) |
  |   bind: obi_checker (OBI port), apb_checker (APB bus)                               |
  |
  +-- uvm_test_top (p2_smoke_test | p2_random_test | p2_stress_test)
        p2_env
         |-- obi_agent:  obi_sequencer -> obi_driver -> obi_if ; obi_monitor (req_ap, rsp_ap)
         |-- apb_agent:  apb_monitor (passive)  -> ap
         |-- pin_driver: stall (wait states), gpio_in
         |-- uart_rx_driver: 8N1 frames on uart_rx -> ap
         |-- p2_scoreboard  <- req_ap, rsp_ap, apb ap, rx ap
         |     `-- p2_reg_model (register mirror / predictor)
         `-- p2_coverage    <- req_ap, apb ap
```

| File | Role |
|------|------|
| apb_sub_wrap.sv | DUT wrapper: bridge + 4 slaves, slots 3..14 tied off, wait-state adapter, bug shims, simctrl taps |
| apb_sub_binds.sv | `bind apb_sub_wrap` of rtl/bus/obi_checker.sv and rtl/bus/apb_checker.sv |
| obi_if.sv, apb_if.sv | interfaces with drive/monitor clocking blocks and a shared cycle counter |
| obi_item.sv | `obi_item` (address = kind/slot/offset/alias fields, we, be, wdata, delay, pipe), `apb_xfer`, `uart_rx_frame`, register ids |
| obi_agent.sv | OBI driver/monitor/agent, passive APB monitor/agent, pin driver, UART RX driver |
| p2_reg_model.sv | predictor: every register per spec 5/8, byte lanes, W1x actions, TX FIFO + shifter, mtime |
| p2_scoreboard.sv | in-order OBI -> APB -> OBI checker; model-state covergroups |
| p2_coverage.sv | functional covergroups |
| p2_seqs.sv, p2_tests.sv, p2_env.sv, p2_uvm_pkg.sv, tb_top.sv | sequences, tests, env, package, top |
| scripts/run.sh | cached Verilator build per variant + one run |
| scripts/summary.sh, scripts/covsum.py | pass/fail + coverage table; coverage.dat summarizer |
| cov_off.vlt | keeps line/toggle coverage off the UVM library and bench plumbing |

### Stimulus

`obi_item` constrains the address to the APB window `0x1xxx_xxxx`:
88% a named register of the four peripherals, 6% an unmapped offset inside
a peripheral (offset 0x010..0xFFF), 6% an unpopulated slot (3..14); 5% set
`addr[27:16]` (aliases, ignored by the bridge) and 5% set `addr[1:0]`
(ignored by the slaves). `be` is one of the seven legal patterns (4 bytes,
2 halves, word) for reads and writes. Request timing: `pipe = 1` (35%)
raises `req` the cycle after the previous handshake, so it waits for `gnt`
and is granted in the `rvalid` cycle (zero-gap back-to-back); otherwise the
driver waits for `rvalid` and then 0..20 idle cycles. Each variable has at
most one `dist`; test knobs (force back-to-back, UART bias) are applied by
assignment after `randomize()`.

APB wait states: every slave has `pready = 1`, so the wrapper inserts
waits when the bench raises `stall` (per cycle, `wait_pct` percent): the
bridge sees `pready = 0`, the slaves see `penable = 0`, so a slave acts
exactly once, in the cycle its ACCESS completes. The APB monitor and
`apb_checker` see the true waited protocol.

### Prediction (p2_reg_model)

An access is applied at its completing ACCESS edge `c` (cycle stamp from
the interfaces' shared counter): reads return the state during cycle `c`,
writes take effect at edge `c`, matching the RTL.

* Byte lanes: every write merges only the `pstrb` lanes (spec 5).
  GPIO OUT/OUT_SET/OUT_CLR use lanes 0..1; DIVISOR lanes 0..1; IRQ_EN,
  UART DATA push, STATUS clear and PUTC need lane 0; MTIME/MTIMECMP halves
  and EXIT use all four.
* Write-1 actions: OUT_SET `|=`, OUT_CLR `&= ~`, STATUS bit 3 clears
  rx_overrun, DATA write pushes TX, EXIT records the masked code (pstrb 0 is
  no write), PUTC counts characters. EXIT/PUTC effects are checked at the
  end against the simctrl `exit_seen/exit_code/putc_count` taps.
* UART TX FIFO depth: the 16-deep FIFO and the 10-bit shifter are stepped
  edge by edge (lazily up to the next access) with the divisor in force at
  each edge, so `tx_full`, `tx_empty` and dropped pushes are exact.
* UART RX: `uart_rx_driver` sends frames while the OBI port is idle and
  publishes them when the receiver is done; the model pushes them (or sets
  rx_overrun past 16). RX timing itself is not modeled; DATA reads pop.
* TIMER: exact, no tolerance. `mtime(k) = base + (k - base_cyc)`; a write to
  one half replaces the enabled bytes of `mtime(c)`, skips that increment
  and re-anchors at `c + 1`. `irq_timer = mtime >= mtimecmp` is checked in
  every APB ACCESS cycle.
* GPIO IN: the APB monitor attaches `gpio_in` as sampled two edges before
  the access (the 2-flop synchronizer).

### Scoreboard

For every OBI request: the APB transfer must carry psel slot = addr[15:12],
paddr = addr[11:0], pwrite = we, pstrb = be on writes and 0 on reads,
pwdata = wdata on the be lanes, pprot = 0, with SETUP the edge after the
handshake; `prdata` must equal the prediction; `gpio_out`, `irq_timer` and
`uart_irq` must equal the model in the ACCESS cycle; `rvalid` must follow
the ACCESS by one edge (one edge after the handshake for an unpopulated
slot) with `rdata` = prediction (0 for writes and unmapped). No APB transfer
may appear without a request; nothing may be outstanding at the end; a run
with zero checked reads fails.

### Coverage (SV covergroups)

| covergroup | content |
|------------|---------|
| cg_access | 14 registers x {R, W} x 7 strobe patterns (196-bin cross); unmapped offset per peripheral and unmapped slot x {R, W}; alias; nonzero addr[1:0] |
| cg_b2b | gap previous-rvalid to handshake {0 = back-to-back, 1, 2..4, 5+} x {RR, RW, WR, WW}; x same/other slave; R->W, W->R, W->W transitions |
| cg_gnt | req-to-gnt wait {0, 2, 3, 4+}; 1 is unreachable for obi2apb (ignore_bins) |
| cg_wait | APB wait states {0, 1, 2, 3+} x peripheral x direction |
| cg_model | TX FIFO level at each push {empty, partial, full}; dropped push |
| cg_status | each UART STATUS bit read as 0 and 1 |
| cg_rx | RX FIFO level at each DATA read {empty, partial, full} |
| cg_misc | rx_overrun cleared by W1C; irq_timer 0 and 1 |

## How to run

```
make -C tb/uvm smoke                     # directed test
make -C tb/uvm random SEED=7             # one constrained-random run
make -C tb/uvm stress SEED=7
make -C tb/uvm regress SEEDS="1 2 3 4 5" # smoke + random + stress per seed, table, merged coverage
make -C tb/uvm bug                       # injected bugs must be caught
make -C tb/uvm clean
```

`NUM_TXN=<n>` changes the transaction count (random 3000, stress 4000
by default). Builds are cached in tb/uvm/build/obj_<variant> (JOBS=4 make
jobs) and rebuilt when a tb/uvm or rtl/bus, rtl/periph source is newer.
Runs land in tb/uvm/build/runs/<test>_s<seed>/{sim.log,coverage.dat}.

`make bug` builds three variants and requires each to fail for its own reason:

* `strb` (`+define+INJECT_BUG_STRB`): a shim makes the bridge's pstrb
  all-ones on every write, i.e. byte enables ignored. The APB protocol stays
  legal, so the bound checkers stay silent; the scoreboard must report both
  APB field mismatches and wrong OBI read data.
* `proto` (`+define+INJECT_BUG_PROTO`): pwdata bit 0 flips in ACCESS; the
  bound `apb_checker` A5 must fire.
* `obi` (`+define+INJECT_BUG_OBI`): the driver changes wdata while waiting
  for gnt; the bound `obi_checker` M1 must fire.

## Results (2026-11-08, Verilator 5.053 devel, UVM 1800.2-2017-1.0, WSL Ubuntu 24.04)

`make regress SEEDS="1 2 3 4 5"`: 11 runs (smoke + 5 x random + 5 x
stress), 11 passed, 0 scoreboard mismatches, no assertion failures.
Per run: random 3015 OBI transactions (about 1400 reads checked), stress
4014 (about 1200 reads); smoke 174. All requests, APB transfers and
responses checked; pins checked in every APB ACCESS cycle.

Per-run `get_inst_coverage()` (mean over coverpoints/crosses):

| covergroup | smoke | random s1..s5 | stress s1..s5 |
|------------|-------|---------------|---------------|
| cg_access | 67.4 | 98.8 .. 99.3 | 98.5 .. 99.1 |
| cg_access.cx_reg_rw_be (196 bins) | 29.1 | 90.3 .. 94.4 | 87.8 .. 92.9 |
| cg_b2b | 71.9 | 100 | 79.2 (back-to-back only, by design) |
| cg_gnt | 25.0 | 100 | 100 |
| cg_wait | 85.2 | 98.4 .. 99.2 | 100 |
| cg_model | 100 | 33.3 .. 100 | 100 |
| cg_status | 100 | 75.0 .. 87.5 | 62.5 .. 75.0 |
| cg_rx | 100 | 66.7 | 33.3 |
| cg_misc | 100 | 50.0 | 50.0 |

Merged over the 11 runs (`verilator_coverage --write`, then
`--report summary` and scripts/covsum.py):

* covergroup bins: 337/337 = 100% (verilator_coverage). covsum.py also
  counts cg_gnt's ignore bin and prints 337/338.
* RTL code coverage (rtl/ files only): line 131/134 = 97.8%, toggle
  3337/3716 = 89.8%. The 3 missed lines are 2 in simctrl_apb (its
  FINISH_ON_EXIT branches cannot be reached with FINISH_ON_EXIT = 0) and
  1 in uart_apb. These were not annotated line by line: run
  `verilator_coverage --annotate` on merged.dat to confirm.

`make bug` (seed 1, 600 transactions per leg): BUG GATE PASS.

* strb: caught by the scoreboard alone. There were 188 APB field
  mismatches and 31 wrong OBI read values, and no protocol checker fired.
* proto: caught by `tb_top.dut.u_apb_chk.g_assert.apb_a5_stable`.
* obi: caught by `tb_top.dut.u_obi_chk.g_m_assert.obi_m1_hold`.

Runtime: about 70 s wall time for a 3000-transaction random run. Most of
it goes to the external SMT solver (z3) that Verilator calls for
`randomize()`; simulation CPU is about 16 s.

## Verilator notes and limitations

* Covergroups do work in this Verilator. Used here: explicit bins, value
  ranges with `$`, `ignore_bins`, transition bins `(a => b)`, 2- and 3-way
  crosses, `option.per_instance`, `get_inst_coverage()` on the group and on
  one cross. A side probe also showed `wildcard` bins, `iff` and
  `binsof`-based `ignore_bins` in crosses computing correct percentages.
  `illegal_bins` were declared but never hit, so their error behaviour was
  not checked. With `--coverage-user` the bins land in coverage.dat, and
  verilator_coverage merges them across seeds.
* There is no UCIS/RAL. The register model is a plain SV class, and the
  merged figure is a bin count. That is a different metric from
  `get_inst_coverage()`, which is the mean over items.
* Portability fixes needed:
  - `alias` is a keyword, so the bin is called `aliased`. `small` is
    avoided as an identifier.
  - No `dist` combined with `==` on the same variable: knobs are applied
    by assignment after `randomize()`.
  - `+UVM_TESTNAME` is read in tb_top, because a UVM_NO_DPI build cannot
    read it in run_test.
  - No `uvm_top`.
* Immediate assertions need `--assert`. A failure prints
  `Assertion failed in <path>` and calls `$stop`. Any UVM error turns into
  `$fatal` in tb_top's `final` block, so a run exits nonzero.

## Observation about the RTL (not a mismatch)

`uart_apb` ends a bit period on `tx_cnt == div_eff - 1`. If DIVISOR is
lowered below the running `tx_cnt` mid-character, the counter has to wrap
through 65536 before the bit ends, so TX stalls for up to about 65k
cycles. The model mirrors this, so it is not flagged. Early random runs
showed it: only 17 bytes went out and 84 were dropped. The random
DIVISOR writes are now held at 3 (95%) so that TX keeps draining.

## Not covered here

* UART RX timing: frames are sent only while the OBI port is idle, and the
  model applies them as a batch.
* The serial output on uart_tx is not decoded.
* pslverr: the bridge ignores it, and every slave drives 0.
* Random runs rarely clear rx_overrun with W1C, and they reach a full RX
  FIFO only on seeds whose burst is 16 bytes or more. Smoke covers both.
