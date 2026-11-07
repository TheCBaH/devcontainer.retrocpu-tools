#!/bin/sh
# Packs the built tools and diagnostics with their licences.
# usage: package.sh <repo-root> <meta-dir> <prefix> <dist> <arch>
set -eu
root=$1 meta=$2 prefix=$3 dist=$4 arch=$5
mkdir -p "$dist"
stage=$(mktemp -d)

t=$stage/retrocpu-tools-$arch
mkdir -p "$t/bin"
cp "$prefix/bin/"* "$t/bin/"
"$root/scripts/collect-licenses.sh" "$root" "$meta" "$t/licenses" tools
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner -cf - "retrocpu-tools-$arch" \
    | xz -9e > "$dist/retrocpu-tools-linux-$arch-musl.tar.xz"

d=$stage/retrocpu-diagnostics
mkdir -p "$d"
cp "$prefix/share/diagnostics/"* "$root/scripts/check-shim.sh" "$root/run/8080PRE.ini" "$root/run/8080EX1.ini" "$d/"
mkdir -p "$d/source/patches"
cp "$root/sources/i8080-core/asm/8080PRE.MAC" "$root/sources/i8080-core/asm/8080EX1.MAC" "$root/asm/shim.asm" "$d/source/"
cp "$root/patches/"*.patch "$d/source/patches/"
"$root/scripts/collect-licenses.sh" "$root" "$meta" "$d/licenses" diagnostics
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner -cf - retrocpu-diagnostics \
    | xz -9e > "$dist/retrocpu-diagnostics-$arch.tar.xz"
