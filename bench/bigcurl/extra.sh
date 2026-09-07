#!/bin/bash
# extra.sh - the tests that are about behaviour rather than raw speed.
set -uo pipefail
BC=/root/bigcurl
BASE=${1:-http://10.200.0.1:8080}
HOST=${2:-lab}
W=/tmp/extra; rm -rf $W; mkdir -p $W; cd $W

pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1));
        else echo "  FAIL $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }

echo "== $HOST: server behaviours =="
REF=$(curl -sS "$BASE/shard-1.bin" | sha256sum | cut -d' ' -f1)

# 1. no Range support -> single stream fallback, correct bytes
NR=${BASE%:*}:8083
rm -f f; $BC -s -o f "$NR/shard-1.bin"; rc=$?
chk "no-range server: exit 0" "$rc" "0"
chk "no-range server: bytes intact" "$(sha256sum f | cut -d' ' -f1)" "$REF"
rm -f f

# 2. per-IP connection cap (503 under over-parallelism)
CC=${BASE%:*}:8082
rm -f f; $BC -s -n 24 -o f "$CC/shard-1.bin"; rc=$?
chk "conn-capped server: exit 0" "$rc" "0"
chk "conn-capped server: bytes intact" "$(sha256sum f 2>/dev/null | cut -d' ' -f1)" "$REF"
rm -f f

# 3. 404 -> exit 4
$BC -s -o f "$BASE/nope.bin" >/dev/null 2>&1; chk "404 exit code" "$?" "4"
rm -f f

# 4. resume integrity under repeated kills
echo "== $HOST: chaos resume (10 kills on a 128MB file) =="
SRC="$BASE/shard-2.bin"
REF2=$(curl -sS "$SRC" | sha256sum | cut -d' ' -f1)
rm -f c.bin c.bin.part c.bin.part.state
total_before=0
for i in $(seq 1 10); do
  $BC -s -n 8 -o c.bin "$SRC" >/dev/null 2>&1 &
  p=$!
  perl -e "select(undef,undef,undef,0.3+rand()*0.9)"
  kill -9 $p 2>/dev/null
  wait $p 2>/dev/null
  [ -f c.bin ] && break
done
$BC -s -n 8 -o c.bin "$SRC" >/dev/null 2>&1
chk "chaos: final bytes intact" "$(sha256sum c.bin | cut -d' ' -f1)" "$REF2"
# how much did we re-fetch overall?
rm -f c.bin c.bin.part c.bin.part.state

# 5. many small files vs xargs -P8 curl
echo "== $HOST: 200 x 1MB files =="
SM=$(seq -w 1 200 | sed "s|^|$BASE/small/f|; s|$|.bin|")
rm -rf many; mkdir many; cd many
t0=$(perl -e 'use Time::HiRes; print Time::HiRes::time()')
echo "$SM" | xargs -P 8 -n 1 curl -sS -O >/dev/null 2>&1
t1=$(perl -e 'use Time::HiRes; print Time::HiRes::time()')
n1=$(ls | wc -l); cd ..; rm -rf many; mkdir many; cd many
echo "$SM" > /tmp/urls.txt
t2=$(perl -e 'use Time::HiRes; print Time::HiRes::time()')
$BC -s -i /tmp/urls.txt >/dev/null 2>&1
t3=$(perl -e 'use Time::HiRes; print Time::HiRes::time()')
n2=$(ls | wc -l); cd ..
printf "  xargs -P8 curl : %.2fs (%s files)\n" "$(echo "$t1 - $t0" | bc)" "$n1"
printf "  bigcurl -i     : %.2fs (%s files)\n" "$(echo "$t3 - $t2" | bc)" "$n2"

echo "== $HOST: $pass passed, $fail failed =="
