#!/bin/sh
# The shim assembled by the shipped AS must equal the shipped bytes.
# usage: check-shim.sh <dir-with-extracted-packages> <arch>
set -eu
root=$1 arch=$2
bin=$root/retrocpu-tools-$arch/bin
diag=$root/retrocpu-diagnostics
tmp=$(mktemp -d)
"$bin/asl" -q -cpu 8080 -o "$tmp/shim.p" "$diag/source/shim.asm"
"$bin/p2bin" -l 0 -r 0x0000-0x0002 "$tmp/shim.p" "$tmp/boot.bin" >/dev/null
"$bin/p2bin" -l 0 -r 0x0005-0x0007 "$tmp/shim.p" "$tmp/bdos.bin" >/dev/null
"$bin/p2bin" -l 0 -r 0xfe00-0xfe1b "$tmp/shim.p" "$tmp/handler.bin" >/dev/null
cmp "$tmp/boot.bin" "$diag/shim-boot.bin"
cmp "$tmp/bdos.bin" "$diag/shim-bdos.bin"
cmp "$tmp/handler.bin" "$diag/shim-handler.bin"
echo "$(. /etc/os-release && echo "$PRETTY_NAME"): shim bytes rebuilt by the shipped AS match"
