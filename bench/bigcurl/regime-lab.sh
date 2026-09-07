#!/bin/bash
# regime-lab.sh - run the regime-signal measurement across the netem cells on
# the Hetzner box. For each cell it sets netem EXPLICITLY, reads tc back on
# BOTH veth ends and refuses to report if the readback disagrees, then runs
# regime-probe.pl (per-connection impairment, plain curl) and trace-signal.pl
# (what bigcurl's own -l trace can see) as the client inside the namespace.
#
# The lab is never assumed clean: a previous worker has left netem configured
# before, and inheriting it would silently measure the wrong link.
#
#   regime-lab.sh <reps>          default 5
#
# Expects on this host: /root/lab.sh /root/regime-probe.pl /root/trace-signal.pl
# /root/bigcurl (sha256 checked by the caller against git), /srv/bench/shard-1.bin
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -euo pipefail

REPS=${1:-5}
FIX=/srv/bench/shard-1.bin
URL=http://10.200.0.1:8080/shard-1.bin
LABRUN="/root/lab.sh run"
PCSV=/root/regime-probe.csv
TCSV=/root/regime-trace.csv

[ -f "$FIX" ] || { echo "FATAL: fixture $FIX missing" >&2; exit 1; }
[ -x /root/bigcurl ] || { echo "FATAL: /root/bigcurl missing" >&2; exit 1; }

# sha256 recomputed on THIS host from the file the origin will serve, every
# run. Never carried in from a script, a CSV or a note.
SHA=$(sha256sum "$FIX" | awk '{print $1}')
echo "fixture $FIX  $(stat -c %s "$FIX") bytes  sha256=$SHA"
echo "bigcurl under test: $(sha256sum /root/bigcurl | awk '{print $1}')"

assert_cell() {   # assert_cell <rtt_ms> <loss_pct> <when>
  local rtt=$1 loss=$2 when=$3 bad=0 half q
  half=$(python3 -c "print(f'{${rtt}/2:g}')")
  for side in host ns; do
    if [ "$side" = host ]; then q=$(tc qdisc show dev vbench0 | head -1)
    else q=$(ip netns exec bcli tc qdisc show dev vbench1 | head -1); fi
    echo "  tc[$side/$when]: $q"
    case "$q" in *"delay ${half}ms"*) ;; *) echo "ASSERT FAIL($side): delay not ${half}ms/dir" >&2; bad=1;; esac
    case "$q" in *"rate 200Mbit"*) ;; *) echo "ASSERT FAIL($side): rate not 200Mbit" >&2; bad=1;; esac
    if [ "$loss" = "0" ]; then
      case "$q" in *loss*) echo "ASSERT FAIL($side): loss present, this cell must be 0%" >&2; bad=1;; esac
    else
      case "$q" in *"loss ${loss}%"*) ;; *) echo "ASSERT FAIL($side): loss not ${loss}%" >&2; bad=1;; esac
    fi
  done
  [ "$bad" = 0 ] || { echo "LAB STATE WRONG ($when) - refusing to report these numbers" >&2; exit 3; }
}

# cell <label> <rtt> <loss> <probe_span_bytes>
#
# The probe span differs per cell on purpose: the fair comparison for a
# per-connection spread is at equal transfer DURATION, not equal bytes. A
# 0.5%-loss flow at 250ms RTT moves ~30x less than a clean one, so an equal
# span would compare a 25s transfer against a 1s transfer and the shorter one
# would look artificially steady. Achieved durations are recorded either way.
cell() {
  local label=$1 rtt=$2 loss=$3 span=$4
  echo
  echo "=============== $label (netem: rtt ${rtt}ms, loss ${loss}%/dir, 200mbit) ==============="
  /root/lab.sh set "$rtt" "$loss" 200mbit
  assert_cell "$rtt" "$loss" before
  /root/lab.sh ping || true

  echo "--- probe (plain curl, 8 conns, span $span) ---"
  $LABRUN perl /root/regime-probe.pl --url "$URL" --span "$span" --conns 8 \
      --reps "$REPS" --label "$label" --csv "$PCSV"

  echo "--- bigcurl -l trace ---"
  rm -f /tmp/rs.bin /tmp/rs.bin.part /tmp/rs.bin.part.state
  $LABRUN perl /root/trace-signal.pl --bigcurl /root/bigcurl --url "$URL" \
      --sha "$SHA" --out /tmp/rs.bin --reps "$REPS" --label "$label" --csv "$TCSV"
  rm -f /tmp/rs.bin /tmp/rs.bin.part /tmp/rs.bin.part.state

  assert_cell "$rtt" "$loss" after
}

# Optional cell names as args 2+ run a subset, for replicating one pair
# without paying for the whole sweep. Default is all three.
WANT="${*:2}"
want() { [ -z "$WANT" ] && return 0; case " $WANT " in *" $1 "*) return 0;; *) return 1;; esac; }

/root/lab.sh up
want clean-rtt250-loss0   && cell clean-rtt250-loss0   250 0   $((8*1024*1024))
want lossy-rtt100-loss0.5 && cell lossy-rtt100-loss0.5 100 0.5 $((2*1024*1024))
want lossy-rtt250-loss0.5 && cell lossy-rtt250-loss0.5 250 0.5 $((1024*1024))
/root/lab.sh down

echo
echo "=== probe csv ==="; cat "$PCSV"
echo "=== trace csv ==="; cat "$TCSV"
echo "REGIME LAB COMPLETE"
