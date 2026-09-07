#!/bin/bash
# Pure orchestration cost: loopback, no network limit, 1GB file.
set -uo pipefail
FIXTURE=/srv/bench/big-1g.bin
SHA=$(sha256sum "$FIXTURE" | awk '{print $1}')
[ ${#SHA} -eq 64 ] || { echo "FATAL: cannot hash $FIXTURE" >&2; exit 1; }
echo "fixture $FIXTURE sha256=$SHA"
OUT=/root/overhead-results.csv
rm -f "$OUT"
perl /root/bench.pl --base http://127.0.0.1:8080 --path big-1g.bin \
  --label "localhost/1GB" --reps 3 --warmup 1 --sha "$SHA" \
  --bigcurl /root/bigcurl --workdir /tmp/ohwork \
  --tools curl,aria2-8,axel-8,bigcurl-8,bigcurl-auto --out "$OUT"
echo "OVERHEAD COMPLETE"
