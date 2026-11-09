"""Small RV32I + Zicsr + M-mode reference model for lockstep RVFI checks.

It follows spec section 2 and the RVFI conventions of model/rv32_iss.py
(word-aligned mem_addr, byte-lane masks, lane-positioned mem data). Interrupts are not modeled on their own: the testbench injects one
where the RTL took it (rvfi_intr on a record that does not follow a trap).
"""

M32 = 0xFFFFFFFF
RAM_SIZE = 0x10000

# CSRs whose read value cannot be predicted by an untimed model.
TIMING_CSRS = {0xB00, 0xB80, 0xC00, 0xC80}


def lane_bits(mask):
    return sum(0xFF << (8 * i) for i in range(4) if mask >> i & 1)


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class RefModel:
    def __init__(self, image: bytes, reset_pc=0):
        self.mem = bytearray(RAM_SIZE)
        self.mem[: len(image)] = image
        self.x = [0] * 32
        self.pc = reset_pc
        self.mie_b = self.mpie = self.mtie = self.meie = 0
        self.mtvec = self.mscratch = self.mepc = self.mcause = self.mtval = 0
        self.mcycle = self.minstret = 0
        self.irq_t = self.irq_e = 0
        self.mip_exact = True
        self.last_trap = False

    # ------------------------------------------------------------ memory
    def rd32(self, a):
        a &= ~3
        return int.from_bytes(self.mem[a: a + 4], "little") if a + 4 <= RAM_SIZE else 0

    def wr(self, a, nbytes, v):
        if a + nbytes <= RAM_SIZE:
            for i in range(nbytes):
                self.mem[a + i] = (v >> (8 * i)) & 0xFF

    # ------------------------------------------------------------ CSRs
    def csr_read(self, a):
        mstatus = (3 << 11) | (self.mpie << 7) | (self.mie_b << 3)
        table = {
            0x300: mstatus, 0x301: 0x40000100,
            0x304: (self.meie << 11) | (self.mtie << 7),
            0x305: self.mtvec, 0x340: self.mscratch, 0x341: self.mepc,
            0x342: self.mcause, 0x343: self.mtval,
            0x344: (self.irq_e << 11) | (self.irq_t << 7),
            0xB00: self.mcycle & M32, 0xB80: self.mcycle >> 32,
            0xC00: self.mcycle & M32, 0xC80: self.mcycle >> 32,
            0xB02: self.minstret & M32, 0xB82: self.minstret >> 32,
            0xC02: self.minstret & M32, 0xC82: self.minstret >> 32,
            0xF11: 0, 0xF12: 0, 0xF13: 0, 0xF14: 0,
        }
        return table.get(a)

    def csr_write(self, a, v):
        if a == 0x300:
            self.mie_b, self.mpie = v >> 3 & 1, v >> 7 & 1
        elif a == 0x304:
            self.mtie, self.meie = v >> 7 & 1, v >> 11 & 1
        elif a == 0x305:
            self.mtvec = v & ~3 & M32
        elif a == 0x340:
            self.mscratch = v
        elif a == 0x341:
            self.mepc = v & ~3 & M32
        elif a == 0x342:
            self.mcause = v
        elif a == 0x343:
            self.mtval = v
        elif a == 0xB00:
            self.mcycle = (self.mcycle & ~M32) | v
        elif a == 0xB80:
            self.mcycle = (self.mcycle & M32) | (v << 32)
        elif a == 0xB02:
            self.minstret = (self.minstret & ~M32) | v
        elif a == 0xB82:
            self.minstret = (self.minstret & M32) | (v << 32)

    # ------------------------------------------------------------ traps
    def enter_trap(self, cause, tval):
        self.mepc = self.pc & ~3
        self.mcause, self.mtval = cause, tval & M32
        self.mpie, self.mie_b = self.mie_b, 0
        self.pc = self.mtvec

    def take_interrupt(self, cause):
        self.enter_trap(cause, 0)

    # ------------------------------------------------------------ execute
    def step(self, rtl=None):
        """Execute one instruction; return the expected RVFI fields.

        rtl (the RTL record) supplies read values of timing-dependent CSRs.
        """
        pc = self.pc
        insn = self.rd32(pc)
        r = dict(pc_rdata=pc, insn=insn, trap=0, rs1_addr=0, rs2_addr=0, rs1_rdata=0,
                 rs2_rdata=0, rd_addr=0, rd_wdata=0, mem_addr=0, mem_rmask=0,
                 mem_wmask=0, mem_rdata=0, mem_wdata=0)
        op, rd, f3 = insn & 0x7F, insn >> 7 & 31, insn >> 12 & 7
        rs1, rs2, f7 = insn >> 15 & 31, insn >> 20 & 31, insn >> 25
        imm_i = sx(insn >> 20, 12)
        imm_s = sx(((insn >> 25) << 5) | (insn >> 7 & 31), 12)
        imm_b = sx(((insn >> 31) << 12) | ((insn >> 7 & 1) << 11) | ((insn >> 25 & 63) << 5)
                   | ((insn >> 8 & 15) << 1), 13)
        imm_u = insn & 0xFFFFF000
        imm_j = sx(((insn >> 31) << 20) | ((insn >> 12 & 255) << 12) | ((insn >> 20 & 1) << 11)
                   | ((insn >> 21 & 1023) << 1), 21)

        def use1():
            r["rs1_addr"], r["rs1_rdata"] = rs1, self.x[rs1]
            return self.x[rs1]

        def use2():
            r["rs2_addr"], r["rs2_rdata"] = rs2, self.x[rs2]
            return self.x[rs2]

        def trap(cause, tval):
            r.update(trap=1, rd_addr=0, rd_wdata=0, mem_addr=0, mem_rmask=0, mem_wmask=0,
                     mem_rdata=0, mem_wdata=0)
            self.enter_trap(cause, tval)
            r["pc_wdata"] = self.pc
            self.last_trap = True
            return r

        def illegal():
            r.update(rs1_addr=0, rs1_rdata=0, rs2_addr=0, rs2_rdata=0)
            return trap(2, insn)

        npc = (pc + 4) & M32
        result = None
        no_instret = False
        if insn & 3 != 3:
            return illegal()
        if op == 0x37:
            result = imm_u
        elif op == 0x17:
            result = (pc + imm_u) & M32
        elif op == 0x6F:
            t = (pc + imm_j) & M32
            if t & 3:
                return trap(0, t)
            result, npc = (pc + 4) & M32, t
        elif op == 0x67:
            if f3:
                return illegal()
            t = (use1() + imm_i) & M32 & ~1
            if t & 3:
                return trap(0, t)
            result, npc = (pc + 4) & M32, t
        elif op == 0x63:
            if f3 in (2, 3):
                return illegal()
            a, b = use1(), use2()
            sa, sb = sx(a, 32), sx(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}[f3]
            if taken:
                t = (pc + imm_b) & M32
                if t & 3:
                    return trap(0, t)
                npc = t
        elif op == 0x03:
            if f3 not in (0, 1, 2, 4, 5):
                return illegal()
            addr = (use1() + imm_i) & M32
            size = 1 << (f3 & 3)
            if addr & (size - 1):
                return trap(4, addr)
            lanes = ((1 << size) - 1) << (addr & 3)
            word = self.rd32(addr)
            raw = (word >> (8 * (addr & 3))) & ((1 << (8 * size)) - 1)
            r.update(mem_addr=addr & ~3, mem_rmask=lanes, mem_rdata=word & lane_bits(lanes))
            result = raw if f3 & 4 or size == 4 else sx(raw, 8 * size) & M32
        elif op == 0x23:
            if f3 > 2:
                return illegal()
            base, data = use1(), use2()
            addr = (base + imm_s) & M32
            size = 1 << f3
            if addr & (size - 1):
                return trap(6, addr)
            data &= (1 << (8 * size)) - 1
            lanes = ((1 << size) - 1) << (addr & 3)
            r.update(mem_addr=addr & ~3, mem_wmask=lanes, mem_wdata=(data << (8 * (addr & 3))) & M32)
            self.wr(addr, size, data)
        elif op in (0x13, 0x33):
            if op == 0x13:
                if (f3 == 1 and f7 != 0) or (f3 == 5 and f7 not in (0, 0x20)):
                    return illegal()
                a, b = use1(), imm_i & M32
                alt = f3 == 5 and f7 == 0x20
            else:
                if not (f7 == 0 or (f7 == 0x20 and f3 in (0, 5))):
                    return illegal()
                a, b = use1(), use2()
                alt = f7 == 0x20
            sh = b & 31
            result = {
                0: (a - b) if alt else (a + b),
                1: a << sh,
                2: int(sx(a, 32) < sx(b, 32)),
                3: int(a < b),
                4: a ^ b,
                5: (sx(a, 32) >> sh) if alt else (a >> sh),
                6: a | b,
                7: a & b,
            }[f3] & M32
        elif op == 0x0F:
            if f3 != 0:
                return illegal()
        elif op == 0x73:
            if f3 == 0:
                if insn == 0x00000073:
                    return trap(11, 0)
                if insn == 0x00100073:
                    return trap(3, 0)
                if insn == 0x30200073:
                    npc = self.mepc
                    self.mie_b, self.mpie = self.mpie, 1
                elif insn != 0x10500073:
                    return illegal()
            elif f3 == 4:
                return illegal()
            else:
                csr = insn >> 20
                src = rs1 if f3 & 4 else use1()
                wr_intent = (f3 & 3) == 1 or rs1 != 0
                old = self.csr_read(csr)
                if old is None or (wr_intent and csr >> 10 == 3):
                    return illegal()
                if rtl is not None and (csr in TIMING_CSRS or (csr == 0x344 and not self.mip_exact)):
                    old = rtl["rd_wdata"] if rd else old
                new = {1: src, 2: old | src, 3: old & ~src & M32}[f3 & 3]
                if wr_intent:
                    self.csr_write(csr, new)
                    no_instret = csr in (0xB02, 0xB82)
                result = old
        else:
            return illegal()

        if result is not None and rd != 0:
            self.x[rd] = result
            r["rd_addr"], r["rd_wdata"] = rd, result
        self.pc = npc
        r["pc_wdata"] = npc
        if not no_instret:
            self.minstret = (self.minstret + 1) & ((1 << 64) - 1)
        self.last_trap = False
        return r
