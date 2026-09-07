#!/bin/bash
# probe-size-lab.sh - the cells that decide the probe-size change.
# old=da87807 (pre-probe-free) tip=ae9f6f3 (regressed) new=probe-size HEAD.
# Cell A 32MB: where the regression was measured.
# Cell B 512KB: the counter-case, bigger than the new 8KB solo probe but
#               smaller than the old 1MB one, so it is where the change
#               should LOSE a round trip. Measured, not argued.
# Own CSV, own build names (ps-*), so the concurrent sweep is untouched:
# /root/bigcurl-old and /root/bigcurl-new are ANOTHER worker's staging, and
# in its vocabulary "new" means the current tip, not a fix. Never write there.
# Verify each arm by sha256 against git, not by filename.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -uo pipefail
REPS=${1:-3}
OUT=/root/probe-size-lab.csv
BIG=/srv/bench/lab-32m.bin
SMALL=/srv/bench/lab-512k.bin
[ -f "$BIG" ] || { echo "missing $BIG" >&2; exit 1; }
[ -f "$SMALL" ] || dd if="$BIG" of="$SMALL" bs=1024 count=512 status=none
for b in old tip new; do [ -x "/root/ps-$b" ] || { echo "missing /root/ps-$b" >&2; exit 1; }; done

# AIDEV-NOTE: the lab is NOT assumed clean. A previous worker left netem at
# 125ms delay + 0.5% loss; running this cell on that would have silently
# measured a lossy path and reported it as the clean one. Set explicitly,
# then READ BACK both veth ends and fail loudly on any mismatch.
assert_lab() {
  local when=$1 q bad=0
  for side in host ns; do
    if [ "$side" = host ]; then q=$(tc qdisc show dev vbench0 | head -1)
    else q=$(ip netns exec bcli tc qdisc show dev vbench1 | head -1); fi
    echo "  [$when/$side] $q"
    case "$q" in *"delay 125ms"*) ;; *) echo "ASSERT FAIL: delay not 125ms/dir (=250ms rtt)" >&2; bad=1;; esac
    case "$q" in *"rate 200Mbit"*) ;; *) echo "ASSERT FAIL: rate not 200Mbit" >&2; bad=1;; esac
    case "$q" in *loss*) echo "ASSERT FAIL: loss present, this cell must be 0%" >&2; bad=1;; esac
  done
  [ "$bad" = 0 ] || { echo "LAB STATE WRONG ($when) - refusing to report these numbers" >&2; exit 3; }
}

/root/lab.sh set 250 0 200mbit
echo "== netem readback =="
assert_lab before
echo "== independent rtt check =="
/root/lab.sh ping

SHA_BIG=$(sha256sum "$BIG" | awk '{print $1}')
SHA_SMALL=$(sha256sum "$SMALL" | awk '{print $1}')
echo "lab-32m.bin  sha256 (recomputed on host): $SHA_BIG"
echo "lab-512k.bin sha256 (recomputed on host): $SHA_SMALL"

cell() {
  local P=$1 S=$2 SUF=$3 TOOLS=$4 TMO=$5 r b
  /root/lab.sh run perl /root/bench.pl --base http://10.200.0.1:8080 --path "$P" \
    --label "rtt250ms/loss0pct/curlref$SUF" --reps "$REPS" --warmup 0 \
    --timeout "$TMO" --sha "$S" --bigcurl /root/ps-new \
    --workdir /tmp/pswork --tools curl --out "$OUT"
  for r in $(seq 1 "$REPS"); do
    for b in old tip new; do
      /root/lab.sh run perl /root/bench.pl --base http://10.200.0.1:8080 --path "$P" \
        --label "rtt250ms/loss0pct/$b$SUF" --reps 1 --warmup 0 \
        --timeout "$TMO" --sha "$S" --bigcurl "/root/ps-$b" \
        --workdir /tmp/pswork --tools "$TOOLS" --out "$OUT"
    done
  done
}

cell lab-32m.bin  "$SHA_BIG"   ""     bigcurl-8,bigcurl-auto 300
cell lab-512k.bin "$SHA_SMALL" /512k  bigcurl-auto           120

echo "== netem readback after =="
assert_lab after
echo "== rows =="
wc -l "$OUT"
awk -F, 'NR>1 && $8!=1 {n++} END{printf "rows with ok!=1 (sha mismatch/timeout): %d\n", n+0}' "$OUT"
