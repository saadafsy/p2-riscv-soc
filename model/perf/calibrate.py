"""Fit the free parameters of p2perf against RTL cycle counts and report how
well the model predicts programs it was not fitted on.

The RTL counts come from the lockstep SoC log (tb/soc prints
"<prog>: PASS, N instructions in C cycles"). The fit uses only the small
directed ISA programs; the C programs are the validation set.

usage: python3 model/perf/calibrate.py <rtl_cycles.txt> [--perf build/perf/p2perf]
writes model/perf/params.txt and prints the comparison table (markdown).
"""
import argparse
import json
import pathlib
import re
import subprocess

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
FREE = ["START", "CSR", "TRAP", "INTR", "APB"]
FEATURE = {"START": None, "CSR": "csr", "TRAP": "trap", "INTR": "intr", "APB": "apb"}
TRAIN = ["alu_imm", "alu_reg", "branch", "csr", "jump", "load", "lui_auipc", "store", "trap",
         "muldiv"]
VALIDATE = ["hello", "bench", "timer_irq", "irq", "coremark"]


def rtl_counts(path):
    out = {}
    for m in re.finditer(r"(\w+): PASS, (\d+) instructions in (\d+) cycles", open(path).read()):
        out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out


def run(perf, prog, params):
    hexf = ROOT / "build" / "sw" / prog / f"{prog}.hex"
    args = [str(perf), "--json", "--param", "UART_DIV=16"]  # as tb/soc builds the SoC
    for k, v in params.items():
        args += ["--param", f"{k}={v}"]
    r = subprocess.run(args + [str(hexf)], capture_output=True, text=True)
    return json.loads(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("--perf", default=str(ROOT / "build" / "perf" / "p2perf"))
    a = ap.parse_args()
    rtl = rtl_counts(a.rtl)
    train = [p for p in TRAIN if p in rtl]

    # Linear fit: rtl_cycles - fixed-cost cycles = X @ free params.
    rows, rhs = [], []
    for p in train:
        c = run(a.perf, p, {k: 0 for k in FREE})
        base = c["cycles"]  # retired + fixed costs (taken, load-use, mul, div)
        rows.append([1.0 if k == "START" else float(c[FEATURE[k]]) for k in FREE])
        rhs.append(rtl[p][1] - base)
    X, y = np.array(rows), np.array(rhs)
    # Least squares with every cost >= 0: drop a parameter that comes out
    # negative (it is held at 0) and refit, until all are non-negative.
    used = [i for i in range(len(FREE)) if X[:, i].any()]
    while True:
        sol, *_ = np.linalg.lstsq(X[:, used], y, rcond=None)
        neg = [i for i, v in zip(used, sol) if v < 0]
        if not neg:
            break
        used.remove(neg[0])
    params = {k: 0.0 for k in FREE}
    for i, v in zip(used, sol):
        params[FREE[i]] = round(float(v), 2)
    (ROOT / "model" / "perf" / "params.txt").write_text(
        " ".join(f"--param {k}={v}" for k, v in params.items()) + "\n")

    print("fitted on: " + ", ".join(train))
    print("parameters: " + ", ".join(f"{k}={v}" for k, v in params.items()))
    print()
    print("| program | set | RTL instr | model instr | RTL cycles | model cycles | error |")
    print("|---|---|---|---|---|---|---|")
    for p in train + [v for v in VALIDATE if v in rtl]:
        c = run(a.perf, p, params)
        ri, rc = rtl[p]
        err = (c["cycles"] - rc) / rc * 100
        s = "fit" if p in train else "validation"
        print(f"| {p} | {s} | {ri} | {c['retired']} | {rc} | {c['cycles']:.0f} | {err:+.1f}% |")


if __name__ == "__main__":
    main()
