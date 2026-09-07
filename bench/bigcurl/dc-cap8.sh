#!/bin/bash
# Re-run only the connection-capped scenario (tuner change after the main DC run).
set -uo pipefail
H=http://100.82.150.18
SHA1G=d0a9a598d55beec9e464e96e125199ef392fe360eae01bd876e4ca4944b383cd
OUT=/root/dc-cap8.csv; rm -f "$OUT"
perl /root/bench.pl --base "$H:8084" --path big-1g.bin --label "do-sfo>hz-ore/rate4m+cap8" \
  --sha "$SHA1G" --reps 2 --warmup 1 --timeout 900 --bigcurl /root/bigcurl \
  --workdir /tmp/dcwork --tools curl,aria2-8,aria2-16,bigcurl-8,bigcurl-16,bigcurl-auto --out "$OUT"
echo "CAP8 COMPLETE"
