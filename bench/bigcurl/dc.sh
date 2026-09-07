#!/bin/bash
# DO Santa Clara -> Hetzner Oregon, 16ms, over the tailnet (direct path).
set -uo pipefail
H=http://100.82.150.18
# AIDEV-NOTE: this suite runs on the droplet but pulls from the Hetzner origin,
# so it cannot hash the fixture locally. SHA1G must be recomputed on the ORIGIN
# immediately before launching and passed in; there is deliberately no default.
: "${SHA1G:?SHA1G must be set to a fresh sha256 of big-1g.bin computed ON THE ORIGIN}"
[ ${#SHA1G} -eq 64 ] || { echo "FATAL: SHA1G is not a sha256" >&2; exit 1; }
echo "origin fixture big-1g.bin sha256=$SHA1G"
OUT=/root/dc-results.csv
TOOLS=curl,aria2-8,aria2-16,bigcurl-8,bigcurl-16,bigcurl-auto
rm -f "$OUT"
run() { perl /root/bench.pl --base "$1" --path big-1g.bin --label "$2" \
        --sha "$SHA1G" --reps 2 --warmup 1 --timeout 900 --bigcurl /root/bigcurl \
        --workdir /tmp/dcwork --tools "$TOOLS" --out "$OUT"; }
run "$H:8080" "do-sfo>hz-ore/plain"
run "$H:8081" "do-sfo>hz-ore/rate4m"
run "$H:8084" "do-sfo>hz-ore/rate4m+cap8"
echo "DC COMPLETE"
