#!/bin/sh
# Packs vm80a_sim with its sources, fixtures, manifest and licences.
# usage: package-vm80a-sim.sh <repo-root> <meta-dir> <dist> <arch> <vm80a-sim-prefix> <stage>
set -eu
root=$1 meta=$2 dist=$3 arch=$4 sim=$5 stage=$6
v=$stage/retrocpu-vm80a-sim-$arch
mkdir -p "$v/bin" "$v/source" "$v/fixtures"
cp "$sim/bin/vm80a_sim" "$v/bin/"
cp "$root/hdl/vm80a/harness.v" "$root/sources/vm80a/org/rtl/vm80a.v" "$v/source/"
cp "$root/hdl/vm80a/README.md" "$root/scripts/run-vm80a-fixtures.sh" "$root/scripts/vm80a.py" "$v/"
cp "$root/fixtures/mvi-sta-hlt/"* "$v/fixtures/"
vpin=$(grep " sources/vm80a " "$meta/pins.txt" | cut -d' ' -f1)
epin=$(grep " sources/verilator " "$meta/pins.txt" | cut -d' ' -f1)
cat > "$v/manifest.json" <<EOF2
{
  "format": "retrocpu-vm80a-sim/1",
  "arch": "$arch",
  "retrocpu_tools_commit": "$(cat "$meta/commit")",
  "vm80a": {"revision": "$vpin", "file": "source/vm80a.v", "modified": false,
            "licence": "CC-BY-3.0", "author": "1801BM1", "url": "https://github.com/1801BM1/vm80a"},
  "harness": {"file": "source/harness.v", "sha256": "$(sha256sum "$root/hdl/vm80a/harness.v" | cut -d' ' -f1)"},
  "verilator": {"revision": "$epin", "version": "$(cat "$sim/verilator-version")"},
  "build": "verilator --binary --timing --trace --top-module i8080_tb --x-initial unique -LDFLAGS -static (Alpine, musl)",
  "binary_sha256": "$(sha256sum "$v/bin/vm80a_sim" | cut -d' ' -f1)"
}
EOF2
"$root/scripts/collect-licenses.sh" "$root" "$meta" "$v/licenses" vm80a-sim
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner -cf - "retrocpu-vm80a-sim-$arch" \
    | xz -9e > "$dist/retrocpu-vm80a-sim-linux-$arch-musl.tar.xz"
