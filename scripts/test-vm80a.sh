#!/bin/bash
# Runs the MVI/STA/HLT fixtures (no waits, two waits on the STA write) on the
# vm80a harness: Icarus against the hand-written traces, Verilator (several
# --x-initial unique seeds) against Icarus, plus VCD and negative checks.
# usage: test-vm80a.sh <build-dir>   (see the vm80a-test target)
set -uo pipefail
b=$1
fx=fixtures/mvi-sta-hlt
out=$b/results
vm80a() { python3 -I scripts/vm80a.py "$@"; }
icarus=(vvp "$b/icarus/tb.vvp")
verilator=("$b/verilator/vm80a_sim")
failed=0
check() { # description, command...
    local what=$1; shift
    if "$@" > "$out/check.log" 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; sed 's/^/        /' "$out/check.log"; failed=1; fi
}
mkdir -p "$out"

for f in mvi-sta-hlt mvi-sta-hlt-wait2; do
    echo "== $f"
    check "icarus: result matches manifest, no X" vm80a run $fx/$f.json "$out/icarus" -- "${icarus[@]}"
    check "icarus: pin trace equals the hand-written trace" vm80a compare $fx/$f.trace "$out/icarus/$f.trace"
    check "icarus: exactly one write (2000 2a)" test "$(grep -c '^write=' "$out/icarus/$f.result")" = 1 \
        -a "$(grep '^write=' "$out/icarus/$f.result")" = "write=2000 2a"
    for seed in none 1 2 3 4 5; do
        d="$out/verilator-$seed"
        if [ "$seed" = none ]; then s=(); else s=(--seed "$seed"); fi
        check "verilator seed $seed: result matches manifest" vm80a run $fx/$f.json "$d" "${s[@]}" -- "${verilator[@]}"
        check "verilator seed $seed: trace identical to icarus" cmp "$out/icarus/$f.trace" "$d/$f.trace"
        check "verilator seed $seed: memory dump identical to icarus" cmp "$out/icarus/$f.mem" "$d/$f.mem"
    done
    # an idle data bus of 00 instead of ff changes only a masked address byte
    # (the last T-state of the STA fetch shows 00xx), so the masked hand
    # trace still matches; the strict X check of `run` is not applied
    check "icarus: idle data input 00 still matches the hand-written trace" sh -c \
        "mkdir -p $out/idle00 && ${icarus[*]} +image=$out/icarus/$f.img +ram_start=0 +ram_size=4000 \
         +stim=$fx/$f.stim +trace=$out/idle00/$f.trace +idle_din=00 >/dev/null \
         && python3 -I scripts/vm80a.py compare $fx/$f.trace $out/idle00/$f.trace"
    check "halt-cycle address is the HLT address 0005 (finding: hand trace says 0006)" \
        grep -q '^halt_a=0005$' "$out/icarus/$f.result"
done

echo "== packaged fixture image"
check "mvi-sta-hlt.hex holds the manifest image bytes" python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
h = bytes.fromhex("".join(open(sys.argv[2]).read().split()))
sys.exit(0 if h.hex() == m["image"]["hex"] else "hex file differs from the manifest")' $fx/mvi-sta-hlt.json $fx/mvi-sta-hlt.hex

echo "== VCD"
for sim in icarus verilator; do
    if [ $sim = icarus ]; then cmd=("${icarus[@]}"); else cmd=("${verilator[@]}"); fi
    VM80A_EXTRA="+vcd=$out/$sim.vcd" check "$sim: VCD written with signals and time" \
        sh -c "python3 -I scripts/vm80a.py run $fx/mvi-sta-hlt.json $out/vcd-$sim -- ${cmd[*]} && grep -q '^\$enddefinitions' $out/$sim.vcd && grep -q '^#' $out/$sim.vcd"
done

echo "== memory dump range and raw bytes"
img=$out/icarus/mvi-sta-hlt.img
dumprun() { "${cmd[@]}" +image="$img" +ram_start=0 +ram_size=4000 +stim=$fx/mvi-sta-hlt.stim +result="$d/r" "$@" > /dev/null; }
dump_full() { dumprun +memdump="$d/full.hex" +membin="$d/full.bin" \
    && python3 -I scripts/vm80a.py bincheck "$d/full.hex" "$d/full.bin" 0 10000; }
dump_part() { dumprun +dump_start=1ffe +dump_size=6 +membin="$d/part.bin" \
    && python3 -I scripts/vm80a.py bincheck "$d/full.hex" "$d/part.bin" 1ffe 6 && [ "$(wc -c < "$d/part.bin")" = 6 ]; }
dump_bad() { dumprun +dump_start=ffff +dump_size=2 +membin="$d/bad.bin"; grep -q '^error=dump range' "$d/r"; }
for sim in icarus verilator; do
    if [ $sim = icarus ]; then cmd=("${icarus[@]}"); else cmd=("${verilator[@]}"); fi
    d=$out/dump-$sim; mkdir -p "$d"
    check "$sim: whole-space binary dump equals the hex dump" dump_full
    check "$sim: ranged binary dump (1ffe+6, NUL bytes kept) equals the hex slice" dump_part
    check "$sim: a dump range beyond 64 KiB is an error" dump_bad
done

echo "== negative checks (the comparison must fail)"
nw=$fx/mvi-sta-hlt.trace
mut() { sed "$1" "$nw" > "$out/mutated.trace"; ! vm80a compare "$out/mutated.trace" "$out/icarus/mvi-sta-hlt.trace" > "$out/neg.log" 2>&1 && cat "$out/neg.log"; }
check "wrong write data (n=19 do) is caught" mut 's/^19 ~~~~ 2a /19 ~~~~ 2b /'
check "wrong sync (n=4) is caught" mut 's/^4  0001 82 zz 1 /4  0001 82 zz 0 /'
check "wrong ready (n=9) is caught" mut 's/^9  0002 zz 32 0 0 1 0 0 0 1 /9  0002 zz 32 0 0 1 0 0 0 0 /'
check "wait2 trace does not match the no-wait run" sh -c \
    "! python3 -I scripts/vm80a.py compare $fx/mvi-sta-hlt-wait2.trace $out/icarus/mvi-sta-hlt.trace"
check "a run with a bad image hash is rejected" sh -c \
    "sed 's/990ab981/990ab982/' $fx/mvi-sta-hlt.json > $out/bad.json && ! python3 -I scripts/vm80a.py run $out/bad.json $out/bad -- ${icarus[*]}"

[ $failed = 0 ] && echo "vm80a: all checks passed" || { echo "vm80a: FAILED" >&2; exit 1; }
