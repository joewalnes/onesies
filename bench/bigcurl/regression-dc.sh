#!/bin/bash
# regression-dc.sh - the droplet's plain (uncapped) origin, one bigcurl
# build, appended to regression-dc.csv. Companion to dc.sh, not a
# replacement: dc.sh measures one build across three origin behaviours;
# this drives just the "plain" scenario -- the one-core, CPU-bound case --
# against TWO builds (old vs new) for a regression sweep. See
# REPRODUCE.md's "Regression sweep" section.
#
# Run ON the droplet as root. Requires the bigcurl build under test already
# copied to the host (e.g. /root/bigcurl-old, /root/bigcurl-new) and takes
# the fixture's sha256 as an argument rather than computing it locally --
# the fixture lives on the Hetzner origin, not the droplet, so the caller
# recomputes it there fresh (ssh root@hetzner sha256sum ...) and passes it
# in. Never reuse a hash from a script, a CSV, or a note.
#
#   regression-dc.sh <label_tag> <bigcurl_path> <sha256> <reps> <warmup> [tools]
#
# Example:
#   regression-dc.sh new /root/bigcurl-new cb87776a...483cd 2 1 bigcurl-8,bigcurl-auto
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -uo pipefail
TAG=$1; BC=$2; SHA=$3; REPS=${4:-2}; WARMUP=${5:-1}; TOOLS=${6:-curl,bigcurl-8,bigcurl-auto}
H=http://100.82.150.18
OUT=/root/regression-dc.csv
[ -x "$BC" ] || { echo "missing or non-executable $BC" >&2; exit 1; }
[ -n "$SHA" ] || { echo "need a sha256 (recomputed on the Hetzner host, not reused)" >&2; exit 1; }
perl /root/bench.pl --base "$H:8080" --path big-1g.bin \
  --label "do-sfo>hz-ore/plain/${TAG}" --sha "$SHA" --reps "$REPS" --warmup "$WARMUP" \
  --timeout 300 --bigcurl "$BC" --workdir /tmp/dcregwork --tools "$TOOLS" --out "$OUT"
