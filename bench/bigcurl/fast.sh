#!/bin/bash
# Quick A/B on the fast paths. $1 = URL, $2 = size bytes, $3 = outdir
U=$1; SZ=$2; D=${3:-/tmp}
t(){ perl -e 'use Time::HiRes; print Time::HiRes::time()'; }
run(){ n="$1"; shift; rm -f "$D"/o.bin "$D"/o.bin.part "$D"/o.bin.part.state "$D"/o.bin.aria2
  a=$(t); "$@" >/dev/null 2>&1; b=$(t)
  perl -e "printf(\"  %-24s %7.1f MB/s\n\",\"$n\",($SZ/1048576)/($b-$a))"; }
for i in 1 2; do
run "curl"            curl -sS -o "$D/o.bin" "$U"
run "aria2 -x8"       aria2c -q -x8 -s8 -k1M --file-allocation=none -d "$D" -o o.bin "$U"
run "bigcurl-base -n8" /root/bigcurl-base -s -n 8 -o "$D/o.bin" "$U"
run "bigcurl-new -n8"  /root/bigcurl -s -n 8 -o "$D/o.bin" "$U"
done
rm -f "$D"/o.bin*
