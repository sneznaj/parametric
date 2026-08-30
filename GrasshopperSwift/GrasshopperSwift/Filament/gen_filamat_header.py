#!/usr/bin/env python3
"""Compile a Filament .mat source into a compiled .filamat, then emit it as a
C byte-array header (matching the studio_pbr_filamat.h / studio_subsurface_filamat.h
format already embedded in FilamentBridge.mm).

The app embeds materials as compiled-in byte arrays rather than loading .mat/.filamat
files from the bundle at runtime, so this script's output is checked in — run it
again (via `make materials`) only after editing a .mat source file.

Usage: gen_filamat_header.py <name> <input.mat> <output.h>
  name — the material's base identifier; emits `<name>_filamat` / `<name>_filamat_len`.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    name, mat_path, header_path = sys.argv[1], sys.argv[2], sys.argv[3]

    matc = Path(__file__).resolve().parents[2] / "filament-framework" / "bin" / "matc"
    if not matc.exists():
        sys.exit(f"matc not found at {matc}")

    with tempfile.NamedTemporaryFile(suffix=".filamat") as tmp:
        subprocess.run(
            [str(matc), "-a", "metal", "-p", "desktop", "-o", tmp.name, mat_path],
            check=True,
        )
        data = Path(tmp.name).read_bytes()

    symbol = f"{name}_filamat"
    with open(header_path, "w") as f:
        f.write(f"unsigned char {symbol}[] = {{\n")
        for i in range(0, len(data), 12):
            chunk = data[i:i + 12]
            f.write("  " + ", ".join(f"0x{b:02x}" for b in chunk) + ",\n")
        f.write("};\n")
        f.write(f"unsigned int {symbol}_len = {len(data)};\n")

    print(f"wrote {header_path} ({len(data)} bytes)")

if __name__ == "__main__":
    main()
