#!/bin/sh
# Runs the packaged vm80a_sim on the MVI/STA/HLT fixtures: unseeded and with
# Verilator random-initial seeds. Writes <out>/seed-<s>/<fixture>.{trace,result,mem}.
# usage: run-vm80a-fixtures.sh <package-dir> <outdir>
set -eu
p=$1 o=$2
for seed in none 1 2 3 4 5; do
    d=$o/seed-$seed
    mkdir -p "$d"
    rnd=
    [ "$seed" = none ] || rnd="+verilator+rand+reset+2 +verilator+seed+$seed"
    for f in mvi-sta-hlt mvi-sta-hlt-wait2; do
        # shellcheck disable=SC2086
        "$p/bin/vm80a_sim" +image="$p/fixtures/mvi-sta-hlt.hex" +ram_start=0 +ram_size=4000 \
            +stim="$p/fixtures/$f.stim" +max_tstates=1000 +trace="$d/$f.trace" \
            +result="$d/$f.result" +memdump="$d/$f.mem" $rnd >/dev/null
    done
done
