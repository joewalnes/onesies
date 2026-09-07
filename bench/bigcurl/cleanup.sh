#!/bin/bash
# cleanup.sh - remove this benchmark run's scratch from one origin host.
#
#   cleanup.sh <host> [--yes] [--dry-run]
#
#   <host>   REQUIRED. One of the known bench hosts: hetzner | droplet
#            (or their exact public IP). There is deliberately no default
#            and no free-form host: an unrecognised name is a usage error,
#            never a run against something unintended.
#   --yes    skip the interactive confirmation
#   --dry-run  list what would go, touch nothing
#
# What it removes: staged bigcurl builds, harness scripts, CSV/log outputs,
# out-*.bin and diag-* artefacts, /tmp work directories, and the netem lab.
#
# What it deliberately LEAVES, so the host stays a usable origin and never
# needs re-provisioning:
#   * nginx and its bench.conf (all six ports keep serving)
#   * every fixture under /srv/bench, including SHA256SUMS
#   * the aria2 / axel / curl packages
#
# It also kills no processes. Two `while pgrep` loops on the Hetzner box
# predate this run and are not ours to reap.
#
# Joe Walnes <joe@walnes.com>, 2026, MIT License
# https://github.com/joewalnes/onesies
set -euo pipefail

# ---------------------------------------------------------------- config ---
# AIDEV-NOTE: the allowlist IS the safety mechanism. Resolving a free-form
# argument straight into `ssh root@$1` would let a typo point a recursive
# delete at an unrelated machine, so only these keys are accepted.
HETZNER_ADDR=5.78.179.108
DROPLET_ADDR=143.198.232.48

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# Paths removed on every host. Globs are expanded ON THE REMOTE HOST.
REMOVE_GLOBS=(
  '/root/bigcurl' '/root/bigcurl-*' '/root/bigcurl.*'
  '/root/*.csv' '/root/*.log'
  '/root/out-*.bin' '/root/diag-*'
  '/root/bench.pl' '/root/bench2.pl' '/root/byteproxy.sh'
  '/root/grid.sh' '/root/grid2.sh' '/root/mygrid.sh' '/root/lab.sh'
  '/root/steady.sh' '/root/overhead.sh' '/root/extra.sh' '/root/dc.sh'
  '/root/dc-cap8.sh' '/root/h2-vs-h1.sh' '/root/starlink.sh'
  '/root/cap_run.sh' '/root/cap_run_lab.sh'
  '/root/netem_run.sh' '/root/netem_run_big.sh'
  '/root/ba.sh' '/root/ba2.sh' '/root/sweep.sh' '/root/sweep2.sh'
  '/root/zprobe.sh' '/root/diag2.sh' '/root/diag3.sh' '/root/diag4.sh'
  '/root/regime-client.sh' '/root/regime-probe.pl' '/root/trace-signal.pl'
  '/root/regime-lab.sh' '/root/regime-verdict.py' '/root/regime-synthorigin.py'
  '/root/regression-lab.sh' '/root/regression-dc.sh' '/root/regression-analyze.py'
  '/root/probe-size-lab.sh' '/root/tailmetric.pl' '/root/analyze.py'
  '/root/setup-server.sh' '/root/setup-droplet.sh' '/root/setup.log'
  '/tmp/labwork' '/tmp/dcwork' '/tmp/steadywork' '/tmp/ohwork'
  '/tmp/slwork' '/tmp/benchwork' '/tmp/rswork' '/tmp/extra' '/tmp/ba2'
  '/tmp/bigcurl.*' '/tmp/modetest-*' '/tmp/h2capcheck' '/tmp/stracecheck'
  '/tmp/urls.txt' '/tmp/bc.log' '/tmp/st.txt' '/tmp/d.*.bin' '/tmp/p.[0-9]*'
)

# AIDEV-NOTE: anything matching these is refused even if a glob above reaches
# it. Belt and braces against a future edit widening a pattern by accident.
PROTECT_RE='^/srv/bench|^/etc/nginx|^/usr|^/bin|^/lib|^/boot|^/root/\.ssh|^/+$'

# ------------------------------------------------------------- arguments ---
usage() {
  cat >&2 <<EOF
usage: cleanup.sh <host> [--yes] [--dry-run]

  <host>      REQUIRED, one of:
                hetzner   ($HETZNER_ADDR)
                droplet   ($DROPLET_ADDR)
  --yes       skip the confirmation prompt
  --dry-run   show what would be removed, change nothing

Removes this run's benchmark scratch. Leaves nginx, the /srv/bench fixtures
and the aria2/axel packages in place, so the host keeps serving without
being re-provisioned.
EOF
  exit 2
}

HOST_KEY=""
ASSUME_YES=0
DRY_RUN=0

[ $# -ge 1 ] || { echo "cleanup.sh: a host argument is required" >&2; usage; }

for arg in "$@"; do
  case "$arg" in
    --yes)     ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    --*)       echo "cleanup.sh: unknown option '$arg'" >&2; usage ;;
    *)
      [ -z "$HOST_KEY" ] || { echo "cleanup.sh: only one host may be given (got '$HOST_KEY' and '$arg')" >&2; usage; }
      HOST_KEY="$arg"
      ;;
  esac
done

# An empty or missing host is a usage error, not a default.
[ -n "$HOST_KEY" ] || { echo "cleanup.sh: a host argument is required" >&2; usage; }

case "$HOST_KEY" in
  hetzner|"$HETZNER_ADDR") NAME=hetzner; ADDR=$HETZNER_ADDR; HAS_LAB=1 ;;
  droplet|"$DROPLET_ADDR") NAME=droplet; ADDR=$DROPLET_ADDR; HAS_LAB=0 ;;
  *)
    echo "cleanup.sh: '$HOST_KEY' is not a known bench host." >&2
    echo "cleanup.sh: refusing to guess. Use 'hetzner' or 'droplet'." >&2
    usage
    ;;
esac

for g in "${REMOVE_GLOBS[@]}"; do
  if printf '%s' "$g" | grep -Eq "$PROTECT_RE"; then
    echo "cleanup.sh: INTERNAL: glob '$g' hits a protected path; refusing to run." >&2
    exit 3
  fi
done

SSH=(ssh "${SSH_OPTS[@]}" "root@$ADDR")

echo "host: $NAME ($ADDR)"
"${SSH[@]}" true || { echo "cleanup.sh: cannot reach $NAME ($ADDR)" >&2; exit 1; }

# --------------------------------------------------------------- survey ---
# Ask the host what actually exists, so the confirmation prompt lists real
# paths rather than the patterns we hope match something.
GLOB_LIST=$(printf '%s\n' "${REMOVE_GLOBS[@]}")

VICTIMS=$("${SSH[@]}" "bash -s" <<REMOTE
set -u
shopt -s nullglob dotglob
while IFS= read -r g; do
  for p in \$g; do [ -e "\$p" ] && printf '%s\n' "\$p"; done
done <<'GLOBS'
$GLOB_LIST
GLOBS
REMOTE
)
# a path can match more than one glob (/root/setup.log matches both '*.log'
# and its own entry); list each victim once so the count is the truth.
VICTIMS=$(printf '%s\n' "$VICTIMS" | awk 'NF && !seen[$0]++')

if [ -z "$VICTIMS" ]; then
  echo "nothing to remove: $NAME is already clean"
else
  echo
  echo "will remove from $NAME:"
  printf '%s\n' "$VICTIMS" | sed 's/^/  /'
  echo
  echo "  ($(printf '%s\n' "$VICTIMS" | wc -l | tr -d ' ') paths)"
fi

if [ "$HAS_LAB" = 1 ]; then
  echo
  echo "will tear down the netem lab (netns 'bcli', veth vbench0/vbench1)"
fi

cat <<EOF

will KEEP (host stays a working origin, no re-provision needed):
  nginx + /etc/nginx/conf.d/bench.conf  (ports 8080-8085)
  /srv/bench fixtures + SHA256SUMS
  aria2 / axel / curl packages
no processes will be killed.
EOF

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: nothing was changed"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  echo
  printf 'proceed? [y/N] '
  read -r reply </dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

# --------------------------------------------------------------- remove ---
# The lab goes first: lab.sh is itself on the removal list, and tearing the
# namespace down after deleting the script that does it leaves it stranded.
if [ "$HAS_LAB" = 1 ]; then
  echo "tearing down the netem lab..."
  "${SSH[@]}" '
    if [ -x /root/lab.sh ]; then /root/lab.sh down || true
    else ip netns del bcli 2>/dev/null || true; ip link del vbench0 2>/dev/null || true; fi
  ' || true
fi

echo "removing scratch..."
"${SSH[@]}" "bash -s" <<REMOTE
set -u
shopt -s nullglob dotglob
n=0
while IFS= read -r g; do
  for p in \$g; do
    case "\$p" in
      /srv/bench*|/etc/nginx*|/usr/*|/bin/*|/lib/*|/boot/*|/root/.ssh*|/) continue ;;
    esac
    [ -e "\$p" ] || continue
    rm -rf -- "\$p" && n=\$((n+1))
  done
done <<'GLOBS'
$GLOB_LIST
GLOBS
echo "removed \$n paths"
REMOTE

# ---------------------------------------------------------------- verify ---
# AIDEV-NOTE: assert the origin still serves AFTER cleaning. A cleanup that
# quietly breaks the host is worse than one that leaves scratch behind.
echo "verifying the origin still serves..."
"${SSH[@]}" '
  fail=0
  systemctl is-active --quiet nginx || { echo "  FAIL: nginx is not active"; fail=1; }
  for f in /srv/bench/*.bin; do :; done
  n=$(ls /srv/bench/*.bin 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || { echo "  FAIL: no fixtures left under /srv/bench"; fail=1; }
  echo "  fixtures present: $n"
  # AIDEV-NOTE: 8085 is cleartext HTTP/2 (h2c), reachable ONLY with
  # --http2-prior-knowledge -- a plain HTTP/1.1 probe against it correctly
  # returns 000, which reads as a failure if you probe it like the others.
  for p in 8080 8081 8082 8083 8084; do
    c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -r 0-1023 "http://127.0.0.1:$p/shard-1.bin" 2>/dev/null || echo 000)
    printf "  port %s -> %s\n" "$p" "$c"
  done
  if curl -s --http2-prior-knowledge -o /dev/null --max-time 10 -r 0-1023 "http://127.0.0.1:8085/shard-1.bin" 2>/dev/null; then
    printf "  port 8085 -> %s (h2c)\n" "$(curl -s -o /dev/null -w '%{http_code}' --http2-prior-knowledge --max-time 10 -r 0-1023 http://127.0.0.1:8085/shard-1.bin)"
  else
    printf "  port 8085 -> not serving h2c\n"
  fi
  for t in aria2c axel curl; do
    command -v $t >/dev/null || { echo "  FAIL: $t is gone"; fail=1; }
  done
  [ "$fail" = 0 ] && echo "  origin OK" || { echo "  ORIGIN DEGRADED"; exit 1; }
'

echo "done: $NAME cleaned, origin intact"
