#!/bin/sh
# Builds static altairz80 from a pristine source tree into $2.
# usage: build-simh.sh <source-dir> <install-prefix>
set -eu
src=$1 prefix=$2
work=$(mktemp -d)
mkdir "$work/src"
cp -a "$src/." "$work/src"
rm -f "$work/src/.git"
cmake -S "$work/src" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DWITH_NETWORK=OFF -DWITH_PCAP=OFF -DWITH_SLIRP=OFF -DWITH_VDE=OFF \
    -DWITH_TAP=OFF -DWITH_VIDEO=OFF -DWITH_REGEX=OFF -DWITH_ASYNC=OFF \
    -DCMAKE_C_FLAGS=-D_LARGEFILE64_SOURCE -DCMAKE_EXE_LINKER_FLAGS=-static
cmake --build "$work/build" --target altairz80
mkdir -p "$prefix/bin"
install -m755 "$work/src/BIN/altairz80" "$prefix/bin/altairz80"
