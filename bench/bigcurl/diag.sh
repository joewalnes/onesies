#!/bin/bash
# Why does bigcurl trail aria2 on a clean high-RTT path?
# Compare against a hand-rolled 8-way curl to separate "parallel in principle"
# from "bigcurl's own overhead".
set -uo pipefail
U=http://10.200.0.1:8080/lab-32m.bin
SZ=33554432
R="/root/lab.sh run"
t() { perl -e 'use Time::HiRes; print Time::HiRes::time()'; }
timeit() {
  local name="$1"; shift
  local a b
  rm -f /tmp/d.bin /tmp/d.bin.part /tmp/d.bin.part.state /tmp/d.bin.aria2
  a=$(t); "$@" >/dev/null 2>&1; b=$(t)
  perl -e "printf('  %-26s %6.2fs  %6.2f MB/s'.\"\n\", '$name', $b-$a, ($SZ/1048576)/($b-$a))"
}
/root/lab.sh up >/dev/null
for RTT in 100 250; do
  /root/lab.sh set $RTT 0 200mbit >/dev/null
  echo "--- rtt ${RTT}ms, no loss ---"
  timeit "curl (1 stream)"        $R curl -sS -o /tmp/d.bin "$U"
  timeit "aria2 -x8 -k1M"         $R aria2c -q -x8 -s8 -k1M --file-allocation=none -d /tmp -o d.bin "$U"
  # 8 hand-rolled range curls, one connection each, exactly what bigcurl does
  a=$(t)
  $R bash -c "for i in 0 1 2 3 4 5 6 7; do s=\$((i*4194304)); e=\$((s+4194303)); curl -sS -r \$s-\$e -o /tmp/p.\$i '$U' & done; wait"
  b=$(t)
  perl -e "printf('  %-26s %6.2fs  %6.2f MB/s'.\"\n\", '8x raw curl ranges', $b-$a, ($SZ/1048576)/($b-$a))"
  rm -f /tmp/p.*
  timeit "bigcurl -n 8"           $R /root/bigcurl -s -n 8 -o /tmp/d.bin "$U"
  timeit "bigcurl -n 8 -B 4M"     $R /root/bigcurl -s -n 8 -B 4M -o /tmp/d.bin "$U"
  timeit "bigcurl -n 16"          $R /root/bigcurl -s -n 16 -o /tmp/d.bin "$U"
  rm -f /tmp/d.bin
done
/root/lab.sh down >/dev/null
