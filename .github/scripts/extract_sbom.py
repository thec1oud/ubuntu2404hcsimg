#!/usr/bin/env python3
"""
extract_sbom.py — Parse /var/lib/dpkg/status from stdin and write a TSV SBOM.

Usage:
    virt-cat -a <image.qcow2> /var/lib/dpkg/status | python3 extract_sbom.py <output.tsv>

The image is accessed READ-ONLY via virt-cat; it is never modified.
Outputs a TSV with header: package  version  architecture
Only packages with "Status: install ok installed" are included.
"""
import sys

if len(sys.argv) < 2:
    print("usage: extract_sbom.py <output.tsv>", file=sys.stderr)
    sys.exit(1)

outfile = sys.argv[1]
pkg = ver = arch = status = ""
installed: list[tuple[str, str, str]] = []

for raw in sys.stdin:
    line = raw.rstrip("\n")
    if line.startswith("Package: "):
        pkg = line[9:]
    elif line.startswith("Version: "):
        ver = line[9:]
    elif line.startswith("Architecture: "):
        arch = line[14:]
    elif line.startswith("Status: "):
        status = line[8:]
    elif line == "" and pkg:
        if "install ok installed" in status:
            installed.append((pkg, ver, arch))
        pkg = ver = arch = status = ""

# Flush the last record: dpkg/status does not end with a trailing blank line.
if pkg and "install ok installed" in status:
    installed.append((pkg, ver, arch))

installed.sort()

with open(outfile, "w") as fh:
    fh.write("package\tversion\tarchitecture\n")
    for p, v, a in installed:
        fh.write(f"{p}\t{v}\t{a}\n")

print(f"SBOM: {len(installed)} installed packages → {outfile}", flush=True)
