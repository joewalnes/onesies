#!/bin/bash
U=http://10.200.0.1:8080/lab-32m.bin; R="/root/lab.sh run"
t(){ perl -e 'use Time::HiRes; print Time::HiRes::time()'; }
M=1048576
/root/lab.sh up >/dev/null; /root/lab.sh set 100 0.5 200mbit >/dev/null
rep(){ name="$1"; shift; tot=0; for i in 1 2 3 4; do rm -f /tmp/p.* /tmp/d.bin*; a=$(t); "$@" >/dev/null 2>&1; b=$(t); v=$(perl -e "print 32/($b-$a)"); tot=$(perl -e "print $tot+$v"); printf '%5.2f ' "$v"; done; perl -e "printf('  <- %-38s mean %5.2f MB/s'.\"\n\",'$name',$tot/4)"; }
echo "--- 100ms / 0.5% loss, 32MB, 8 connections everywhere ---"
rep "aria2 -x8 -k1M (dynamic 1MB pieces)" $R aria2c -q -x8 -s8 -k1M --file-allocation=none -d /tmp -o d.bin "$U"
rep "aria2 -x8 -k4M (dynamic 4MB pieces)" $R aria2c -q -x8 -s8 -k4M --file-allocation=none -d /tmp -o d.bin "$U"
rep "8 curl, one 4MB range each" $R bash -c "for i in 0 1 2 3 4 5 6 7; do s=\$((i*4*$M)); curl -sS -r \$s-\$((s+4*$M-1)) -o /tmp/p.\$i '$U' & done; wait"
rep "8 curl, 4x1MB contiguous via --next" $R bash -c "for i in 0 1 2 3 4 5 6 7; do b=\$((i*4)); curl -sS -r \$((b*$M))-\$(((b+1)*$M-1)) -o /tmp/p.\$i.0 '$U' --next -r \$(((b+1)*$M))-\$(((b+2)*$M-1)) -o /tmp/p.\$i.1 '$U' --next -r \$(((b+2)*$M))-\$(((b+3)*$M-1)) -o /tmp/p.\$i.2 '$U' --next -r \$(((b+3)*$M))-\$(((b+4)*$M-1)) -o /tmp/p.\$i.3 '$U' & done; wait"
rep "8 curl, 4x1MB striped via --next" $R bash -c "for i in 0 1 2 3 4 5 6 7; do curl -sS -r \$((i*$M))-\$(((i+1)*$M-1)) -o /tmp/p.\$i.0 '$U' --next -r \$(((i+8)*$M))-\$(((i+9)*$M-1)) -o /tmp/p.\$i.1 '$U' --next -r \$(((i+16)*$M))-\$(((i+17)*$M-1)) -o /tmp/p.\$i.2 '$U' --next -r \$(((i+24)*$M))-\$(((i+25)*$M-1)) -o /tmp/p.\$i.3 '$U' & done; wait"
rep "16 curl, one 2MB range each" $R bash -c "for i in \$(seq 0 15); do s=\$((i*2*$M)); curl -sS -r \$s-\$((s+2*$M-1)) -o /tmp/p.\$i '$U' & done; wait"
rep "32 curl, one 1MB range each" $R bash -c "for i in \$(seq 0 31); do s=\$((i*$M)); curl -sS -r \$s-\$((s+$M-1)) -o /tmp/p.\$i '$U' & done; wait"
/root/lab.sh down >/dev/null
