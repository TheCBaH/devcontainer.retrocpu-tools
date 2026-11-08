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
fast=("$b/verilator/vm80a_sim_fast")
fstdump=$b/fstdump
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

echo "== bus cycles by status: IN/OUT with the K5 shim console, INTA (RST and CALL)"
for f in io-console:io-console inta:inta-rst inta:inta-call; do
    dir=${f%%:*} id=${f##*:}
    m=fixtures/$dir/$id.json
    check "icarus $id: result matches manifest (io_out, instructions, memory digest)" vm80a run $m "$out/icarus-io" -- "${icarus[@]}"
    for seed in none 1 2; do
        if [ "$seed" = none ]; then s=(); else s=(--seed "$seed"); fi
        check "verilator $id seed $seed: result matches manifest" vm80a run $m "$out/verilator-io-$seed" "${s[@]}" -- "${verilator[@]}"
        for ext in trace mem ioout; do
            check "verilator $id seed $seed: $ext identical to icarus" cmp "$out/icarus-io/$id.$ext" "$out/verilator-io-$seed/$id.$ext"
        done
        check "vm80a_sim_fast $id seed $seed: result matches manifest" vm80a run $m "$out/fast-io-$seed" "${s[@]}" -- "${fast[@]}"
        for ext in trace mem ioout; do
            check "vm80a_sim_fast $id seed $seed: $ext identical to icarus" cmp "$out/icarus-io/$id.$ext" "$out/fast-io-$seed/$id.$ext"
        done
    done
done
r=$out/icarus-io
check "io-console: 6 OUTs and 3 INs reach the port table, 5 memory writes only (an OUT never writes memory)" sh -c \
    "grep -qx 'outputs=6' $r/io-console.result && grep -qx 'inputs=3' $r/io-console.result && grep -qx 'writes=5' $r/io-console.result && grep -qx 'port_dup_errors=0' $r/io-console.result"
check "io-console: the console text on port 01 is HIB" sh -c \
    "test \"\$(python3 -I -c 'import sys; print(\"\".join(chr(int(l.split()[1],16)) for l in open(sys.argv[1]) if l.split()[0]==\"01\"))' $r/io-console.ioout)\" = HIB"
check "inta-rst: one INTA cycle; inta-call: three, six T-states longer" sh -c \
    "grep -qx 'intas=1' $r/inta-rst.result && grep -qx 'intas=3' $r/inta-call.result && \
     test \$(( \$(sed -n 's/^tstates=//p' $r/inta-call.result) - \$(sed -n 's/^tstates=//p' $r/inta-rst.result) )) = 6"
check "INTA with no byte left is a fault, not a memory read" sh -c "
    grep -v '^inta' fixtures/inta/inta-rst.stim > $out/no-inta.stim
    ${icarus[*]} +image=$r/inta-rst.img +ram_start=0 +ram_size=10000 +boot=$out/icarus-io/inta-rst.boot +boot_len=14 +boot_pc=100 \
        +stim=$out/no-inta.stim +stop_ports=ff +halt_stop=0 +max_tstates=2000 +result=$out/no-inta.result >/dev/null
    grep -q '^stop_reason=fault' $out/no-inta.result && grep -q '^fault=inta ' $out/no-inta.result"
check "wrong io_out expectation is caught" sh -c \
    "sed 's/\"0x31\", \"0x55\"/\"0x31\", \"0x56\"/' fixtures/inta/inta-rst.json > $out/bad-io.json && ! python3 -I scripts/vm80a.py run $out/bad-io.json $out/bad-io -- ${icarus[*]}"
check "the built-in shim equals the K5 bytes (0000, 0005, FE00)" sh -c "
    ${icarus[*]} +shim=1 +ram_start=0 +ram_size=10000 +memdump=$out/shim.mem +max_tstates=200 >/dev/null
    python3 -I -c 'import sys; m=bytes.fromhex(\"\".join(open(sys.argv[1]).read().split())); h=\"79fe02ca0efefe09ca12fed3fec97bd301c91afe24c8d30113c312fe\"
sys.exit(0 if m[0:3].hex()==\"d3ff76\" and m[5:8].hex()==\"c300fe\" and m[0xfe00:0xfe00+28].hex()==h and not any(m[8:0xfe00]) else \"shim bytes differ\")' $out/shim.mem"

echo "== packaged fixture image"
check "mvi-sta-hlt.hex holds the manifest image bytes" python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
h = bytes.fromhex("".join(open(sys.argv[2]).read().split()))
sys.exit(0 if h.hex() == m["image"]["hex"] else "hex file differs from the manifest")' $fx/mvi-sta-hlt.json $fx/mvi-sta-hlt.hex

echo "== VCD (Icarus), FST (vm80a_sim) and the register set"
VM80A_EXTRA="+vcd=$out/icarus.vcd" check "icarus: VCD written with signals and time" \
    sh -c "python3 -I scripts/vm80a.py run $fx/mvi-sta-hlt.json $out/vcd-icarus -- ${icarus[*]} && grep -q '^\$enddefinitions' $out/icarus.vcd && grep -q '^#' $out/icarus.vcd"
VM80A_EXTRA="+fst=$out/fixture.fst" check "vm80a_sim: FST written" \
    sh -c "python3 -I scripts/vm80a.py run $fx/mvi-sta-hlt.json $out/fst-run -- ${verilator[*]} && test -s $out/fixture.fst"
regs="acc:8 r16_bc:16 r16_de:16 r16_hl:16 r16_sp:16 r16_pc:16 r16_wz:16 psw_z:1 psw_s:1 psw_p:1 psw_c:1 psw_ac:1"
"$fstdump" "$out/fixture.fst" vars > "$out/fixture.vars"
for rw in $regs; do
    check "FST holds i8080_tb.dut.${rw%%:*} with width ${rw##*:}" grep -qx "i8080_tb.dut.${rw%%:*} ${rw##*:}" "$out/fixture.vars"
done
check "FST holds the pins (i8080_tb.pin_a, pin_sync, pin_dbin, pin_wr_n)" sh -c \
    "for p in pin_a pin_sync pin_dbin pin_wr_n; do grep -q \"^i8080_tb.\$p \" $out/fixture.vars || exit 1; done"
check "FST: the accumulator register ends at 2a" sh -c \
    "test \"\$($fstdump $out/fixture.fst final i8080_tb.dut.acc)\" = 'i8080_tb.dut.acc 2a'"
"$fstdump" "$out/fixture.fst" changes i8080_tb.dut.r16_pc > "$out/fixture.pc"
echo "      (r16_pc changes: $(tr '\n' ',' < "$out/fixture.pc"))"
check "vm80a_sim_fast has no FST: +fst= is an error" sh -c \
    "${fast[*]} +image=$out/icarus/mvi-sta-hlt.img +ram_start=0 +ram_size=4000 +fst=$out/x.fst +result=$out/fast-fst.result >/dev/null; grep -q '^error=no FST' $out/fast-fst.result"
check "vm80a_sim: +vcd= is an error (the build writes FST)" sh -c \
    "${verilator[*]} +image=$out/icarus/mvi-sta-hlt.img +ram_start=0 +ram_size=4000 +vcd=$out/x.vcd +result=$out/fst-vcd.result >/dev/null; grep -q '^error=this build writes FST' $out/fst-vcd.result"

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
