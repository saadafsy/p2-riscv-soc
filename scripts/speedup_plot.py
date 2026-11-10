#!/usr/bin/env python3
"""Bar chart of the accelerator speedup for the README (docs/img/speedup.png).

The cycle counts are the ones `make speedup` printed (mcycle, CPU cycles, SoC
simulation with the core at 100 MHz and the accelerator at 73 MHz); pass a log
from a new run to plot that instead:  python3 scripts/speedup_plot.py [speedup.log]
"""
import pathlib
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = pathlib.Path(__file__).resolve().parent.parent
# N: (load, compute, read, software) from `make speedup`, 2026-11-09
RUNS = {16: (9277, 1262, 6322, 175879), 64: (36925, 9083, 25207, 1549997)}
if len(sys.argv) > 1:
    RUNS = {}
    pat = re.compile(r"N=(\d+) load (\d+) \+ compute (\d+) \+ read (\d+) = \d+ cycles accel, (\d+) cycles software")
    for m in pat.finditer(pathlib.Path(sys.argv[1]).read_text()):
        RUNS[int(m[1])] = tuple(int(x) for x in m.groups()[1:])

fig, axes = plt.subplots(1, len(RUNS), figsize=(8, 3.4), dpi=150)
for ax, (n, (load, comp, read, sw)) in zip(axes, sorted(RUNS.items())):
    hw = load + comp + read
    ax.bar(0, sw, color="#9e9e9e", width=0.6)
    ax.bar(1, load, color="#1f77b4", width=0.6, label="load Q, K, V")
    ax.bar(1, comp, bottom=load, color="#d62728", width=0.6, label="compute")
    ax.bar(1, read, bottom=load + comp, color="#2ca02c", width=0.6, label="read results")
    ax.text(0, sw, f"{sw:,}", ha="center", va="bottom", fontsize=8)
    ax.text(1, hw, f"{hw:,}\n{sw / hw:.1f}x faster", ha="center", va="bottom", fontsize=8)
    ax.set_xticks([0, 1], ["optimized C\non the core", "accelerator\n(end to end)"], fontsize=8)
    ax.set_title(f"N = {n}", fontsize=10)
    ax.set_ylim(0, sw * 1.18)
    ax.spines[["top", "right"]].set_visible(False)
    ax.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
axes[0].set_ylabel("CPU cycles (mcycle)")
axes[-1].legend(frameon=False, fontsize=8, loc="upper right")
fig.suptitle("One attention head: software on the RV32IM core vs the accelerator (SoC simulation)", fontsize=10, x=0.02, ha="left")
fig.tight_layout()
out = ROOT / "docs" / "img" / "speedup.png"
fig.savefig(out, facecolor="white")
print("wrote", out)
