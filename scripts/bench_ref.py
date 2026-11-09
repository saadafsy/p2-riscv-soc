#!/usr/bin/env python3
"""Reference results for sw/c/bench.c (CRC_EXPECT, MAT_EXPECT)."""
import zlib

M32 = 0xFFFFFFFF


def xorshift_buf(n=4096, x=0x12345678):
    out = bytearray()
    for _ in range(n):
        x ^= (x << 13) & M32
        x ^= x >> 17
        x ^= (x << 5) & M32
        out.append(x & 0xFF)
    return bytes(out)


def matmul_checksum(m=8):
    a = [[i * m + j - 20 for j in range(m)] for i in range(m)]
    b = [[(i - j) * 3 + 1 for j in range(m)] for i in range(m)]
    s = 0
    for i in range(m):
        for j in range(m):
            c = sum(a[i][k] * b[k][j] for k in range(m))
            s += (c & M32) * (i * m + j + 1)
    return s & M32


if __name__ == "__main__":
    print(f"CRC_CHECK  0x{zlib.crc32(b'123456789'):08X}")
    print(f"CRC_EXPECT 0x{zlib.crc32(xorshift_buf()):08X}")
    print(f"MAT_EXPECT 0x{matmul_checksum():08X}")
