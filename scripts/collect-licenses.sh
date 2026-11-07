#!/bin/sh
# Collects the licence files that apply to a binary package.
# usage: collect-licenses.sh <repo-root> <meta-dir> <outdir> tools|diagnostics
# <meta-dir>/pins.txt has lines "<sha> <path> <subject>" (from the host).
set -eu
root=$1 meta=$2 out=$3 kind=$4
rm -rf "$out"; mkdir -p "$out"
src=$root/sources third=$root/licenses/third-party
: > "$out/.entries"

pin() { grep " sources/$1 " "$meta/pins.txt" | cut -d' ' -f1,4-; }
# add <component> <version/pin> <SPDX> <why> <file>...  (file = src[:dest-name])
add() {
    comp=$1 ver=$2 spdx=$3 why=$4; shift 4
    mkdir -p "$out/$comp"
    files=
    for f in "$@"; do
        s=${f%%:*}; d=${f#*:}; [ "$d" = "$f" ] && d=$(basename "$s")
        [ -f "$s" ] || { echo "missing licence file: $s" >&2; exit 1; }
        cp "$s" "$out/$comp/$d"
        files="$files $comp/$d"
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$comp" "$ver" "$spdx" "$why" "${files# }" >> "$out/.entries"
}

# Copyright lines of the SIMH core and AltairZ80 sources linked into altairz80.
simh_notices() {
    {
        echo "Copyright lines found in the SIMH core (sim_*.c, scp.c) and AltairZ80/*.c"
        echo "sources, a superset of what altairz80 links. The licence text is LICENSE.txt."
        echo
        for f in "$src"/simh/scp.c "$src"/simh/sim_*.c "$src"/simh/AltairZ80/*.c "$src"/simh/AltairZ80/*.h; do
            grep -h -i -E '^[[:space:]/*#]*copyright' "$f" || true
        done | sed -E 's/^[[:space:]/*#]+//; s/[[:space:]]+/ /g; s/[[:space:]*\/]+$//' | sort -u
    } > "$out/.simh-copyrights"
}

add retrocpu-tools "$(cat "$meta/commit" 2>/dev/null || echo unknown)" MIT \
    "build scripts, patches, shim" "$root/LICENSE"

case $kind in
tools)
    simh_notices
    add simh "$(pin simh)" "X11-style (MIT without advertising)" \
        "altairz80 (statically linked)" "$src/simh/LICENSE.txt" "$out/.simh-copyrights:COPYRIGHTS.txt"
    add asl "$(pin asl-releases)" "GPL-2.0-only OR GPL-3.0-only" \
        "asl, p2bin, p2hex (statically linked)" \
        "$src/asl-releases/COPYING:COPYING-GPL-2.0" "$third/gcc-runtime/COPYING3:COPYING-GPL-3.0"
    add musl "v$(grep MUSL_VERSION "$root/versions.env" | cut -d= -f2) (Alpine package)" MIT \
        "C library, statically linked into every binary" "$third/musl/COPYRIGHT"
    add gcc-runtime "$(grep GCC_RUNTIME_VERSION "$root/versions.env" | cut -d= -f2) (Alpine package)" \
        "GPL-3.0-or-later WITH GCC-exception-3.1" \
        "libgcc/libstdc++ runtime pieces, statically linked" \
        "$third/gcc-runtime/COPYING3" "$third/gcc-runtime/COPYING.RUNTIME"
    ;;
diagnostics)
    add i8080-core "$(pin i8080-core)" "GPL-2.0-or-later" \
        "source of 8080PRE.MAC and 8080EX1.MAC (Cringle, Bartholomew, Demin)" \
        "$src/i8080-core/LICENSE" "$src/asl-releases/COPYING:COPYING-GPL-2.0"
    ;;
*) echo "unknown kind $kind" >&2; exit 2 ;;
esac

{
    echo "# Licences ($kind package)"
    echo
    echo "Every component below is included in, or was used to produce, this"
    echo "package. Files are relative to this directory; checksums are in SHA256SUMS."
    echo
    echo "| Component | Version / pin | Licence (SPDX) | Role | Files |"
    echo "| --- | --- | --- | --- | --- |"
    while IFS="$(printf '\t')" read -r c v l w f; do
        echo "| $c | $v | $l | $w | $(echo "$f" | sed 's/ /, /g') |"
    done < "$out/.entries"
} > "$out/LICENSES.md"
{
    echo "# Corresponding sources"
    echo
    echo "Upstream revisions used for this package (the submodule pins of the"
    echo "retrocpu-tools commit listed in LICENSES.md). Local patches to the"
    echo "exercisers are in the diagnostics package under source/patches."
    echo
    echo "| Path | Upstream | Revision |"
    echo "| --- | --- | --- |"
    while read -r sha path url subject; do
        echo "| $path | $url | $sha |"
    done < "$meta/pins.txt"
    echo
    echo "Alpine build image: $(grep ALPINE_IMAGE "$root/versions.env" | cut -d= -f2-)"
} > "$out/SOURCES.md"
rm -f "$out/.entries" "$out/.simh-copyrights"
( cd "$out" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum > SHA256SUMS )
