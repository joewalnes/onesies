#!/bin/bash
# grid.sh - sweep RTT x loss in the netem lab, measuring every downloader.
set -uo pipefail
OUT=/root/lab-v7.csv
# AIDEV-NOTE: the fixture digest is recomputed ON THIS HOST at run time, never
# hardcoded. The hosts have been re-provisioned mid-run more than once and a
# stale literal here silently fails every verification in the suite.
FIXTURE=/srv/bench/lab-32m.bin
SHA=$(sha256sum "$FIXTURE" | awk '{print $1}')
[ ${#SHA} -eq 64 ] || { echo "FATAL: cannot hash $FIXTURE" >&2; exit 1; }
echo "fixture $FIXTURE sha256=$SHA"
TOOLS=curl,aria2-8,axel-8,bigcurl-8,bigcurl-16,bigcurl-auto
rm -f "$OUT"
/root/lab.sh up
for RTT in 0 25 100 250; do
  for LOSS in 0 0.1 0.5; do
    /root/lab.sh set "$RTT" "$LOSS" 200mbit
    /root/lab.sh run perl /root/bench.pl \
      --base http://10.200.0.1:8080 --path lab-32m.bin \
      --label "rtt${RTT}ms/loss${LOSS}pct" --reps 3 --warmup 0 \
      --timeout 600 --sha "$SHA" --bigcurl /root/bigcurl \
      --workdir /tmp/labwork --tools "$TOOLS" --out "$OUT"
  done
done
/root/lab.sh down
echo "GRID COMPLETE"
