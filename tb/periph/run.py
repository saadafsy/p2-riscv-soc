"""Build and run the bus/periph/mem cocotb benches on Verilator with
assertions enabled.

    python run.py              all positive benches, then the negative bench
    python run.py uart bus     selected benches
    python run.py neg          negative checker tests only

Positive benches run with the default error limit, so any checker assertion
stops the simulation and fails the run. The negative bench raises the limit
and also requires every checker label to appear in its log.
"""

import re
import sys
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUS, PER, MEM = ROOT / "rtl/bus", ROOT / "rtl/periph", ROOT / "rtl/mem"
BUILD = HERE / "build"

CHECKERS = [BUS / "obi_checker.sv", BUS / "apb_checker.sv"]
BENCHES = {
    "uart": ([PER / "sync2ff.sv", PER / "sync_fifo.sv", PER / "uart_apb.sv"], "test_uart"),
    "gpio": ([PER / "sync2ff.sv", PER / "gpio_apb.sv"], "test_gpio"),
    "timer": ([PER / "timer_apb.sv"], "test_timer"),
    "simctrl": ([PER / "simctrl_apb.sv"], "test_simctrl"),
    "dp_ram": ([MEM / "dp_ram.sv"], "test_dp_ram"),
    "obi2apb": ([BUS / "apb_mux.sv", BUS / "obi2apb.sv"], "test_obi2apb"),
    "bus": ([PER / "sync2ff.sv", PER / "sync_fifo.sv", PER / "uart_apb.sv",
             PER / "gpio_apb.sv", PER / "timer_apb.sv", PER / "simctrl_apb.sv",
             MEM / "dp_ram.sv", BUS / "apb_mux.sv", BUS / "obi2apb.sv",
             BUS / "obi_default_slave.sv", BUS / "obi_decoder.sv"], "test_bus"),
    "neg": ([], "test_checkers_neg"),
}
TOPS = {"neg": "tb_checkers"}
NEG_LABELS = ["obi_m1_hold", "obi_s1_rvalid", "obi_s2_one_outstanding",
              "apb_a1_onehot", "apb_a2_en_sel", "apb_a3_setup_access",
              "apb_a4_en_after_setup", "apb_a5_stable", "apb_a6_wait", "apb_a7_end",
              "apb_a8_strb_prot_stable", "apb_a9_strb_read_zero"]


def write_ram_image(path, aw=10):
    # Must match init_word() in test_dp_ram.py.
    with open(path, "w") as f:
        for i in range(1 << aw):
            f.write(f"{(i * 0x9E3779B1 + 0x1234) & 0xFFFFFFFF:08x}\n")


def run_bench(name):
    srcs, module = BENCHES[name]
    top = TOPS.get(name, f"tb_{name}")
    bdir = BUILD / name
    bdir.mkdir(parents=True, exist_ok=True)
    params = {}
    if name == "dp_ram":
        img = bdir / "ram_init.hex"
        write_ram_image(img)
        params = {"AW": 10, "INIT_FILE": f'"{img}"'}  # verilator -G needs the quotes
    neg = name == "neg"
    runner = get_runner("verilator")
    runner.build(
        sources=CHECKERS + srcs + [HERE / f"{top}.sv"],
        hdl_toplevel=top,
        build_dir=bdir,
        parameters=params,
        build_args=["--assert", "-Wall", "-Wno-fatal"],
        timescale=("1ns", "1ps"),
        log_file=bdir / "build.log",
    )
    log = bdir / "sim.log"
    plus = ["+verilator+error+limit+100000"] if neg else []
    xml = runner.test(
        hdl_toplevel=top, test_module=module, test_dir=HERE, build_dir=bdir,
        results_xml=str(bdir / "results.xml"), plusargs=plus, log_file=log,
    )
    ntests, nfail = get_results(xml)
    text = log.read_text(errors="replace")
    asserts = len(re.findall(r"Assertion failed", text))
    ok = nfail == 0
    if neg:
        missing = [lb for lb in NEG_LABELS if lb not in text]
        if missing:
            print(f"[neg] labels never reported by Verilator: {missing}")
            ok = False
    elif asserts:
        ok = False
    print(f"[{name}] tests {ntests} failed {nfail} assertion-failures {asserts} "
          f"-> {'PASS' if ok else 'FAIL'}")
    return ntests, ok


def main(argv):
    names = argv or [n for n in BENCHES if n != "neg"] + ["neg"]
    total, bad = 0, []
    for n in names:
        if n not in BENCHES:
            sys.exit(f"unknown bench {n}; choose from {list(BENCHES)}")
        cnt, ok = run_bench(n)
        total += cnt
        if not ok:
            bad.append(n)
    print(f"TOTAL tests {total}; failing benches: {bad or 'none'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
