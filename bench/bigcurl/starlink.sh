#!/bin/bash
# Starlink desktop -> DO SFO (24ms) and Hetzner Oregon (50ms), over the tailnet.
#
# Runs from the desktop, so the client here is a real machine on a real
# consumer link -- this is the one suite in the set that is not a model.
set -uo pipefail

# AIDEV-NOTE: paths default to this script's own checkout rather than a
# hardcoded personal path or a scratch directory from an earlier session.
# An earlier revision pointed at a stale scratchpad copy of bench.pl and at
# the shared checkout's bigcurl; both are wrong when the run is done from a
# worktree, and the stale bench.pl silently lacked --sha handling.
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BC=${BC:-$D/../../cli/bigcurl}
OUT=${OUT:-$D/starlink-new.csv}

# AIDEV-NOTE: fixture digests are NOT hardcoded. They must be recomputed on
# each ORIGIN immediately before this suite runs and passed in. The hosts
# have been re-provisioned mid-run and every literal that used to live here
# was stale, which would have failed verification on every single run.
: "${HZ96:?HZ96 must be a fresh sha256 of big-96m.bin computed ON THE HETZNER ORIGIN}"
: "${HZ48:?HZ48 must be a fresh sha256 of big-48m.bin computed ON THE HETZNER ORIGIN}"
: "${DO96:?DO96 must be a fresh sha256 of big-96m.bin computed ON THE DROPLET ORIGIN}"
for v in HZ96 HZ48 DO96; do
  eval "s=\$$v"
  [ ${#s} -eq 64 ] || { echo "FATAL: $v is not a sha256" >&2; exit 1; }
done
echo "hetzner big-96m.bin sha256=$HZ96"
echo "hetzner big-48m.bin sha256=$HZ48"
echo "droplet big-96m.bin sha256=$DO96"
echo "bigcurl build sha256=$(shasum -a 256 "$BC" | awk '{print $1}')"

TOOLS=curl,aria2-8,aria2-16,bigcurl-8,bigcurl-16,bigcurl-auto
SWEEP=curl,bigcurl-1,bigcurl-2,bigcurl-4,bigcurl-8,bigcurl-16,bigcurl-32
rm -f "$OUT"
run() { perl "$D/bench.pl" --base "$1" --path "$2" --label "$3" --sha "$4" \
        --reps 2 --warmup 1 --timeout 900 --bigcurl "$BC" \
        --workdir /tmp/slwork --tools "$5" --out "$OUT"; }
run http://100.82.150.18:8080 big-96m.bin  "starlink>hz-ore/plain"  "$HZ96" "$TOOLS"
run http://100.82.150.18:8081 big-96m.bin  "starlink>hz-ore/rate4m" "$HZ96" "$TOOLS"
run http://100.119.48.88:8080 big-96m.bin  "starlink>do-sfo/plain"  "$DO96" "$TOOLS"
run http://100.82.150.18:8080 big-48m.bin  "starlink>hz-ore/sweep"  "$HZ48" "$SWEEP"
echo "STARLINK COMPLETE"
