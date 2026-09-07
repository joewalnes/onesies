# Synthetic origin with three selectable impairment models, used to validate
# that regime-probe.pl can tell them apart before spending scarce host time.
#   RATE_MBPS   per-connection rate cap   (independent pipes, no randomness)
#   SHARED_MBPS global rate cap           (one pipe split N ways)
#   STALL_P     per-chunk probability of a random pause, per connection
#               (stochastic per-connection impairment - a loss model)
import http.server, os, random, socketserver, sys, threading, time
ROOT = sys.argv[2]
RATE   = float(os.environ.get('RATE_MBPS', '0'))
SHARED = float(os.environ.get('SHARED_MBPS', '0'))
STALL_P= float(os.environ.get('STALL_P', '0'))
STALL_MS=float(os.environ.get('STALL_MS', '120'))
_lock = threading.Lock()
_state = {'t0': None, 'sent': 0}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_GET(self):
        p = os.path.join(ROOT, os.path.basename(self.path))
        if not os.path.isfile(p): self.send_error(404); return
        sz = os.path.getsize(p)
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            lo, hi = rng[6:].split('-')
            lo = int(lo); hi = int(hi) if hi else sz - 1
            hi = min(hi, sz - 1); n = hi - lo + 1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {lo}-{hi}/{sz}')
        else:
            lo, n = 0, sz; self.send_response(200)
        self.send_header('Content-Length', str(n))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        rnd = random.Random()
        with open(p, 'rb') as f:
            f.seek(lo); left = n; t0 = time.time(); sent = 0
            while left > 0:
                b = f.read(min(65536, left))
                if not b: break
                try: self.wfile.write(b)
                except Exception: return
                left -= len(b); sent += len(b)
                if STALL_P and rnd.random() < STALL_P:
                    time.sleep(STALL_MS / 1000.0)
                if RATE:
                    d = sent / (RATE * 1e6) - (time.time() - t0)
                    if d > 0: time.sleep(d)
                if SHARED:
                    with _lock:
                        if _state['t0'] is None: _state['t0'] = time.time()
                        _state['sent'] += len(b)
                        d = _state['sent'] / (SHARED * 1e6) - (time.time() - _state['t0'])
                    if d > 0: time.sleep(min(d, 2.0))
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True
S(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
