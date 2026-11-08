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

for need in vm80a/CC-BY-3.0.md vm80a/NOTICE.txt verilator/COPYING-LGPL-3.0 verilator/Artistic-2.0 musl/COPYRIGHT gcc-runtime/COPYING.RUNTIME; do
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

echo "== vm80a_sim as non-root, read-only root fs"
sim=/p/retrocpu-vm80a-sim-$arch
for image in debian:bookworm-slim alpine:3.22; do
    tag=${image%%:*}
    run "$image" $sim/run-vm80a-fixtures.sh $sim /o/vm80a-$tag
    docker run --rm -v "$out:/o" alpine:3.22 tar -C /o -cf - vm80a-$tag | tar -C "$stage" -xf -
    d=$stage/vm80a-$tag
    for f in mvi-sta-hlt mvi-sta-hlt-wait2; do
        case $f in mvi-sta-hlt) ts=27 ;; *) ts=29 ;; esac
        for seed in none 1 2 3 4 5; do
            r=$d/seed-$seed/$f
            grep -qx 'stop_reason=hlt' "$r.result" && grep -qx "tstates=$ts" "$r.result" \
                && grep -qx 'instructions=3' "$r.result" && grep -qx 'x_samples=0' "$r.result" \
                && grep -qx 'writes=1' "$r.result" && grep -qx 'write=2000 2a' "$r.result" \
                || { cat "$r.result"; echo "FAIL: vm80a_sim $f seed $seed on $image" >&2; exit 1; }
            python3 -I scripts/vm80a.py compare "fixtures/mvi-sta-hlt/$f.trace" "$r.trace" \
                || { echo "FAIL: vm80a_sim $f seed $seed trace on $image" >&2; exit 1; }
            cmp "$r.trace" "$d/seed-none/$f.trace" && cmp "$r.mem" "$d/seed-none/$f.mem" \
                || { echo "FAIL: vm80a_sim $f seed $seed differs from the unseeded run on $image" >&2; exit 1; }
        done
        sha=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(bytes.fromhex("".join(open(sys.argv[1]).read().split()))).hexdigest())' "$d/seed-none/$f.mem")
        [ "$sha" = 7e60a9484efefb5eebc82a12439ebbbebba80048faf9f9cd7ba196e9a11de430 ] \
            || { echo "FAIL: vm80a_sim $f memory digest $sha on $image" >&2; exit 1; }
    done
    echo "$image: vm80a_sim pass (2 fixtures x 6 seeds, traces equal the hand traces under masks, $arch)" | tee -a "$dist/diagnostics-run-$arch.log"
done
