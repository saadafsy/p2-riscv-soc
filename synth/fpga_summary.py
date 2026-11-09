#!/usr/bin/env python3
"""Roll a yosys synth_xilinx `stat` dump up into LUT / FF / CARRY / DSP / BRAM / LUTRAM counts.
Usage: python3 synth/fpga_summary.py build/synth/fpga_rv32_core_stat.txt [--out FILE]
"""
import argparse
import re
import sys
from pathlib import Path

CLASSES = [
    ("LUT", r"^(LUT[1-6]|INV)$"),
    ("MUXF", r"^MUXF[78]$"),
    ("FF", r"^(FD[A-Z]*|LD[A-Z]*)$"),
    ("CARRY", r"^CARRY[48]$"),
    ("DSP", r"^DSP48"),
    ("BRAM", r"^RAMB(18|36)"),
    ("LUTRAM", r"^(RAM\d+[MSX]|RAM\d+X\d+[SD]|SRL)"),
    ("IO/BUF", r"^((I|O|IO)?BUF|BUFG)"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stat")
    ap.add_argument("--out")
    a = ap.parse_args()
    cells = {}
    for line in Path(a.stat).read_text(errors="replace").splitlines():
        m = re.match(r"\s+(\d+)\s+(?:[\d.E+-]+\s+)?\$?(\w+)\s*$", line)
        if m and m.group(2) not in ("cells", "ports", "wires", "wire_bits", "port_bits",
                                    "memories", "memory_bits", "processes", "scopeinfo"):
            cells[m.group(2)] = cells.get(m.group(2), 0) + int(m.group(1))
    if not cells:
        print("fpga_summary: no cells parsed from", a.stat)
        return 1
    tot = {k: 0 for k, _ in CLASSES}
    other = {}
    for c, n in cells.items():
        for k, pat in CLASSES:
            if re.match(pat, c):
                tot[k] += n
                break
        else:
            other[c] = n
    L = ["# rv32_core Xilinx 7-series resource count (yosys synth_xilinx, pre-place-and-route)"]
    L += [f"{k:7s} {v}" for k, v in tot.items()]
    L.append("detail: " + ", ".join(f"{c}={n}" for c, n in sorted(cells.items())))
    if other:
        L.append("unclassified: " + ", ".join(f"{c}={n}" for c, n in sorted(other.items())))
    out = "\n".join(L) + "\n"
    print(out)
    if a.out:
        Path(a.out).write_text(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
