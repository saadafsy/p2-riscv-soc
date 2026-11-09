#!/usr/bin/env python3
"""Summarize a synth/sta.tcl log: setup WNS/TNS, implied Fmax, the worst
endpoint groups (endpoint registers grouped by RTL bus name), and hold.

Flattened flops are anonymous (_12345_); each is named by its Q net from the
gate netlist, which keeps the RTL register name (e.g. ex_rs1_val[3]).
Exit 1 if no complete setup path is found, so an empty report is never summarized.
Usage: python3 synth/sta_summary.py build/synth/sta_rv32_core.log --period 10 \
         --netlist build/synth/rv32_core_sky130_netlist.v [--out FILE] [--groups 3]
"""
import argparse
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path


def flop_nets(netlist):
    """flop instance -> Q net name."""
    nets, cell = {}, None
    for line in Path(netlist).read_text(errors="replace").splitlines():
        m = re.match(r"\s*sky130_fd_sc_hd__(?:df|ed|sdf)\w*\s+(\S+)\s*\(", line)
        if m:
            cell = m.group(1)
            continue
        if cell:
            m = re.search(r"\.Q\((.+)\)", line)
            if m:
                nets[cell] = re.sub(r"^\\", "", m.group(1).strip()).replace(" [", "[")
                cell = None
            elif line.strip().startswith(");"):
                cell = None
    return nets


def sections(text):
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"---([A-Z][A-Z0-9-]*[A-Z0-9])---\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        if cur:
            out[cur].append(line)
    return out


def paths(lines):
    res, cur = [], None
    for line in lines:
        m = re.match(r"\s*Startpoint:\s*(\S+)", line)
        if m:
            cur = {"start": m.group(1), "end": None, "slack": None, "lines": [], "arrival": None}
            res.append(cur)
            continue
        if cur is None:
            continue
        cur["lines"].append(line)
        m = re.match(r"\s*Endpoint:\s*(\S+)", line)
        if m:
            cur["end"] = m.group(1)
        m = re.match(r"\s*(-?\d+\.\d+)\s+data arrival time", line)
        if m and cur["arrival"] is None:
            cur["arrival"] = float(m.group(1))
        m = re.match(r"\s*(-?\d+\.\d+)\s+slack\s+\((MET|VIOLATED)\)", line)
        if m:
            cur["slack"] = float(m.group(1))
    return [p for p in res if p["slack"] is not None and p["end"]]


def ends(lines):
    res = []
    for line in lines:
        m = re.match(r"(\S+)/\w+\s+\(\S+\)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)", line)
        if m:
            res.append((m.group(1), float(m.group(4))))
    return res


def bus(name):
    return re.sub(r"\[\d+\]$", "", name)


def path_shape(p):
    """Logic depth, cell-type mix and the high-fanout nets of one path."""
    cells, hifo = [], []
    rows = p["lines"]
    for i, line in enumerate(rows):
        m = re.match(r"\s*(\d+)?\s+-?\d+\.\d+\s+-?\d+\.\d+\s+[v^]\s+(\S+)/(\w+)\s+\((\S+)\)", line)
        if not m or m.group(3) in ("CLK",) or m.group(3) == "D":
            continue
        cells.append(m.group(4).replace("sky130_fd_sc_hd__", ""))
        fo = int(m.group(1)) if m.group(1) else 0
        if fo >= 8 and i + 1 < len(rows):
            n = re.match(r"\s+(\S+) \(net\)", rows[i + 1])
            hifo.append(f"{n.group(1) if n else '?'}:{fo}")
    return cells, hifo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--period", type=float, required=True)
    ap.add_argument("--netlist")
    ap.add_argument("--out")
    ap.add_argument("--groups", type=int, default=3)
    a = ap.parse_args()
    nets = flop_nets(a.netlist) if a.netlist else {}
    nm = lambda c: nets.get(c, c)
    sec = sections(Path(a.log).read_text(errors="replace"))

    allp = paths(sec.get("SETUP-ALL", []))
    if not allp:
        print("sta_summary: no setup path found in", a.log)
        return 1
    worst = allp[0]
    wns = worst["slack"]
    tmin = a.period - wns
    L = [
        "# rv32_core STA summary (pre-layout, sky130_fd_sc_hd tt_025C_1v80, ideal clock,",
        "# zero I/O delay; tool estimate, not silicon)",
        f"source: {a.log}",
        f"clock period: {a.period} ns",
        f"setup WNS (all paths): {wns:+.3f} ns ({'MET' if wns >= 0 else 'VIOLATED'})",
        f"implied min period / Fmax: {tmin:.3f} ns / {1000.0 / tmin:.1f} MHz  (period - WNS)",
        f"worst path: {nm(worst['start'])} -> {nm(worst['end'])}",
    ]

    e = ends(sec.get("SETUP-REG2REG-ENDS", []))
    if e:
        viol = [s for _, s in e if s < 0]
        L.append(f"reg->reg endpoints: {len(e)}, violating: {len(viol)}, TNS: {sum(viol):+.3f} ns")
    groups = OrderedDict()
    for inst, s in e:
        g = bus(nm(inst))
        groups.setdefault(g, []).append(s)
    full = paths(sec.get("SETUP-REG2REG-FULL", []))
    first = {}
    for p in full:
        first.setdefault(bus(nm(p["end"])), p)
    L.append("")
    L.append(f"worst {a.groups} reg->reg endpoint groups (endpoint bus, bits listed, worst slack):")
    for k, (g, sl) in enumerate(list(groups.items())[: a.groups], 1):
        p = first.get(g)
        L.append(f"  {k}. {g}  ({len(sl)} bits in report, worst {min(sl):+.3f} ns)")
        if p:
            cells, hifo = path_shape(p)
            starts = sorted({bus(nm(q['start'])) for q in full if bus(nm(q['end'])) == g})
            L.append(f"     worst path: {nm(p['start'])} -> {nm(p['end'])}, arrival {p['arrival']:.3f} ns, "
                     f"{len(cells)} cells")
            L.append(f"     startpoint buses into this group: {', '.join(starts[:8])}")
            L.append(f"     high-fanout nets on path (net:fanout): {', '.join(hifo) or 'none'}")
            L.append(f"     cell mix: {', '.join(f'{c}x{n}' for c, n in Counter(cells).most_common(6))}")
        else:
            L.append("     (no full path in the SETUP-REG2REG-FULL window; raise -group_path_count)")

    L.append("")
    for tag, label in (("SETUP-IN2REG", "input->reg"), ("SETUP-REG2OUT", "reg->output"),
                       ("SETUP-IN2OUT", "input->output")):
        pp = paths(sec.get(tag, []))
        if pp:
            p = pp[0]
            L.append(f"worst {label}: {p['slack']:+.3f} ns, {nm(p['start'])} -> {nm(p['end'])}")
    hp = paths(sec.get("HOLD-CHECK", []))
    if hp:
        h = hp[0]
        L.append(f"hold worst slack: {h['slack']:+.3f} ns ({'MET' if h['slack'] >= 0 else 'VIOLATED'}), "
                 f"{nm(h['start'])} -> {nm(h['end'])}")
    L.append("")
    L.append("worst setup path detail:")
    L += ["  " + l for l in worst["lines"]]
    out = "\n".join(L) + "\n"
    print("\n".join(L[: L.index("worst setup path detail:")]))
    if a.out:
        Path(a.out).write_text(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
