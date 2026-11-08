#!/bin/sh
# Builds Verilator from the pinned source, then a static vm80a_sim from the
# harness and vm80a_core. Runs in the Alpine builder.
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
"$vprefix/bin/verilator" --binary --timing --trace --top-module i8080_tb --x-initial unique \
    -Wno-fatal -Wno-lint -Wno-style -Mdir obj -o vm80a_sim -LDFLAGS -static \
    "$root/hdl/vm80a/harness.v" "$root/sources/vm80a/org/rtl/vm80a.v" >verilator.log 2>&1 \
    || { cat verilator.log; exit 1; }
strip -o "$out/bin/vm80a_sim" obj/vm80a_sim
"$vprefix/bin/verilator" --version > "$out/verilator-version"
ccache -s
