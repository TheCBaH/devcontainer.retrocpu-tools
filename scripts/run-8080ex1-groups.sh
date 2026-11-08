#!/bin/sh
# Runs the 25 groups of 8080EX1 as separate programs (one process each, in
# parallel) under a vm80a_sim binary and the K5 shim, then prints the verdict.
# A group passes when its console shows "OK" and no "ERROR".
# usage: run-8080ex1-groups.sh <vm80a_sim> <8080EX1.COM> <outdir> [jobs]
set -eu
sim=$1 com=$2 out=$3 jobs=${4:-4}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
python3 -I "$here/exerciser-group.py" list "$com" > "$out/groups.txt"
n=$(wc -l < "$out/groups.txt")
start=$(date +%s)
i=0
while [ "$i" -lt "$n" ]; do
    g=$(printf 'g%02d' "$i")
    python3 -I "$here/exerciser-group.py" cut "$com" "$i" "$out/$g.COM"
    i=$((i + 1))
done
seq 0 $((n - 1)) | xargs -P "$jobs" -I{} sh -c '
    g=$(printf "g%02d" {})
    s=$(date +%s)
    python3 -I "$1/vm80a.py" com "$2/$g.COM" "$2/$g" --max-tstates 400000000000 -- "$3" > "$2/$g.console" 2>&1 || true
    echo "$g $(( $(date +%s) - s )) s: $(tail -c 120 "$2/$g.console" | tr "\r\n" "  ")"
' _ "$here" "$out" "$sim"
ok=0
for f in "$out"/g*.console; do
    if grep -q '  OK' "$f" && ! grep -q ERROR "$f" && grep -q 'Tests complete' "$f"; then ok=$((ok + 1)); fi
done
echo "8080EX1 under $(basename "$sim"): $ok of $n groups OK in $(( $(date +%s) - start )) s"
[ "$ok" = "$n" ]
