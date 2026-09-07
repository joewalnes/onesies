#!/bin/bash
# lab.sh - a controlled network between two namespaces on one box.
#
#   lab.sh up                       create the netns + veth pair
#   lab.sh set <rtt_ms> <loss_%> <rate>   apply conditions (both directions)
#   lab.sh run <cmd...>             run a command as the client
#   lab.sh down                     tear it all down
#
# The server is the host itself (nginx on 10.200.0.1); the client lives in the
# 'bcli' namespace. netem is applied to both veth ends, so <rtt_ms> is the
# round trip and <loss_%> is per direction.
set -euo pipefail
NS=bcli
HOST_IF=vbench0
NS_IF=vbench1

case "${1:-}" in
up)
  ip netns del $NS 2>/dev/null || true
  ip link del $HOST_IF 2>/dev/null || true
  ip netns add $NS
  ip link add $HOST_IF type veth peer name $NS_IF
  ip link set $NS_IF netns $NS
  ip addr add 10.200.0.1/24 dev $HOST_IF
  ip link set $HOST_IF up
  ip link set $HOST_IF mtu 1500
  ip netns exec $NS ip addr add 10.200.0.2/24 dev $NS_IF
  ip netns exec $NS ip link set $NS_IF up
  ip netns exec $NS ip link set lo up
  ip netns exec $NS ip link set $NS_IF mtu 1500
  ip netns exec $NS ip route add default via 10.200.0.1
  echo "lab up"
  ;;
set)
  RTT=${2:-0}; LOSS=${3:-0}; RATE=${4:-200mbit}
  HALF=$(python3 -c "print(f'{${RTT}/2:.3f}')")
  for spec in "$HOST_IF:" "$NS_IF:netns"; do
    IF=${spec%%:*}; MODE=${spec##*:}
    if [ "$MODE" = "netns" ]; then RUN="ip netns exec $NS"; else RUN=""; fi
    $RUN tc qdisc del dev $IF root 2>/dev/null || true
    if [ "$RTT" = "0" ] && [ "$LOSS" = "0" ]; then
      $RUN tc qdisc add dev $IF root netem rate $RATE limit 20000
    elif [ "$LOSS" = "0" ]; then
      $RUN tc qdisc add dev $IF root netem delay ${HALF}ms rate $RATE limit 20000
    else
      $RUN tc qdisc add dev $IF root netem delay ${HALF}ms loss ${LOSS}% rate $RATE limit 20000
    fi
  done
  # AIDEV-NOTE: read the qdisc back on BOTH veth ends and fail loudly if it is
  # not what we just asked for. A suite that silently inherits a previous
  # worker's netem config produces numbers labelled with the wrong conditions,
  # which is worse than no numbers at all.
  echo "lab set rtt=${RTT}ms loss=${LOSS}%/dir rate=$RATE"
  echo "  readback $HOST_IF: $(tc qdisc show dev $HOST_IF | tr -s ' ')"
  echo "  readback $NS_IF:   $(ip netns exec $NS tc qdisc show dev $NS_IF | tr -s ' ')"
  for spec in "$HOST_IF:" "$NS_IF:netns"; do
    IF=${spec%%:*}; MODE=${spec##*:}
    if [ "$MODE" = "netns" ]; then RUN="ip netns exec $NS"; else RUN=""; fi
    Q=$($RUN tc qdisc show dev $IF)
    case "$Q" in *netem*) ;; *) echo "FATAL: no netem on $IF" >&2; exit 1 ;; esac
    # tc prints "50ms" where we asked for "50.000ms", and "0.5%" for "0.5%",
    # so compare the parsed numbers, not the formatted strings.
    if [ "$RTT" != "0" ]; then
      GOT=$(echo "$Q" | sed -n 's/.*delay \([0-9.]*\)ms.*/\1/p')
      python3 -c "import sys;sys.exit(0 if abs(float('${GOT:-0}')-float('$HALF'))<0.01 else 1)" \
        || { echo "FATAL: $IF delay is ${GOT:-none}ms, asked ${HALF}ms: $Q" >&2; exit 1; }
    fi
    if [ "$LOSS" != "0" ]; then
      GOT=$(echo "$Q" | sed -n 's/.*loss \([0-9.]*\)%.*/\1/p')
      python3 -c "import sys;sys.exit(0 if abs(float('${GOT:-0}')-float('$LOSS'))<0.001 else 1)" \
        || { echo "FATAL: $IF loss is ${GOT:-none}%, asked ${LOSS}%: $Q" >&2; exit 1; }
    fi
  done
  ;;
run)
  shift
  exec ip netns exec $NS "$@"
  ;;
ping)
  ip netns exec $NS ping -c 5 -q 10.200.0.1 | tail -2
  ;;
down)
  ip netns del $NS 2>/dev/null || true
  ip link del $HOST_IF 2>/dev/null || true
  echo "lab down"
  ;;
*) echo "usage: lab.sh up|set <rtt> <loss> <rate>|run <cmd>|ping|down"; exit 2 ;;
esac
