#!/bin/bash
# The clean-path cells of the grid use a 32MB file, which at 250ms RTT is
# mostly TCP slow start. Repeat them with 1GB to see steady-state behaviour.
set -uo pipefail
FIXTURE=/srv/bench/big-1g.bin
SHA=$(sha256sum "$FIXTURE" | awk '{print $1}')
[ ${#SHA} -eq 64 ] || { echo "FATAL: cannot hash $FIXTURE" >&2; exit 1; }
echo "fixture $FIXTURE sha256=$SHA"
OUT=/root/steady-results.csv
rm -f "$OUT"
/root/lab.sh up
for RTT in 100 250; do
  /root/lab.sh set "$RTT" 0 200mbit
  /root/lab.sh run perl /root/bench.pl \
    --base http://10.200.0.1:8080 --path big-1g.bin \
    --label "steady/rtt${RTT}ms/loss0pct" --reps 2 --warmup 0 --timeout 900 \
    --sha "$SHA" --bigcurl /root/bigcurl --workdir /tmp/steadywork \
    --tools curl,aria2-8,bigcurl-8,bigcurl-auto --out "$OUT"
done
/root/lab.sh down
echo "STEADY COMPLETE"
