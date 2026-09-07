#!/bin/bash
# h2-vs-h1.sh - ASK 4 evidence: does one HTTP/2 connection with N
# multiplexed streams beat N separate HTTP/1.1 connections, across a
# spread of RTT and loss, on the netem lab?
#
# Instrument: curl's H2 against curl's H1 -- NOT bigcurl. This is a proxy
# for what stream multiplexing in bigcurl might buy; it does not exercise
# bigcurl itself. See REPRODUCE.md for that caveat spelled out, and for why
# the H2 origin (port 8085) is cleartext h2c rather than TLS: h2c avoids
# confounding "one connection, many streams" with "plus a TLS handshake".
#
# Runs on the origin host itself (where the netem lab lives), as root:
#   /root/lab.sh up
#   ./h2-vs-h1.sh
#   /root/lab.sh down
#
# AIDEV-NOTE: this script issues the shell commands itself but the actual
# network transfers must happen *inside* the lab's client namespace, so
# every curl is wrapped with `$LABRUN` (== "/root/lab.sh run"). Forgetting
# that wrapper on any one call would silently measure the unconstrained
# loopback/LAN path instead of the netem'd link -- easy mistake, hard to
# notice, because the run still "succeeds" and posts a number.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -uo pipefail

# --- config -------------------------------------------------------------
LAB=/root/lab.sh
LABRUN="$LAB run"
FIXTURE_ROOT=/srv/bench
# All of these are env-overridable so the same script can also run the
# "steady-state, clean high-RTT" addendum with a 1GB file (see steady.sh's
# rationale: a 32MB file at 250ms RTT is mostly TCP slow start, which is
# exactly the regime ASK 4's premise is not about).
FILE="${FILE:-lab-32m.bin}"
STREAMS="${STREAMS:-8}"          # matches the bigcurl -n8 baseline elsewhere in this suite
RTTS="${RTTS:-0 25 100 250}"      # ms, matches grid.sh's grid for comparability
LOSSES="${LOSSES:-0 0.1 0.5}"     # pct per direction, matches grid.sh's grid
RATE="${RATE:-200mbit}"
REPS="${REPS:-3}"
MAXTIME="${MAXTIME:-90}"         # per-rep curl safety valve; loss+small RTT can stall otherwise
OUT="${OUT:-/root/h2-vs-h1.csv}"
WORK=/tmp/h2v-h1-work
H1_URL="http://10.200.0.1:8080/$FILE"
H2_URL="http://10.200.0.1:8085/$FILE"
# --------------------------------------------------------------------------

FIXTURE="$FIXTURE_ROOT/$FILE"
[ -f "$FIXTURE" ] || { echo "FATAL: fixture $FIXTURE not found on this host" >&2; exit 1; }
SIZE=$(stat -c %s "$FIXTURE")
CHUNK=$(( SIZE / STREAMS ))
# AIDEV-NOTE: sha computed fresh from the file on THIS host, every run --
# never hardcode this. Fixture bytes have changed across provisions before.
SHA=$(sha256sum "$FIXTURE" | awk '{print $1}')

mkdir -p "$WORK"
rm -f "$OUT"
echo "rtt_ms,loss_pct,tool,rep,seconds,mbps,verified" > "$OUT"

now() { perl -e 'use Time::HiRes; print Time::HiRes::time()'; }

# many H1 connections in parallel, one range each -- the "N connections" arm
run_h1() {
  rm -f "$WORK"/h1.*
  local pids=()
  local i s e
  for ((i = 0; i < STREAMS; i++)); do
    s=$(( i * CHUNK ))
    e=$(( i == STREAMS - 1 ? SIZE - 1 : s + CHUNK - 1 ))
    $LABRUN curl -sS --http1.1 --max-time "$MAXTIME" \
      -r "$s-$e" -o "$WORK/h1.$i" "$H1_URL" &
    pids+=("$!")
  done
  local p
  for p in "${pids[@]}"; do wait "$p"; done
}

# one H2 connection, N multiplexed streams via -Z/--next -- the "1 connection" arm
run_h2() {
  rm -f "$WORK"/h2.*
  # AIDEV-NOTE: -Z/--parallel is a global option (applies once, to the whole
  # invocation); --http2-prior-knowledge and --max-time are PER-TRANSFER and
  # curl resets them at each --next boundary unless repeated. Measured the
  # hard way: an earlier version set --max-time once up front and only the
  # first of 8 streams was actually capped -- a run under severe loss ran to
  # 125s against a 90s "cap". Repeat both on every group.
  local args=(-sS -Z)
  local i s e
  for ((i = 0; i < STREAMS; i++)); do
    s=$(( i * CHUNK ))
    e=$(( i == STREAMS - 1 ? SIZE - 1 : s + CHUNK - 1 ))
    [ "$i" -gt 0 ] && args+=(--next)
    args+=(--http2-prior-knowledge --max-time "$MAXTIME")
    args+=(-r "$s-$e" -o "$WORK/h2.$i")
    args+=("$H2_URL")
  done
  $LABRUN curl "${args[@]}"
}

# verify <prefix> -> prints 1 (sha matches) or 0
verify() {
  cat "$WORK/$1".* > "$WORK/$1.cat" 2>/dev/null
  local got
  got=$(sha256sum "$WORK/$1.cat" 2>/dev/null | awk '{print $1}')
  [ "$got" = "$SHA" ] && echo 1 || echo 0
}

ROWS=0
for RTT in $RTTS; do
  for LOSS in $LOSSES; do
    $LAB set "$RTT" "$LOSS" "$RATE" >/dev/null
    for rep in $(seq 1 "$REPS"); do
      # AIDEV-NOTE: interleaved (h1 rep, then h2 rep, repeat) not batched --
      # see REPRODUCE.md's note on bench.pl for why: batching charges one
      # arm for whatever the link happened to be doing in its whole window.
      a=$(now); run_h1; b=$(now)
      ok=$(verify h1)
      t=$(perl -e "printf('%.3f', $b-$a)")
      mbps=$(perl -e "printf('%.2f', ($SIZE/1048576)/($b-$a))")
      echo "$RTT,$LOSS,h1x${STREAMS}conn,$rep,$t,$mbps,$ok" >> "$OUT"
      ROWS=$((ROWS + 1))

      a=$(now); run_h2; b=$(now)
      ok=$(verify h2)
      t=$(perl -e "printf('%.3f', $b-$a)")
      mbps=$(perl -e "printf('%.2f', ($SIZE/1048576)/($b-$a))")
      echo "$RTT,$LOSS,h2x${STREAMS}stream,$rep,$t,$mbps,$ok" >> "$OUT"
      ROWS=$((ROWS + 1))
    done
  done
done

rm -rf "$WORK"

# AIDEV-NOTE: a script that reads/measures nothing and exits 0 has burned
# this project before (see REPRODUCE.md pitfalls). Assert the row count
# matches what the grid promises, not just "greater than zero".
NRTT=$(echo "$RTTS" | wc -w); NLOSS=$(echo "$LOSSES" | wc -w)
EXPECT=$(( NRTT * NLOSS * REPS * 2 ))
if [ "$ROWS" -ne "$EXPECT" ]; then
  echo "FATAL: expected $EXPECT rows, wrote $ROWS -- a scenario was skipped" >&2
  exit 1
fi
echo "H2-VS-H1 COMPLETE: $ROWS rows -> $OUT"
