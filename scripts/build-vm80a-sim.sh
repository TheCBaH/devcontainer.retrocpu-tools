#!/bin/sh
# Builds Verilator from the pinned source, then the static vm80a_sim (FST),
# vm80a_sim_fast (no waveforms) and fstdump. Runs in the Alpine builder.
# Keep the Verilator flags in step with the Makefile (VM80A_VFLAGS).
# usage: build-vm80a-sim.sh <repo-root> <verilator-src> <verilator-prefix> <out-prefix>
set -eu
root=$1 vsrc=$2 vprefix=$3 out=$4
cd "$vsrc"
autoconf
./configure --prefix="$vprefix" CXX="ccache g++" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
mkdir -p "$out/bin" /tmp/vm80a
cd /tmp/vm80a
rtl="$root/hdl/vm80a/harness.v $root/sources/vm80a/org/rtl/vm80a.v"
flags="--binary --timing --top-module i8080_tb --x-initial unique -O3 -CFLAGS -O3 -Wno-fatal -Wno-lint -Wno-style -LDFLAGS -static"
# shellcheck disable=SC2086
"$vprefix/bin/verilator" $flags --trace-fst -DVM80A_FST -Mdir obj -o vm80a_sim \
    "$root/hdl/vm80a/trace.vlt" $rtl >verilator.log 2>&1 || { cat verilator.log; exit 1; }
# shellcheck disable=SC2086
"$vprefix/bin/verilator" $flags -Mdir obj-fast -o vm80a_sim_fast $rtl >verilator-fast.log 2>&1 \
    || { cat verilator-fast.log; exit 1; }
strip -o "$out/bin/vm80a_sim" obj/vm80a_sim
strip -o "$out/bin/vm80a_sim_fast" obj-fast/vm80a_sim_fast
g=$vsrc/include/gtkwave
gcc -O2 -static -DFST_CONFIG_INCLUDE='"fst_config.h"' -I"$g" -o "$out/bin/fstdump" "$root/scripts/fstdump.c" \
    "$g/fstapi.c" "$g/lz4.c" "$g/fastlz.c" -lz -lpthread
strip "$out/bin/fstdump"
"$vprefix/bin/verilator" --version > "$out/verilator-version"
ccache -s
