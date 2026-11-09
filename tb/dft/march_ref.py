"""Reference model for the MBIST tests: the fault semantics of fault_mem.sv
and the March C- sequence of mbist_marchc.sv, written independently of the
RTL, so a test can predict whether a fault is caught and where first.
"""

from dataclasses import dataclass

NONE, SA0, SA1, TF_UP, TF_DN, CFIN, CFID, CFST, AF = range(9)
NAMES = {NONE: "none", SA0: "SA0", SA1: "SA1", TF_UP: "TF_UP", TF_DN: "TF_DN",
         CFIN: "CFIN", CFID: "CFID", CFST: "CFST", AF: "AF"}
BACKGROUNDS = [0x00000000, 0x55555555, 0x33333333, 0x0F0F0F0F, 0x00FF00FF, 0x0000FFFF]
MASK = 0xFFFFFFFF


@dataclass
class Fault:
    kind: int = NONE
    vaddr: int = 0
    vbit: int = 0
    aaddr: int = 0
    abit: int = 0
    up: int = 1
    val: int = 0


def _bit(w, b):
    return w >> b & 1


def _set(w, b, v):
    return (w | (1 << b)) if v else (w & ~(1 << b) & MASK)


class FaultMem:
    def __init__(self, aw, fault):
        self.m = [0] * (1 << aw)
        self.f = fault

    def _idx(self, i):
        f = self.f
        return f.aaddr if f.kind == AF and i == f.vaddr else i

    def read(self, i):
        return self.m[self._idx(i)]

    def write(self, i, d):
        f, m = self.f, self.m
        i = self._idx(i)
        aold = _bit(m[f.aaddr], f.abit)
        if i == f.vaddr:
            vb = _bit(d, f.vbit)
            old = _bit(m[i], f.vbit)
            if f.kind == SA0:
                d = _set(d, f.vbit, 0)
            elif f.kind == SA1:
                d = _set(d, f.vbit, 1)
            elif f.kind == TF_UP and not old and vb:
                d = _set(d, f.vbit, 0)
            elif f.kind == TF_DN and old and not vb:
                d = _set(d, f.vbit, 1)
        m[i] = d
        anew = _bit(m[f.aaddr], f.abit)
        trans = (not aold and anew) if f.up else (aold and not anew)
        if i == f.aaddr and trans:
            if f.kind == CFIN:
                m[f.vaddr] ^= 1 << f.vbit
            elif f.kind == CFID:
                m[f.vaddr] = _set(m[f.vaddr], f.vbit, f.val)
        if f.kind == CFST and _bit(m[f.aaddr], f.abit) == f.up:
            m[f.vaddr] = _set(m[f.vaddr], f.vbit, f.val)


# March C- elements: (descending, [(is_read, complement)])
MARCH_C_MINUS = [
    (False, [(False, 0)]),
    (False, [(True, 0), (False, 1)]),
    (False, [(True, 1), (False, 0)]),
    (True, [(True, 0), (False, 1)]),
    (True, [(True, 1), (False, 0)]),
    (True, [(True, 0)]),
]


def run_march(aw, nbg, fault):
    """Return (accesses, first) where first is None or
    (byte_addr, elem, bg, syndrome) of the first mismatching read."""
    mem = FaultMem(aw, fault)
    n = 1 << aw
    first = None
    accesses = 0
    for bg in range(nbg):
        pat = BACKGROUNDS[bg]
        for e, (down, ops) in enumerate(MARCH_C_MINUS):
            for i in (range(n - 1, -1, -1) if down else range(n)):
                for is_read, comp in ops:
                    data = (~pat & MASK) if comp else pat
                    accesses += 1
                    if is_read:
                        got = mem.read(i)
                        if got != data and first is None:
                            first = (i * 4, e, bg, got ^ data)
                    else:
                        mem.write(i, data)
    return accesses, first
