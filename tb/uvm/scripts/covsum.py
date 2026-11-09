#!/usr/bin/env python3
"""Summarize a Verilator coverage.dat (single run or verilator_coverage merge).

Prints, for the RTL under test (files under rtl/), line and toggle points
hit/total per file, and for every covergroup the bins hit/total. Covergroup
figures here are bin counts (hit bins / all bins, crosses included), which
is not the same metric as get_inst_coverage() (mean over coverpoints and
crosses) that the simulation log prints.
Usage: covsum.py <coverage.dat>
"""
import re
import sys
from collections import defaultdict

LINE_RE = re.compile(r"^C '(.*)' (\d+)$")


def fields(key):
    out = {}
    for part in key.split("\x01"):
        if "\x02" in part:
            k, v = part.split("\x02", 1)
            out[k] = v
    return out


def main(path):
    code = defaultdict(lambda: [0, 0])   # (file, type) -> [hit, total]
    cg = defaultdict(lambda: [0, 0])     # covergroup -> [hit, total]
    with open(path, encoding="latin-1") as fh:
        for line in fh:
            m = LINE_RE.match(line.rstrip("\n"))
            if not m:
                continue
            f = fields(m.group(1))
            cnt = int(m.group(2))
            typ = f.get("t", "")
            if typ == "covergroup":
                name = f.get("page", "").split("/", 1)[-1]
                name = name.split("::")[-1]
                cg[name][0] += cnt > 0
                cg[name][1] += 1
            elif typ in ("line", "toggle", "branch"):
                fn = f.get("f", "")
                if "/rtl/" not in fn:
                    continue
                key = (fn.split("/rtl/", 1)[1], typ)
                code[key][0] += cnt > 0
                code[key][1] += 1
    tot = defaultdict(lambda: [0, 0])
    print("RTL code coverage (rtl/ files only):")
    for (fn, typ), (h, t) in sorted(code.items()):
        print(f"  {fn:24s} {typ:7s} {h:5d}/{t:<5d} {100.0 * h / t:5.1f}%")
        tot[typ][0] += h
        tot[typ][1] += t
    for typ, (h, t) in sorted(tot.items()):
        print(f"  {'TOTAL':24s} {typ:7s} {h:5d}/{t:<5d} {100.0 * h / t:5.1f}%")
    print("covergroup bins (hit/total):")
    h_all = t_all = 0
    for name, (h, t) in sorted(cg.items()):
        print(f"  {name:12s} {h:4d}/{t:<4d} {100.0 * h / t:5.1f}%")
        h_all += h
        t_all += t
    if t_all:
        print(f"  {'ALL':12s} {h_all:4d}/{t_all:<4d} {100.0 * h_all / t_all:5.1f}%")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "coverage.dat")
