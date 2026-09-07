#!/bin/bash
# Provision a benchmark origin: nginx on several ports, each with a different
# server behaviour, plus the fixture files. Idempotent.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq nginx aria2 axel curl python3 >/dev/null 2>&1 || \
  apt-get install -y -qq nginx aria2 curl python3 >/dev/null

ROOT=/srv/bench
mkdir -p "$ROOT/small"

mk() {  # mk <path> <size-MB>
  [ -f "$1" ] && [ "$(stat -c %s "$1")" = "$(( $2 * 1048576 ))" ] && return 0
  head -c "$(( $2 * 1048576 ))" /dev/urandom > "$1"
}

mk "$ROOT/big-1g.bin" 1024
for i in $(seq 1 8); do mk "$ROOT/shard-$i.bin" 128; done
if [ ! -f "$ROOT/small/f001.bin" ]; then
  for i in $(seq -w 1 500); do head -c 1048576 /dev/urandom > "$ROOT/small/f$i.bin"; done
fi
sha256sum "$ROOT"/big-1g.bin "$ROOT"/shard-*.bin > "$ROOT/SHA256SUMS"
chmod -R a+r "$ROOT"

cat > /etc/nginx/conf.d/bench.conf <<'NGINX'
# Benchmark origins. Each port models a different real-world server behaviour.
limit_conn_zone $binary_remote_addr zone=benchconn:10m;

# 8080 - baseline: ranges, keepalive, no limits at all
server {
    listen 8080 default_server;
    root /srv/bench;
    autoindex on;
    sendfile on;
    tcp_nopush on;
    access_log off;
}

# 8081 - per-connection rate cap, the classic CDN shape
server {
    listen 8081;
    root /srv/bench;
    limit_rate 4m;
    sendfile on;
    access_log off;
}

# 8082 - per-IP connection cap: punishes over-parallelism with 503s
server {
    listen 8082;
    root /srv/bench;
    limit_conn benchconn 4;
    limit_conn_status 503;
    sendfile on;
    access_log off;
}

# 8083 - no Range support: forces the single-stream fallback
server {
    listen 8083;
    root /srv/bench;
    max_ranges 0;
    sendfile on;
    access_log off;
}

# 8084 - rate cap AND connection cap together
server {
    listen 8084;
    root /srv/bench;
    limit_rate 4m;
    limit_conn benchconn 8;
    limit_conn_status 503;
    sendfile on;
    access_log off;
}

# 8085 - HTTP/2 origin (ASK 4), cleartext h2c via prior knowledge.
# AIDEV-NOTE: nginx <1.25.1 (this host is 1.24.0) only speaks h2 over TLS
# via `listen ... ssl http2;` with ALPN, OR cleartext h2c via the legacy
# `listen <port> http2;` form -- but the latter has NO upgrade path from
# HTTP/1.1; it only answers a client that sends the HTTP/2 connection
# preface immediately (curl's --http2-prior-knowledge). A plain
# `curl --http2` GET against this port will NOT upgrade and gets nothing
# useful. h2c was chosen over `ssl http2` specifically so the H1-vs-H2
# comparison measures multiplexing alone, not multiplexing confounded with
# a TLS handshake -- see REPRODUCE.md for the measured verification that
# this port actually negotiates h2 (not a silent 1.1 fallback that still
# returns 200) and for a worked example of 4 ranges sharing one connection.
# Otherwise identical to the 8080 baseline: ranges, keepalive, no limits.
server {
    listen 8085 http2;
    root /srv/bench;
    autoindex on;
    sendfile on;
    tcp_nopush on;
    access_log off;
}
NGINX

nginx -t >/dev/null 2>&1
systemctl reload nginx 2>/dev/null || systemctl restart nginx

# Open the ports if a firewall is active
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  for p in 8080 8081 8082 8083 8084 8085; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
fi

echo "READY $(hostname)"
for p in 8080 8081 8082 8083 8084; do
  printf '  :%s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -r 0-1023 "http://127.0.0.1:$p/shard-1.bin")"
done
# 8085 verified separately and explicitly for protocol, not just status code:
# a fallback to HTTP/1.1 still returns 200/206 and would look identical to
# success in the loop above.
H2V=$(curl -s -o /dev/null -w '%{http_version} %{http_code} %{size_download}' \
  --http2-prior-knowledge -r 0-1023 "http://127.0.0.1:8085/shard-1.bin")
printf '  :8085 %s (http_version must be 2)\n' "$H2V"
case "$H2V" in
  "2 "*) ;;
  *) echo "FATAL: :8085 did not negotiate HTTP/2 (got: $H2V)" >&2; exit 1 ;;
esac
df -h /srv | tail -1
