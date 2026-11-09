#!/usr/bin/env python3
"""Raw binary (image at address 0) -> $readmemh file: one 32-bit little-endian word per
line, 8 hex digits, no @ records, padded with zeros to the full RAM (16384 words)."""
import sys

RAM_WORDS = 16384


def main(src, dst, words=RAM_WORDS):
    data = open(src, "rb").read()
    if len(data) > words * 4:
        sys.exit(f"{src}: {len(data)} bytes does not fit in {words * 4} bytes of RAM")
    data += bytes(words * 4 - len(data))
    with open(dst, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: bin2hex.py in.bin out.hex")
    main(sys.argv[1], sys.argv[2])
