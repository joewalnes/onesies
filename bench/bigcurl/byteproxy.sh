#!/bin/bash
# byteproxy.sh - fetch one URL as N ranged curl processes with NO perl
# anywhere in the byte path, as the ceiling instrument for ASK 2 (see
# REPRODUCE.md, "ASK 2: is perl in the byte path worth removing?").
#
#   byteproxy.sh curlo  N url out    # N curl -o pieces, concatenated after
#   byteproxy.sh curldd N url out    # N `curl -r ... | dd seek=...` pipes
#
# NOT bigcurl: no resume, no block bitmap, no byte-exact progress, no stall
# detection, no adaptive pool, no auth/header passthrough. This script exists
# to answer one question - what is the ceiling N parallel connections can
# reach with zero perl involvement in reading or writing downloaded bytes -
# so it can be compared against `bigcurl -n N` at the SAME N. Comparing
# across different N is exactly the mistake ASK 1's measurement caught
# bigcurl-auto making; this script is meant to be driven at a pinned N to
# avoid repeating it.
#
# Two modes, two different proxies for the two ASK-2 candidates:
#
#   curlo  - each piece is written directly by curl (curl's own C code, no
#            perl reads a single byte of it) to its own file, then all
#            pieces are joined with one sequential `cat` into `out`. This
#            UNDERSTATES candidate 1 ("curl -o per piece with incremental
#            append"): a real incremental-append implementation still needs
#            perl to open/append/close each piece as it completes, which
#            this single end-of-run cat does not pay for. Treat curlo's
#            number as an optimistic ceiling for candidate 1, not candidate
#            1 itself.
#
#   curldd - each piece is streamed `curl -r a-b url | dd of=out seek=...
#            conv=notrunc` directly into its slice of the final file - no
#            perl, no concatenation pass, no second write. This is a direct
#            proxy for candidate 2 ("curl | dd").
#
# PORTABILITY (the ask's hard requirement is Linux AND macOS): dd's `seek=`
# is in units of `bs`, and BSD/macOS dd has no `oflag=seek_bytes` (that is
# GNU/Linux-only) to seek an arbitrary byte offset with bs>1. So curldd here
# only works correctly when every piece boundary is an exact multiple of
# $BS - true for this suite's 1 GiB fixture split into 1/2/4/8/16 pieces,
# but NOT true in general (arbitrary file size / N). It refuses to run
# rather than silently writing at the wrong offset when that assumption
# doesn't hold. A real implementation would need either bs=1 (slow, extra
# syscalls) or GNU-only oflag=seek_bytes on Linux and a different mechanism
# on macOS - which is itself evidence against curl|dd as a portable
# candidate, independent of its measured throughput. Recorded here, not
# hidden.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -uo pipefail

BS=$((1024*1024))   # dd block size for curldd; piece boundaries must divide this

usage() { echo "usage: byteproxy.sh <curlo|curldd> <n> <url> <out>" >&2; exit 2; }
[ $# -eq 4 ] || usage
mode=$1 n=$2 url=$3 out=$4
case "$mode" in curlo|curldd) ;; *) usage ;; esac
case "$n" in ''|*[!0-9]*) usage ;; esac
[ "$n" -ge 1 ] || usage

size=$(curl -sSI -L "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
if [ -z "${size:-}" ]; then
    echo "byteproxy.sh: could not read Content-Length from $url" >&2
    exit 1
fi

piece=$(( (size + n - 1) / n ))

if [ "$mode" = curldd ] && [ $((piece % BS)) -ne 0 ] && [ "$piece" -lt "$size" ]; then
    echo "byteproxy.sh: curldd needs piece size ($piece) to be a multiple of" \
         "$BS for portable dd seeking (size=$size n=$n) - refusing to guess" >&2
    exit 1
fi

rm -f "$out" "$out".part*
: > "$out"   # curldd writes into slices of this file; curlo overwrites it at the end

pids=""
pieces=""
i=0
while [ "$i" -lt "$n" ]; do
    start=$(( i * piece ))
    if [ "$start" -ge "$size" ]; then break; fi
    end=$(( start + piece - 1 ))
    [ "$end" -ge "$size" ] && end=$((size - 1))
    if [ "$mode" = curlo ]; then
        p="${out}.part${i}"
        pieces="$pieces $p"
        curl -sS --fail -r "${start}-${end}" -o "$p" "$url" &
        pids="$pids $!"
    else
        blk=$(( start / BS ))
        ( set -o pipefail
          curl -sS --fail -r "${start}-${end}" "$url" \
            | dd of="$out" bs=$BS seek="$blk" conv=notrunc 2>/dev/null
        ) &
        pids="$pids $!"
    fi
    i=$((i + 1))
done

rc=0
for pid in $pids; do
    wait "$pid" || rc=1
done
[ "$rc" -eq 0 ] || { echo "byteproxy.sh: a worker failed" >&2; exit 1; }

if [ "$mode" = curlo ]; then
    cat $pieces > "$out" || exit 1
    rm -f $pieces
fi

exit 0
