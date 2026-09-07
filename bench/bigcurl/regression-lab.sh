#!/bin/bash
# regression-lab.sh - one netem cell, one bigcurl build, appended to
# regression-lab.csv. Companion to grid.sh, not a replacement: grid.sh
# sweeps the full RTT x loss x tool grid for one build; this drives a
# hand-picked subset of cells against TWO builds (old vs new) so a
# regression sweep can compare them without re-running the whole grid
# twice. See REPRODUCE.md's "Regression sweep" section for which cells
# were chosen and why, and for the exact invocations used.
#
# Run ON the Hetzner lab host as root, with `lab.sh up` already done and
# `lab.sh down` left to the caller (so a caller looping over many cells
# doesn't pay setup/teardown per cell). Requires the bigcurl build under
# test already copied to the host (e.g. /root/bigcurl-old, /root/bigcurl-new)
# and /srv/bench/lab-32m.bin already present -- this script provisions
# nothing.
#
#   regression-lab.sh <rtt_ms> <loss_pct> <label_tag> <bigcurl_path> <reps> <timeout_s> [tools]
#
# Example:
#   regression-lab.sh 250 0.5 new /root/bigcurl-new 2 200 bigcurl-8,bigcurl-auto
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -uo pipefail
RTT=$1; LOSS=$2; TAG=$3; BC=$4; REPS=$5; TMO=$6; TOOLS=${7:-curl,bigcurl-8,bigcurl-auto}
OUT=/root/regression-lab.csv
FIXTURE=/srv/bench/lab-32m.bin
[ -f "$FIXTURE" ] || { echo "missing $FIXTURE -- lab fixture not provisioned" >&2; exit 1; }
[ -x "$BC" ] || { echo "missing or non-executable $BC" >&2; exit 1; }
# AIDEV-NOTE: sha256 recomputed fresh here every invocation, never cached or
# passed in -- fixture bytes are not assumed stable across provisions.
SHA=$(sha256sum "$FIXTURE" | awk '{print $1}')
/root/lab.sh set "$RTT" "$LOSS" 200mbit
/root/lab.sh run perl /root/bench.pl \
  --base http://10.200.0.1:8080 --path lab-32m.bin \
  --label "rtt${RTT}ms/loss${LOSS}pct/${TAG}" --reps "$REPS" --warmup 0 \
  --timeout "$TMO" --sha "$SHA" --bigcurl "$BC" \
  --workdir /tmp/regwork --tools "$TOOLS" --out "$OUT"
