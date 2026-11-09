"""Build and run the JTAG debug cocotb bench on Verilator, assertions on.
Any OBI checker assertion in the log fails the run.

    python run.py
"""

import re
import sys
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DBG = ROOT / "rtl/debug"
SRCS = [ROOT / "rtl/bus/obi_checker.sv", DBG / "cdc_req_ack.sv", DBG / "jtag_tap.sv",
        DBG / "jtag_obi_master.sv", DBG / "jtag_debug.sv", HERE / "tb_jtag.sv"]


def main():
    bdir = HERE / "build" / "jtag"
    bdir.mkdir(parents=True, exist_ok=True)
    runner = get_runner("verilator")
    runner.build(sources=SRCS, hdl_toplevel="tb_jtag", build_dir=bdir,
                 build_args=["--assert", "-Wall", "-Wno-fatal"],
                 timescale=("1ns", "1ps"), log_file=bdir / "build.log")
    log = bdir / "sim.log"
    xml = runner.test(hdl_toplevel="tb_jtag", test_module="test_jtag", test_dir=HERE,
                      build_dir=bdir, results_xml=str(bdir / "results.xml"), log_file=log)
    ntests, nfail = get_results(xml)
    asserts = len(re.findall(r"Assertion failed", log.read_text(errors="replace")))
    ok = nfail == 0 and asserts == 0 and ntests > 0
    print(f"[jtag] tests {ntests} failed {nfail} assertion-failures {asserts} "
          f"-> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
