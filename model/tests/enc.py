"""Minimal RV32IM/Zicsr encoder for ISS unit tests."""
M32 = 0xFFFFFFFF

R_OPS = {"add": (0, 0), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0), "sltu": (3, 0),
         "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20), "or": (6, 0), "and": (7, 0),
         "mul": (0, 1), "mulh": (1, 1), "mulhsu": (2, 1), "mulhu": (3, 1), "div": (4, 1),
         "divu": (5, 1), "rem": (6, 1), "remu": (7, 1)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
B_OPS = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
L_OPS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
S_OPS = {"sb": 0, "sh": 1, "sw": 2}
CSR_OPS = {"csrrw": 1, "csrrs": 2, "csrrc": 3, "csrrwi": 5, "csrrsi": 6, "csrrci": 7}

ECALL, EBREAK, MRET, WFI, FENCE, NOP = 0x00000073, 0x00100073, 0x30200073, 0x10500073, \
    0x0FF0000F, 0x00000013


def r(op, rd, rs1, rs2):
    f3, f7 = R_OPS[op]
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | 0x33


def i(op, rd, rs1, imm):
    if op in SH_OPS:
        f3, f7 = SH_OPS[op]
        return f7 << 25 | (imm & 31) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | 0x13
    return (imm & 0xFFF) << 20 | rs1 << 15 | I_OPS[op] << 12 | rd << 7 | 0x13


def lui(rd, imm20):
    return (imm20 & 0xFFFFF) << 12 | rd << 7 | 0x37


def auipc(rd, imm20):
    return (imm20 & 0xFFFFF) << 12 | rd << 7 | 0x17


def jal(rd, off):
    o = off & 0x1FFFFF
    return ((o >> 20 & 1) << 31 | (o >> 1 & 0x3FF) << 21 | (o >> 11 & 1) << 20
            | (o >> 12 & 0xFF) << 12 | rd << 7 | 0x6F)


def jalr(rd, rs1, imm):
    return (imm & 0xFFF) << 20 | rs1 << 15 | rd << 7 | 0x67


def b(op, rs1, rs2, off):
    o = off & 0x1FFF
    return ((o >> 12 & 1) << 31 | (o >> 5 & 0x3F) << 25 | rs2 << 20 | rs1 << 15
            | B_OPS[op] << 12 | (o >> 1 & 0xF) << 8 | (o >> 11 & 1) << 7 | 0x63)


def load(op, rd, rs1, imm):
    return (imm & 0xFFF) << 20 | rs1 << 15 | L_OPS[op] << 12 | rd << 7 | 0x03


def store(op, rs2, rs1, imm):
    imm &= 0xFFF
    return (imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | S_OPS[op] << 12 | (imm & 31) << 7 | 0x23


def csr(op, rd, addr, rs1_or_uimm):
    return addr << 20 | rs1_or_uimm << 15 | CSR_OPS[op] << 12 | rd << 7 | 0x73


def li(rd, value):
    """lui + addi pair loading a 32-bit constant."""
    value &= M32
    lo = value & 0xFFF
    lo = lo - 0x1000 if lo & 0x800 else lo
    hi = ((value - lo) >> 12) & 0xFFFFF
    return [lui(rd, hi), i("addi", rd, rd, lo)]
