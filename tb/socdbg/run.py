"""Build tb_soc_dbg (soc_top + OBI checkers) on Verilator with assertions on
and run test_soc_dbg: every test at ACCEL_PERIOD_PS 13698 (73 MHz), then the
clock-gate test again at 7300 (137 MHz). Any checker assertion in a log
fails the run. Programs come from build/sw (make sw).

    python run.py
"""

import re
import sys
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def srcs():
    files = []
    for fl in ("rtl/core/core.f", "rtl/soc.f"):
        files += [ROOT / l for l in (ROOT / fl).read_text().split()]
    return files + [ROOT / "rtl/bus/obi_checker.sv", HERE / "tb_soc_dbg.sv"]


def main():
    bdir = HERE / "build"
    bdir.mkdir(parents=True, exist_ok=True)
    runner = get_runner("verilator")
    runner.build(sources=srcs(), hdl_toplevel="tb_soc_dbg", build_dir=bdir,
                 includes=[ROOT / "rtl/accel/p1"],
                 build_args=["--assert", "-Wall", "-Wno-fatal", "--public-flat-rw"],
                 timescale=("1ns", "1ps"), log_file=bdir / "build.log")
    runs = [("73", "13698", None), ("137", "7300", "clock_gate")]
    ok = True
    for name, period, filt in runs:
        log = bdir / f"sim_{name}.log"
        xml = runner.test(hdl_toplevel="tb_soc_dbg", test_module="test_soc_dbg", test_dir=HERE,
                          build_dir=bdir, results_xml=str(bdir / f"results_{name}.xml"),
                          log_file=log, test_filter=filt,
                          extra_env={"ACCEL_PERIOD_PS": period, "P2_ROOT": str(ROOT)})
        ntests, nfail = get_results(xml)
        asserts = len(re.findall(r"Assertion failed", log.read_text(errors="replace")))
        good = nfail == 0 and asserts == 0 and ntests > 0
        ok = ok and good
        print(f"[socdbg accel {name} MHz] tests {ntests} failed {nfail} "
              f"assertion-failures {asserts} -> {'PASS' if good else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
