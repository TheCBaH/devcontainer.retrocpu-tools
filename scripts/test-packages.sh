#!/bin/bash
# Checks the packages in <dist>: static binaries, licence listing, and the
# diagnostics run as a non-root user on minimal Debian and Alpine images.
# usage: test-packages.sh <dist>
set -euo pipefail
dist=$(cd "$1" && pwd)
arch=$(uname -m | sed 's/arm64/aarch64/')
stage=$(mktemp -d)
tar -C "$stage" -xJf "$dist/retrocpu-tools-linux-$arch-musl.tar.xz"
tar -C "$stage" -xJf "$dist/retrocpu-diagnostics-$arch.tar.xz"


echo "== static check (no interpreter, no shared libraries)"
tar -C "$stage" -cf - . | docker run -i --rm alpine:3.22 sh -c '
    apk add --no-cache binutils file >/dev/null
    mkdir /t && tar -xf - -C /t
    for b in /t/retrocpu-tools-*/bin/*; do
        file "$b" | grep -q "statically linked" || { echo "not static: $b"; exit 1; }
        ! readelf -lW "$b" | grep -q INTERP || { echo "has interpreter: $b"; exit 1; }
        ! readelf -dW "$b" 2>/dev/null | grep -q NEEDED || { echo "needs libraries: $b"; exit 1; }
        echo "static: $(basename "$b")"
    done'

echo "== licence listing"
for p in retrocpu-tools-$arch retrocpu-diagnostics; do
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
: > "$dist/diagnostics-run.log"
run() { docker run --rm --user 1000:1000 --read-only --tmpfs /tmp:exec,mode=1777 -v "$vol:/p:ro" -v "$out:/o" "$@"; }
for image in debian:bookworm-slim alpine:3.22; do
    run "$image" /p/retrocpu-diagnostics/check-shim.sh /p "$arch" | tee -a "$dist/diagnostics-run.log"
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
        echo "$image: $name pass in ${secs}s (wall clock incl. container start, $arch)" | tee -a "$dist/diagnostics-run.log"
    done
done
