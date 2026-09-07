#!/bin/bash
# regime-client.sh - run the regime-signal measurement from a real client over
# a real network (the 1-core droplet, or this desktop on Starlink) against a
# remote origin. Same two instruments as regime-lab.sh, no netem involved.
#
#   regime-client.sh --label NAME --base URL --path FILE --sha SHA256 \
#                    --span BYTES --reps N --bigcurl PATH --workdir DIR \
#                    --probe-csv F --trace-csv F
#
# --sha must be recomputed on the ORIGIN host, from the file the origin will
# actually serve, immediately before the run. Fixture bytes have changed across
# provisions before.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -euo pipefail

LABEL= ; BASE= ; FPATH= ; SHA= ; SPAN=$((16*1024*1024)) ; REPS=5
BIGCURL= ; WORKDIR=/tmp/rswork ; PCSV= ; TCSV= ; CONNS=8
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL=$2; shift 2;;
    --base) BASE=$2; shift 2;;
    --path) FPATH=$2; shift 2;;
    --sha) SHA=$2; shift 2;;
    --span) SPAN=$2; shift 2;;
    --conns) CONNS=$2; shift 2;;
    --reps) REPS=$2; shift 2;;
    --bigcurl) BIGCURL=$2; shift 2;;
    --workdir) WORKDIR=$2; shift 2;;
    --probe-csv) PCSV=$2; shift 2;;
    --trace-csv) TCSV=$2; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
# Not ${v,,}: this also runs on macOS, whose /bin/bash is 3.2 and has no
# lowercase expansion.
for v in LABEL BASE FPATH SHA BIGCURL; do
  eval "[ -n \"\$$v\" ]" || { echo "FATAL: --$(echo "$v" | tr 'A-Z' 'a-z') required" >&2; exit 2; }
done
[ -x "$BIGCURL" ] || { echo "FATAL: $BIGCURL not executable" >&2; exit 1; }

DIR=$(dirname "$0")
URL="$BASE/$FPATH"
mkdir -p "$WORKDIR"
PCSV=${PCSV:-$WORKDIR/regime-probe.csv}
TCSV=${TCSV:-$WORKDIR/regime-trace.csv}

echo "=============== $LABEL ==============="
echo "url      $URL"
echo "sha      $SHA   (computed on the origin host by the caller)"
echo "bigcurl  $BIGCURL"
if command -v sha256sum >/dev/null 2>&1; then echo "         $(sha256sum "$BIGCURL" | awk '{print $1}')"
else echo "         $(shasum -a 256 "$BIGCURL" | awk '{print $1}')"; fi

# Confirm the origin is reachable AND serves ranges before measuring anything:
# a client that silently gets 200s would have every probe rep discarded and the
# reason would look like a network problem.
PRE=$(curl -sS -o /dev/null -w '%{http_code} %{size_download}' --range 0-1023 "$URL" || true)
case "$PRE" in
  "206 1024") echo "range check OK ($PRE)";;
  *) echo "FATAL: origin did not serve a range request: got '$PRE'" >&2; exit 1;;
esac

echo "--- probe (plain curl, $CONNS conns, span $SPAN) ---"
perl "$DIR/regime-probe.pl" --url "$URL" --span "$SPAN" --conns "$CONNS" \
    --reps "$REPS" --label "$LABEL" --csv "$PCSV"

echo "--- bigcurl -l trace ---"
rm -f "$WORKDIR/rs.bin" "$WORKDIR/rs.bin.part" "$WORKDIR/rs.bin.part.state"
perl "$DIR/trace-signal.pl" --bigcurl "$BIGCURL" --url "$URL" --sha "$SHA" \
    --out "$WORKDIR/rs.bin" --reps "$REPS" --label "$LABEL" --csv "$TCSV"
rm -f "$WORKDIR/rs.bin" "$WORKDIR/rs.bin.part" "$WORKDIR/rs.bin.part.state"

echo
echo "=== probe csv ==="; cat "$PCSV"
echo "=== trace csv ==="; cat "$TCSV"
echo "REGIME CLIENT COMPLETE: $LABEL"
