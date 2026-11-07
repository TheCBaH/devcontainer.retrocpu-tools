#!/bin/sh
# Assembles the exercisers and the K5 shim with the just-built AS and
# compares them with the independent M80-built .COM images.
# usage: build-diagnostics.sh <repo-root> <asl-bin-dir> <outdir>
set -eu
root=$1 bin=$2 out=$3
work=$(mktemp -d)
mkdir -p "$out"
cp "$root/sources/i8080-core/asm/8080PRE.MAC" "$root/sources/i8080-core/asm/8080EX1.MAC" "$work"
cd "$work"
for t in 8080PRE 8080EX1; do
    patch -p1 < "$root/patches/$t.patch"
done
"$bin/asl" -q -cpu 8080 -o 8080PRE.p 8080PRE.MAC
"$bin/asl" -q -cpu 8080 -o 8080EX1.p 8080EX1.MAC
"$bin/asl" -q -cpu 8080 -o shim.p "$root/asm/shim.asm"
# program images end where the last initialized byte of the source ends
"$bin/p2bin" -l 0 -r 0x100-0x4ff 8080PRE.p 8080PRE.COM
"$bin/p2bin" -l 0 -r 0x100-0x12b6 8080EX1.p 8080EX1.COM
"$bin/p2bin" -l 0 -r 0x0000-0x0002 shim.p shim-boot.bin
"$bin/p2bin" -l 0 -r 0x0005-0x0007 shim.p shim-bdos.bin
"$bin/p2bin" -l 0 -r 0xfe00-0xfe1b shim.p shim-handler.bin
cat shim-boot.bin > shim.bin
cat shim-bdos.bin shim-handler.bin >> shim.bin
for f in 8080PRE.COM 8080EX1.COM; do
    n=$(wc -c < "$f")
    ref="$root/sources/i8080-core/assets/$f"
    # the reference is padded to a 128-byte CP/M record with unrelated bytes
    head -c "$n" "$ref" | cmp - "$f" \
        || { echo "MISMATCH: $f differs from the independent image" >&2; exit 1; }
    pad=$(( $(wc -c < "$ref") - n ))
    [ "$pad" -ge 0 ] && [ "$pad" -lt 128 ] || { echo "unexpected padding for $f: $pad" >&2; exit 1; }
    echo "$f: $n bytes match the independent image (reference padding $pad bytes)"
done
cp 8080PRE.COM 8080EX1.COM shim-boot.bin shim-bdos.bin shim-handler.bin "$out"
