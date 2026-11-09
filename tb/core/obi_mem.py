"""OBI slave models for the core testbench.

Both ports share one 64 KB memory. Each port grants and answers per the
spec section 4 subset; in random mode gnt is withheld at random and rvalid
comes 1..4 cycles after the handshake. The model also checks the master
side of the protocol (stable request until gnt, one outstanding).
"""

RAM_SIZE = 0x10000
SIM_EXIT = 0x1000F000
SIM_PUTC = 0x1000F004
SIM_IRQ = 0x1000F010   # tb-only: bit0 drives irq_timer, bit1 irq_external


class Memory:
    def __init__(self, image: bytes):
        self.ram = bytearray(RAM_SIZE)
        self.ram[: len(image)] = image
        self.exit_code = None
        self.irq_bits = 0
        self.console = []

    def read_word(self, addr: int) -> int:
        a = addr & ~3
        if a + 4 <= RAM_SIZE:
            return int.from_bytes(self.ram[a: a + 4], "little")
        return 0

    def write(self, addr: int, be: int, wdata: int):
        a = addr & ~3
        if a + 4 <= RAM_SIZE:
            for i in range(4):
                if be >> i & 1:
                    self.ram[a + i] = (wdata >> (8 * i)) & 0xFF
        elif a == SIM_EXIT:
            self.exit_code = wdata
        elif a == SIM_PUTC:
            self.console.append(chr(wdata & 0xFF))
        elif a == SIM_IRQ:
            self.irq_bits = wdata & 3


class SocMemory(Memory):
    """SoC address map (spec 5): RAM aliases addr & 0xFFFF for addr[31:28] == 0, and
    the peripherals come from a golden-ISS instance used only as a device model."""

    def __init__(self, image: bytes, dev):
        super().__init__(image)
        self.dev = dev

    def read_word(self, addr):
        if addr >> 28 == 0:
            a = addr & (RAM_SIZE - 4)
            return int.from_bytes(self.ram[a: a + 4], "little")
        return self.dev._bus_read(addr)

    def write(self, addr, be, wdata):
        if addr >> 28 == 0:
            super().write(addr & (RAM_SIZE - 4), be, wdata)
            return
        self.dev._bus_write(addr & ~3, wdata, be)
        self.exit_code = self.dev.exit_code

    def tick(self):
        self.dev.mtime = (self.dev.mtime + 1) & ((1 << 64) - 1)

    @property
    def irq_bits(self):
        return int(self.dev.mtime >= self.dev.mtimecmp)

    @irq_bits.setter
    def irq_bits(self, v):
        pass


class ObiPort:
    def __init__(self, dut, prefix, mem, rng, random_lat, writable):
        self.dut, self.p, self.mem, self.rng = dut, prefix, mem, rng
        self.random_lat, self.writable = random_lat, writable
        self.pending = None      # [cycles_left, rdata]
        self.rvalid_now = False
        self.held = None         # request seen without gnt last cycle
        self.gnt_now = 0
        self.handshakes = 0
        self.last_write = None   # (addr, be, wdata) of this cycle's write handshake

    def sig(self, name):
        return getattr(self.dut, f"{self.p}_{name}")

    def drive(self):
        """Falling edge: present this cycle's gnt / rvalid."""
        self.rvalid_now = False
        rdata = self.rng.getrandbits(32)  # garbage when not valid
        if self.pending is not None:
            self.pending[0] -= 1
            if self.pending[0] == 0:
                self.rvalid_now = True
                rdata = self.pending[1]
                self.pending = None
        self.gnt_now = int(self.rng.random() < 0.6) if self.random_lat else 1
        self.sig("gnt").value = self.gnt_now
        self.sig("rvalid").value = int(self.rvalid_now)
        self.sig("rdata").value = rdata

    def sample(self):
        """After comb settles: check and perform the handshake."""
        self.last_write = None
        req = int(self.sig("req").value)
        addr = int(self.sig("addr").value)
        if self.writable:
            we, be, wdata = (int(self.sig("we").value), int(self.sig("be").value),
                             int(self.sig("wdata").value))
        else:
            we, be, wdata = 0, 0xF, 0
        if self.held is not None:
            assert req, f"{self.p}: req dropped before gnt"
            assert self.held == (addr, we, be, wdata if we else 0), \
                f"{self.p}: request changed before gnt {self.held} -> {(addr, we, be, wdata)}"
        if req and self.gnt_now:
            assert self.pending is None, f"{self.p}: second outstanding transaction"
            assert addr & 3 == 0, f"{self.p}: unaligned OBI address {addr:#x}"
            if we:
                assert be != 0, f"{self.p}: write with empty byte enable"
                self.mem.write(addr, be, wdata)
                self.last_write = (addr, be, wdata)
                rdata = 0
            else:
                rdata = self.mem.read_word(addr)
            lat = self.rng.randint(1, 4) if self.random_lat else 1
            self.pending = [lat, rdata]
            self.handshakes += 1
            self.held = None
        elif req:
            self.held = (addr, we, be, wdata if we else 0)
        else:
            self.held = None
