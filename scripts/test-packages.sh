#!/bin/bash
# Checks the packages in <dist>: static binaries, licence listing, and the
# diagnostics and vm80a_sim run as a non-root user on minimal Debian and Alpine images.
# usage: test-packages.sh <dist>
set -euo pipefail
dist=$(cd "$1" && pwd)
arch=$(uname -m | sed 's/arm64/aarch64/')
stage=$(mktemp -d)
tar -C "$stage" -xJf "$dist/retrocpu-tools-linux-$arch-musl.tar.xz"
tar -C "$stage" -xJf "$dist/retrocpu-diagnostics-$arch.tar.xz"
tar -C "$stage" -xJf "$dist/retrocpu-vm80a-sim-linux-$arch-musl.tar.xz"


# argument files for 8080PRE under the K5 shim (the packaged runner reads them in the containers)
mkdir -p "$stage/exe"
python3 -I scripts/vm80a.py com-manifest "$stage/retrocpu-diagnostics/8080PRE.COM" "$stage/exe/8080PRE.json"
python3 -I scripts/vm80a.py args "$stage/exe/8080PRE.json" "$stage/exe" @A@ @O@

echo "== static check (no interpreter, no shared libraries)"
tar -C "$stage" -cf - . | docker run -i --rm alpine:3.22 sh -c '
    apk add --no-cache binutils file >/dev/null
    mkdir /t && tar -xf - -C /t
    for b in /t/retrocpu-tools-*/bin/* /t/retrocpu-vm80a-sim-*/bin/*; do
        file "$b" | grep -q "statically linked" || { echo "not static: $b"; exit 1; }
        ! readelf -lW "$b" | grep -q INTERP || { echo "has interpreter: $b"; exit 1; }
        ! readelf -dW "$b" 2>/dev/null | grep -q NEEDED || { echo "needs libraries: $b"; exit 1; }
        echo "static: $(basename "$b")"
    done'

echo "== licence listing"
for p in retrocpu-tools-$arch retrocpu-diagnostics retrocpu-vm80a-sim-$arch; do
    (cd "$stage/$p/licenses" && sha256sum -c --quiet SHA256SUMS)
    # every file named in LICENSES.md exists, every file is named
    awk -F'|' '/^\| / && !/Component|---/ {print $6}' "$stage/$p/licenses/LICENSES.md" | tr ',' '\n' | tr -d ' ' | sort -u | while read -r f; do
        [ -f "$stage/$p/licenses/$f" ] || { echo "$p: listed but missing: $f"; exit 1; }
    done
    echo "$p: LICENSES.md, SOURCES.md and checksums consistent ($(wc -l < "$stage/$p/licenses/SHA256SUMS") files)"
done
for need in simh/LICENSE.txt asl/COPYING-GPL-2.0 musl/COPYRIGHT gcc-runtime/COPYING.RUNTIME; do
    [ -s "$stage/retrocpu-tools-$arch/licenses/$need" ] || { echo "missing licence $need" >&2; exit 1; }
done

for need in vm80a/CC-BY-3.0.md vm80a/NOTICE.txt verilator/COPYING-LGPL-3.0 verilator/Artistic-2.0 libfst/LICENSE-fstapi.txt lz4/LICENSE-lz4.txt fastlz/LICENSE-fastlz.txt zlib/LICENSE.txt musl/COPYRIGHT gcc-runtime/COPYING.RUNTIME; do
    [ -s "$stage/retrocpu-vm80a-sim-$arch/licenses/$need" ] || { echo "missing licence $need" >&2; exit 1; }
done
cmp "$stage/retrocpu-vm80a-sim-$arch/source/vm80a.v" sources/vm80a/org/rtl/vm80a.v \
    || { echo "packaged vm80a.v differs from the pinned submodule file" >&2; exit 1; }

echo "== diagnostics as non-root, read-only root fs"
# Packages go through a volume. altairz80 output goes to a file in a scratch
# volume (exec, no shell step after it): on some Docker hosts a container's
# stdout/stderr is lost once altairz80 has run, so results are judged here.
vol=retrocpu-test-$$ out=retrocpu-out-$$
docker volume create "$vol" >/dev/null
docker volume create "$out" >/dev/null
trap 'docker volume rm -f "$vol" "$out" >/dev/null' EXIT
tar -C "$stage" -cf - . | docker run -i --rm -v "$vol:/p" alpine:3.22 sh -c 'tar -xf - -C /p && chmod -R a+rX /p'
docker run --rm -v "$out:/o" alpine:3.22 chmod 777 /o
: > "$dist/diagnostics-run-$arch.log"
run() { docker run --rm --user 1000:1000 --read-only --tmpfs /tmp:exec,mode=1777 -v "$vol:/p:ro" -v "$out:/o" "$@"; }
for image in debian:bookworm-slim alpine:3.22; do
    run "$image" /p/retrocpu-diagnostics/check-shim.sh /p "$arch" | tee -a "$dist/diagnostics-run-$arch.log"
    for name in 8080PRE 8080EX1; do
        start=$(date +%s)
        run -w /p/retrocpu-diagnostics "$image" sh -c \
            'exec "$0" "$1" < /dev/null > "/o/$2.out" 2>&1' "/p/retrocpu-tools-$arch/bin/altairz80" "$name.ini" "$name" || true
        secs=$(( $(date +%s) - start ))
        docker run --rm -v "$out:/o" alpine:3.22 cat "/o/$name.out" > "$stage/$name.out"
        case $name in
        8080PRE) grep -q '8080 Preliminary tests complete' "$stage/$name.out" ;;
        8080EX1) [ "$(grep -c '  OK' "$stage/$name.out")" = 25 ] \
                 && grep -q 'Tests complete' "$stage/$name.out" && ! grep -q ERROR "$stage/$name.out" ;;
        esac || { cat "$stage/$name.out"; echo "FAIL: $name on $image" >&2; exit 1; }
        echo "$image: $name pass in ${secs}s (wall clock incl. container start, $arch)" | tee -a "$dist/diagnostics-run-$arch.log"
    done
done

echo "== vm80a_sim and vm80a_sim_fast as non-root, read-only root fs"
sim=/p/retrocpu-vm80a-sim-$arch
regs="acc:8 r16_bc:16 r16_de:16 r16_hl:16 r16_sp:16 r16_pc:16 r16_wz:16 psw_z:1 psw_s:1 psw_p:1 psw_c:1 psw_ac:1"
for image in debian:bookworm-slim alpine:3.22; do
    tag=${image%%:*}
    run "$image" $sim/run-vm80a-fixtures.sh $sim /o/vm80a-$tag
    run "$image" $sim/run-vm80a-fixtures.sh $sim /o/exe-$tag /p/exe "none 1"
    run "$image" sh -c "for v in vm80a_sim; do $sim/bin/fstdump /o/vm80a-$tag/\$v/seed-none/mvi-sta-hlt.fst vars > /o/vm80a-$tag/fst.vars; $sim/bin/fstdump /o/vm80a-$tag/\$v/seed-none/mvi-sta-hlt.fst final i8080_tb.dut.acc > /o/vm80a-$tag/fst.acc; done"
    docker run --rm -v "$out:/o" alpine:3.22 tar -C /o -cf - vm80a-$tag exe-$tag | tar -C "$stage" -xf -
    d=$stage/vm80a-$tag
    for f in mvi-sta-hlt mvi-sta-hlt-wait2 io-console inta-rst inta-call; do
        m=fixtures/*/$f.json
        for variant in vm80a_sim vm80a_sim_fast; do
            for seed in none 1 2 3 4 5; do
                r=$d/$variant/seed-$seed
                [ -e "$r/$f.result" ] || continue
                python3 -I scripts/vm80a.py check $m "$r" > /dev/null \
                    || { python3 -I scripts/vm80a.py check $m "$r"; echo "FAIL: $variant $f seed $seed on $image" >&2; exit 1; }
                case $f in mvi-*)
                    python3 -I scripts/vm80a.py compare "fixtures/mvi-sta-hlt/$f.trace" "$r/$f.trace" >/dev/null \
                        || { echo "FAIL: $variant $f seed $seed trace on $image" >&2; exit 1; } ;;
                esac
                for ext in trace mem ioout result; do
                    cmp "$r/$f.$ext" "$d/vm80a_sim/seed-none/$f.$ext" \
                        || { echo "FAIL: $variant $f seed $seed $ext differs from vm80a_sim unseeded on $image" >&2; exit 1; }
                done
            done
        done
    done
    sha=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(bytes.fromhex("".join(open(sys.argv[1]).read().split()))).hexdigest())' "$d/vm80a_sim/seed-none/mvi-sta-hlt.mem")
    [ "$sha" = 7e60a9484efefb5eebc82a12439ebbbebba80048faf9f9cd7ba196e9a11de430 ] \
        || { echo "FAIL: vm80a_sim memory digest $sha on $image" >&2; exit 1; }
    for rw in $regs; do
        grep -qx "i8080_tb.dut.${rw%%:*} ${rw##*:}" "$d/fst.vars" \
            || { echo "FAIL: FST on $image lacks i8080_tb.dut.${rw%%:*}" >&2; exit 1; }
    done
    grep -qx 'i8080_tb.dut.acc 2a' "$d/fst.acc" || { cat "$d/fst.acc"; echo "FAIL: FST acc on $image" >&2; exit 1; }
    e=$stage/exe-$tag
    for variant in vm80a_sim vm80a_sim_fast; do
        for seed in none 1; do
            python3 -I scripts/vm80a.py check "$stage/exe/8080PRE.json" "$e/$variant/seed-$seed" > /dev/null \
                && python3 -I -c 'import sys; sys.path.insert(0, "scripts"); import vm80a; t = vm80a.console(sys.argv[1]); print(t.decode("latin-1").strip()); sys.exit(0 if b"8080 Preliminary tests complete" in t else 1)' \
                    "$e/$variant/seed-$seed/8080PRE.ioout" > "$e/$variant-$seed.txt" \
                || { cat "$e/$variant-$seed.txt" 2>/dev/null; echo "FAIL: 8080PRE under $variant seed $seed on $image" >&2; exit 1; }
        done
    done
    echo "$image: vm80a_sim and vm80a_sim_fast pass (5 fixtures x seeds; traces equal the hand traces under masks, variants equal; FST holds the register set; 8080PRE: $(cat "$e/vm80a_sim-none.txt"), $arch)" | tee -a "$dist/diagnostics-run-$arch.log"
done
