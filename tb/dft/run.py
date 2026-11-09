"""Build and run the MBIST cocotb bench on Verilator, assertions on, in two
configurations: AW=5 with all 6 backgrounds, and AW=4 with the solid
background only. Any OBI checker assertion in the log fails the run.

    python run.py
"""

import os
import re
import sys
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SRCS = [ROOT / "rtl/bus/obi_checker.sv", ROOT / "rtl/dft/mbist_marchc.sv",
        HERE / "fault_mem.sv", HERE / "tb_mbist.sv"]
CONFIGS = {"aw5_nbg6": (5, 6), "aw4_nbg1": (4, 1)}


def run(name, aw, nbg):
    bdir = HERE / "build" / name
    bdir.mkdir(parents=True, exist_ok=True)
    runner = get_runner("verilator")
    runner.build(sources=SRCS, hdl_toplevel="tb_mbist", build_dir=bdir,
                 parameters={"AW": aw, "NBG": nbg},
                 build_args=["--assert", "-Wall", "-Wno-fatal"],
                 timescale=("1ns", "1ps"), log_file=bdir / "build.log")
    log = bdir / "sim.log"
    os.environ["MBIST_AW"], os.environ["MBIST_NBG"] = str(aw), str(nbg)
    xml = runner.test(hdl_toplevel="tb_mbist", test_module="test_mbist", test_dir=HERE,
                      build_dir=bdir, results_xml=str(bdir / "results.xml"), log_file=log,
                      extra_env={"MBIST_AW": str(aw), "MBIST_NBG": str(nbg)})
    ntests, nfail = get_results(xml)
    asserts = len(re.findall(r"Assertion failed", log.read_text(errors="replace")))
    ok = nfail == 0 and asserts == 0 and ntests > 0
    print(f"[mbist {name}] tests {ntests} failed {nfail} assertion-failures {asserts} "
          f"-> {'PASS' if ok else 'FAIL'}")
    return ok


def main(argv):
    names = argv or list(CONFIGS)
    bad = [n for n in names if not run(n, *CONFIGS[n])]
    print(f"failing configs: {bad or 'none'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
