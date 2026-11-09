"""Assemble and link tb/core/progs/*.S with the lowRISC clang toolchain.

Output per program in tb/core/build/: <name>.elf, <name>.bin, <name>.sym.
"""
import os
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
PROGS = HERE / "progs"
BUILD = HERE / "build"
TOOLS = pathlib.Path(os.environ.get("RISCV_BIN", pathlib.Path.home() / "tools/riscv/bin"))


def tool(name):
    p = TOOLS / name
    return str(p) if p.exists() else (shutil.which(name) or name)


def build(name: str) -> pathlib.Path:
    src = PROGS / f"{name}.S"
    BUILD.mkdir(exist_ok=True)
    elf, binf, sym = (BUILD / f"{name}{ext}" for ext in (".elf", ".bin", ".sym"))
    deps = [src, PROGS / "common.h"]
    if binf.exists() and all(binf.stat().st_mtime >= d.stat().st_mtime for d in deps):
        return binf
    subprocess.run([tool("riscv32-unknown-elf-clang"), "-march=rv32im_zicsr", "-mabi=ilp32",
                    "-mno-relax", "-nostdlib", "-static", "-Wl,-Ttext=0", "-Wl,-e,_start",
                    f"-I{PROGS}", "-o", str(elf), str(src)], check=True)
    subprocess.run([tool("riscv32-unknown-elf-objcopy"), "-O", "binary", str(elf), str(binf)],
                   check=True)
    nm = subprocess.run([tool("llvm-nm"), str(elf)], check=True, capture_output=True, text=True)
    sym.write_text(nm.stdout)
    return binf


def load(name: str):
    """Return (image bytes, {symbol: address})."""
    binf = build(name)
    syms = {}
    for line in binf.with_suffix(".sym").read_text().splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
    return binf.read_bytes(), syms


if __name__ == "__main__":
    for n in sys.argv[1:] or [p.stem for p in PROGS.glob("*.S")]:
        print(build(n))
