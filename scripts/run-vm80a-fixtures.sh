#!/bin/sh
# Runs the packaged vm80a_sim (FST) and vm80a_sim_fast on the fixtures in an
# argument directory (default <package>/fixtures): unseeded and with Verilator
# random-initial seeds. Writes <out>/<variant>/seed-<s>/<id>.{trace,result,mem,ioout},
# and an FST of every vm80a_sim run.
# usage: run-vm80a-fixtures.sh <package-dir> <outdir> [<args-dir> [<seeds>]]
set -eu
p=$1 o=$2 a=${3:-$1/fixtures} seeds=${4:-}
for variant in vm80a_sim vm80a_sim_fast; do
    for f in "$a"/*.args; do
        id=$(basename "$f" .args)
        if [ -n "$seeds" ]; then s=$seeds; else
            case $id in mvi-*) s="none 1 2 3 4 5" ;; *) s="none 1 2" ;; esac
        fi
        for seed in $s; do
            d=$o/$variant/seed-$seed
            mkdir -p "$d"
            rnd=
            [ "$seed" = none ] || rnd="+verilator+rand+reset+2 +verilator+seed+$seed"
            fst=
            [ "$variant" != vm80a_sim ] || fst="+fst=$d/$id.fst"
            # shellcheck disable=SC2046,SC2086
            "$p/bin/$variant" $(sed -e "s|@A@|$a|g; s|@O@|$d|g" "$f") $rnd $fst >/dev/null
        done
    done
done
