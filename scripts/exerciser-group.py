#!/usr/bin/env python3
"""Cut one test group out of 8080EX1.COM (for parallel runs).

  exerciser-group.py list <8080EX1.COM>            group number, descriptor address, name
  exerciser-group.py cut <8080EX1.COM> <n> <out>   .COM that runs only group n (0-based)

The program walks a table of descriptor addresses ending in 0 (`tests:`),
found through the `lxi h,tests` after the start-up code; the cut image has
that table holding group n only. Nothing else is changed.
"""
import re
import sys

ORIGIN = 0x100


def table(img):
    m = re.search(rb"\x2a\x06\x00\xf9\x11..\x0e\x09\xcd..\x21(..)", img, re.S)
    if not m:
        raise SystemExit("start-up sequence (lhld 6; sphl; lxi d; mvi c,9; call; lxi h,tests) not found")
    base = int.from_bytes(m.group(1), "little") - ORIGIN
    entries = []
    while True:
        e = int.from_bytes(img[base + 2 * len(entries):base + 2 * len(entries) + 2], "little")
        if e == 0:
            return base, entries
        entries.append(e)


def name(img, desc):
    # the group's message is the 30-byte, '$'-terminated text after the 20-byte test vector fields
    blob = img[desc - ORIGIN:desc - ORIGIN + 400]
    m = re.search(rb"([ -~]{3,}?)\$", blob)
    return m.group(1).decode().strip() if m else "?"


def main(argv):
    if len(argv) >= 3 and argv[1] == "list":
        img = open(argv[2], "rb").read()
        base, entries = table(img)
        for i, e in enumerate(entries):
            print(i, "%04x" % e, name(img, e))
        return 0
    if len(argv) == 5 and argv[1] == "cut":
        img = bytearray(open(argv[2], "rb").read())
        base, entries = table(img)
        n = int(argv[3])
        if not 0 <= n < len(entries):
            raise SystemExit(f"group {n} out of range (0..{len(entries) - 1})")
        img[base:base + 4] = entries[n].to_bytes(2, "little") + b"\x00\x00"
        open(argv[4], "wb").write(img)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
