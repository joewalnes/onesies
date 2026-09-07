#!/bin/bash
U=http://10.200.0.1:8080/lab-32m.bin; R="/root/lab.sh run"
t(){ perl -e 'use Time::HiRes; print Time::HiRes::time()'; }
/root/lab.sh up >/dev/null; /root/lab.sh set 100 0.5 200mbit >/dev/null
echo "--- 100ms / 0.5% loss, 32MB ---"
for i in 1 2 3; do
  rm -f /tmp/d.bin*; a=$(t); $R aria2c -q -x8 -s8 -k1M --file-allocation=none -d /tmp -o d.bin "$U" >/dev/null 2>&1; b=$(t)
  perl -e "printf('  aria2 -x8            %5.2f MB/s'.\"\n\", 32/($b-$a))"
  a=$(t); $R bash -c "for i in 0 1 2 3 4 5 6 7; do s=\$((i*4194304)); curl -sS -r \$s-\$((s+4194303)) -o /tmp/p.\$i '$U' & done; wait"; b=$(t)
  perl -e "printf('  8x raw curl 4MB each %5.2f MB/s'.\"\n\", 32/($b-$a))"; rm -f /tmp/p.*
  rm -f /tmp/d.bin*; a=$(t); $R /root/bigcurl -l -n 8 -o /tmp/d.bin "$U" > /tmp/bc.log 2>&1; b=$(t)
  perl -e "printf('  bigcurl -n8          %5.2f MB/s'.\"\n\", 32/($b-$a))"
  echo "     retries: $(grep -c '"event":"retry"' /tmp/bc.log)  reasons: $(grep -o '"reason":"[^"]*"' /tmp/bc.log | sort | uniq -c | tr '\n' ';')"
done
echo "--- one curl, 4MB range, under loss: time to first byte and total ---"
for i in 1 2 3; do $R curl -sS -r 0-4194303 -o /dev/null -w "  ttfb %{time_starttransfer}s total %{time_total}s  %{speed_download} B/s\n" "$U"; done
/root/lab.sh down >/dev/null
