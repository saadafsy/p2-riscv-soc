# rtl/debug: JTAG debug port (OBI master)

| File | Module | Clock |
|---|---|---|
| `jtag_tap.sv` | IEEE 1149.1 TAP: 16-state FSM, 5-bit IR, IDCODE, BYPASS, one user DR | tck |
| `jtag_obi_master.sv` | 66-bit debug DR, single OBI word transactions | tck + clk |
| `cdc_req_ack.sv` | toggle request/acknowledge handshake, 2-flop synchronizers | tck + clk |
| `jtag_debug.sv` | `jtag_tap` + `jtag_obi_master`, for JTAG on board pins | tck + clk |
| `bscan_jtag_xilinx.sv` | `BSCANE2` + `jtag_obi_master`, for the Basys 3 USB-JTAG (`FPGA_XC7` only, **untested on a board**) | tck + clk |

Integrated in `soc_top` (docs/spec.md section 13.1): the OBI master port
(spec section 4: word accesses, `be = 4'hF`, one outstanding transaction) is
master 1 of `rtl/bus/obi_arb2.sv`, which shares `obi_decoder` with the core
data port (round-robin). It reaches RAM, every APB peripheral (including
SYSCTL: core hold, BIST, accelerator clock gate) and the accelerator.
`soc_top` uses `jtag_debug` on its `tck/tms/tdi/tdo/trst` pins, or
`bscan_jtag_xilinx` with `JTAG_BSCAN = 1` (the Basys 3 top does). The
transport's `clk`-side reset is the `soc_top` port `dbg_rst` (see Resets
below); the board top drives it from the MMCM lock only, not from btnC.

The define is `FPGA_XC7`, not `XILINX_FPGA`: p1's `online_softmax.sv`
already uses `XILINX_FPGA` to select an XPM ROM that P2 does not include.

## TAP

- IR length 5. Capture-IR loads `5'b00001`.
- `5'h01` IDCODE (selected after Test-Logic-Reset), `5'h18` DBG (the debug
  DR below), `5'h1F` BYPASS. Every other code selects BYPASS (no boundary
  scan).
- IDCODE `0x10502001`: version 1, part `0x0502`, manufacturer field `0x000`.
  Manufacturer 0 has bad JEP106 parity, so it cannot alias a real vendor.
- Reset: five TCK cycles with TMS=1 from any state, or `trst` (synchronous,
  active high, optional: tie to 0).
- TDO changes on the falling edge of TCK; `tdo_oe` is high in Shift-IR and
  Shift-DR.

## Debug DR (IR = 0x18), 66 bits, shifted LSB first

```
 65            34 33            2 1  0
+----------------+---------------+----+
|   addr[31:0]   |   data[31:0]  | op |
+----------------+---------------+----+
```

Shift in at Update-DR:

| op | name | action |
|---|---|---|
| 0 | NOP | none |
| 1 | READ | read the word at `addr` |
| 2 | WRITE | write `data` to `addr` (`be = 4'hF`) |
| 3 | STATUS | clear the sticky error |

Shifted out (captured at Capture-DR):

| field | value |
|---|---|
| op bits | status: 0 OK, 2 ERROR (sticky), 3 BUSY (BUSY wins over ERROR) |
| data | read data of the last completed READ (0 after a WRITE); 0 while BUSY |
| addr | address of the last READ/WRITE that was accepted |

Rules:

1. Each scan both returns the result of earlier work and delivers a new op.
   Do the access, then scan NOP until the status is not BUSY.
2. READ or WRITE while BUSY is dropped and sets ERROR. So is an `addr` that
   is not word-aligned. ERROR stays until an op of 3 (STATUS).
3. An Update-DR with no Shift-DR since Capture-DR does nothing (the DR still
   holds the captured status, which must not be replayed as an op).
4. Scan exactly 66 bits; with any other length the op field holds the wrong
   bits.
5. The response only becomes visible to TCK after two TCK edges of
   synchronization, so a request takes 2 clk edges + the bus access + 2 TCK
   edges. With TCK much slower than `clk`, 4 TCK cycles in Run-Test/Idle
   after the request scan are normally enough; otherwise poll.

### Example (OpenOCD-style Tcl, untested)

```tcl
jtag newtap p2 cpu -irlen 5 -expected-id 0x10502001
proc p2_scan {op addr data} {
  set w [expr {($addr << 34) | ($data << 2) | $op}]
  set r 0x[drscan p2.cpu 66 [format 0x%017llx $w]]
  return [list [expr {$r & 3}] [expr {($r >> 2) & 0xffffffff}]]
}
proc p2_poll {} {
  while 1 { lassign [p2_scan 0 0 0] st d; if {$st != 3} { return [list $st $d] }; runtest 8 }
}
proc p2_write {addr data} { irscan p2.cpu 0x18; p2_scan 2 $addr $data; runtest 8; p2_poll }
proc p2_read  {addr}      { irscan p2.cpu 0x18; p2_scan 1 $addr 0;     runtest 8; p2_poll }
```

(Tcl integers are arbitrary precision; check `drscan` field handling on
your OpenOCD version. The cocotb host in `tb/debug/jtag_drv.py` is the
tested reference for this protocol.)

## Clock domain crossing

Only `cdc_req_ack` crosses: the request word `{we, addr, data}` (65 bits)
is registered on TCK and held until the response returns; the response
word is registered on `clk` and held until the next request. The single
toggle bits are the only signals that are synchronized (two flops,
`ASYNC_REG`). In timing constraints treat TCK and `clk` as asynchronous
and put a max-delay of one `clk` period on the data words.

`trst` and `rst` must be released by the same power-on event: a toggle
handshake loses or replays one request if only one side is reset while a
toggle is set. Do not drive `rst` of this block from a debugger-controlled
or button reset. Test-Logic-Reset does not reset the handshake.

## Basys 3 (BSCANE2)

`bscan_jtag_xilinx` replaces `jtag_tap` with the FPGA's own TAP: select the
debug DR with the Xilinx USER4 instruction (6-bit IR `0x23` on the
XC7A35T, `JTAG_CHAIN = 4`) instead of `0x18`; the 66-bit protocol is the
same. It is compiled only for the FPGA (define `FPGA_XC7`, set by
`fpga/build.tcl` and `fpga/openxc7/build.sh`), linted against primitive
stubs (`tb/socdbg/lint.sh`), and has not been simulated or run on a board.
The XDC constrains its TCK as clock `jtag_tck` (33.3 ns, Vivado only).

## Verification

`make -C tb/debug all`: lint (verilator `-Wall`, verible 100 columns), the
cocotb bench (`tb/debug/test_jtag.py`) and SymbiYosys on the TAP
(`formal/debug_tap.sby`) and the handshake (`formal/debug_cdc.sby`).
In the SoC: `python tb/socdbg/run.py` (JTAG traffic while the core runs,
JTAG program load and boot) and `formal/arb_bmc.sby` (the arbiter).
