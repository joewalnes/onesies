# Reproducing the bigcurl benchmarks

Everything here is self-contained: two shell scripts to provision, one Perl
harness to measure, one Python script to summarise.

## Hosts used

| role | host | location | spec |
|---|---|---|---|
| origin + lab | `joe-hetzner1` (5.78.179.108) | Hetzner, Hillsboro OR | 16 core, 30 GB |
| origin + client | `joe-droplet1` (143.198.232.48) | DigitalOcean, Santa Clara CA | 1 core, 1 GB |
| client | desktop | Starlink | macOS 26.2 |

Both cloud hosts sit behind provider firewalls that block inbound ports, so
client→origin traffic goes over the Tailscale tailnet. Both paths were verified
*direct* (not DERP-relayed) and add no measurable RTT: droplet→hetzner is
16.2 ms over the public path and 16.4 ms over the tailnet.

## Provision

    scp setup-server.sh root@<origin>:/root/
    ssh root@<origin> bash /root/setup-server.sh

Installs nginx, aria2, axel; builds the fixtures under `/srv/bench`; and serves
them on five ports, each modelling a different server behaviour:

| port | behaviour |
|---|---|
| 8080 | baseline: ranges, keepalive, no limits |
| 8081 | `limit_rate 4m` — per-connection cap, the classic CDN shape |
| 8082 | `limit_conn 4` per IP, 503 on excess |
| 8083 | `max_ranges 0` — no Range support at all |
| 8084 | rate cap *and* connection cap |
| 8085 | HTTP/2 cleartext (h2c, prior knowledge) — otherwise identical to 8080 (ASK 4 origin) |

Port 8085 is additive: it was appended after 8084 in `setup-server.sh` and the
5 original server blocks (8080-8084) are byte-for-byte unchanged, so every
number measured against them before this change is still valid.

### Port 8085 — the ASK 4 origin (HTTP/2)

`listen 8085 http2;` with no `ssl` — cleartext HTTP/2 ("h2c"), reachable only
via curl's `--http2-prior-knowledge` (there is no Upgrade: h2c path on this
nginx). This was a deliberate choice over `listen ... ssl http2;`:

* **h2c was chosen over TLS h2** so an H1-vs-H2 comparison measures stream
  multiplexing alone, not multiplexing confounded with a TLS handshake. A
  TLS origin and a cleartext origin are not the same instrument — mixing
  them would leave "is it faster" answering two questions at once.
* The host's nginx is 1.24.0, which predates 1.25.1's `http2 on;` directive,
  so the legacy `listen <port> http2;` form is used instead. That form is
  prior-knowledge only.

**Verified, not assumed** — a fallback to HTTP/1.1 still returns 200/206 and
looks exactly like success if you only check the status code:

    $ curl -s -o /dev/null -w 'http_version=%{http_version} code=%{http_code}\n' \
        --http2-prior-knowledge -r 0-1023 http://<origin>:8085/shard-1.bin
    http_version=2 code=206

`setup-server.sh` runs this exact check (with a `case` guard) on every
provision and exits non-zero if it ever sees anything but `2 `. The guard
was proven to bite before being trusted: run against port 8080 (no `http2`
listener at all), the same probe returns `http_version=0 code=000` — curl's
raw HTTP/2 preface makes no sense to an HTTP/1.1-only listener, so it fails
loudly rather than quietly downgrading. And the specific "silent fallback
that returns 200" shape this task warned about — the *upgrade* path, plain
`curl --http2` (no prior knowledge) against 8085 — also fails loudly here
rather than silently succeeding: nginx's legacy h2c listener doesn't speak
the `Upgrade: h2c` dance at all, so curl gets a mangled response and errors
out (`curl: (1) Received HTTP/0.9 when not allowed`) instead of quietly
completing over HTTP/1.1. (measured, both directions)

**Multiplexing itself was verified**, not assumed from the protocol
existing: 4 concurrent ranged requests issued from one
`curl -Z --http2-prior-knowledge ... --next ...` invocation all logged
against the same nginx `$connection` id, confirmed via a temporary
`log_format` on the host — one TCP connection, four streams.

## The controlled lab (`lab.sh`)

Creates a veth pair into a network namespace and puts `netem` on both ends, so
RTT and loss are exact and reproducible rather than whatever the internet was
doing that minute.

    lab.sh up
    lab.sh set <rtt_ms> <loss_pct_per_direction> <rate>
    lab.sh run <command...>      # runs as the client, inside the namespace
    lab.sh down

`grid.sh` sweeps RTT × loss over that lab; its output becomes `lab-results.csv`
(below) once committed.

## Measuring (`bench.pl`)

    bench.pl --base http://host:8080 --path big-1g.bin --label "scenario" \
             --tools curl,aria2-8,bigcurl-8 --reps 5 --sha <sha256> \
             --bigcurl /path/to/bigcurl --out results.csv

Notes on method:

* **Repetitions are interleaved, not batched.** All tools run once, then all
  tools run again. Batching every repetition of one tool charges that tool for
  whatever the link was doing during its window — which matters a lot on
  Starlink.
* **Every run is verified**, not just timed: the output is sha256'd against a
  reference copy. A fast wrong answer scores zero.
* `--timeout` caps a run and records it as failed; the throughput it did
  achieve is still recorded, so a capped single-stream run is still a data point.
* The first `--warmup` passes are discarded.
* Output files are removed between runs — otherwise bigcurl correctly skips a
  file that is already complete and posts an absurd time.

## Summarising

    ./analyze.py            # all CSVs, median MB/s per scenario and tool
    ./analyze.py ask2       # just the ASK 2 tables (ask2-droplet.csv, ask2-hetzner.csv)

## ASK 4: does H2 multiplexing beat H1 multi-connection? (`h2-vs-h1.sh`)

ASK 4 proposes HTTP/2 multiplexing — one connection, many streams — selected
by the tuner on "clean high-RTT links only", because a shared congestion
window is supposed to make it worse under loss. That claim was unmeasured
before this. This is the measurement.

**Instrument, named plainly:** this is curl's HTTP/1.1 (N parallel
connections, one curl process each) against curl's HTTP/2 (one curl process,
N ranges multiplexed via `-Z --http2-prior-knowledge ... --next ...`, proven
above to share one connection). **It is not bigcurl.** It is a proxy for
what stream multiplexing in bigcurl might buy — bigcurl was not modified for
this task. RTT and loss come from `lab.sh`'s netem, not Starlink or the real
internet; netem's loss model is uniform-random per packet, which is not
identical to real bufferbloat/burst loss, though it is the same instrument
every other number in this report was measured with.

    lab.sh up
    ./h2-vs-h1.sh                    # 32MB file, RTT x loss grid, 3 reps -> h2-vs-h1-lab.csv
    FILE=big-1g.bin RTTS="100 250" LOSSES=0 REPS=2 MAXTIME=300 \
      OUT=h2-vs-h1-steady.csv ./h2-vs-h1.sh   # steady-state addendum, see below
    lab.sh down

Both arms fetch the same file, split into 8 equal-size ranges (8, to match
the `bigcurl -n8` baseline used throughout this report), and every run is
sha256-verified against a hash computed fresh on the host — never a
hardcoded or reused one (`verified` column: 1 = matched, 0 = did not).
`--max-time` bounds every run; a run that hits the cap is recorded as a
failure, not skipped. (One bug paid for here: `--max-time` is a per-transfer
curl option that resets at each `--next` boundary, so an earlier version of
this script only capped the *first* of the 8 H2 streams — a run under
severe loss ran to 125s against a nominal 90s cap. Fixed by repeating
`--max-time` after every `--next`; re-verified the fix actually bites by
timing the worst-case cell directly: 90s elapsed against a 90s cap, not 125.)

### Result 1 — 32MB file, RTT x loss grid (`h2-vs-h1-lab.csv`, 72 rows, all sha256-verified)

Median MB/s of 3 interleaved reps. This file size is small enough that the
clean-RTT cells are mostly TCP slow start (same caveat `steady.sh` already
notes for the 8080-baseline suite) — see Result 2 for the steady-state
retest of the specific case this matters for.

| RTT | loss | H1 x8 conn (MB/s) | H2 x8 stream (MB/s) | H2 vs H1 |
|---:|---:|---:|---:|---:|
| 0 | 0% | 22.30 | 22.15 | tied |
| 0 | 0.1% | 22.18 | 22.18 | tied |
| 0 | 0.5% | 22.21 | 22.06 | tied |
| 25 | 0% | 20.87 | 19.57 | H1 +7% |
| 25 | 0.1% | 19.17 | 19.53 | tied |
| 25 | 0.5% | 8.92 | 2.87 | **H1 3.1x faster** |
| 100 | 0% | 11.90 | 13.53 | H2 +14% |
| 100 | 0.1% | 9.15 | 12.82 | H2 +40% |
| 100 | 0.5% | 2.14 | 0.44 | **H1 4.9x faster** |
| 250 | 0% | 7.05 | 6.56 | tied |
| 250 | 0.1% | 4.13 | 0.76 | **H1 5.4x faster** |
| 250 | 0.5% | 1.19 | 0.36 (0/3 verified — every rep hit the 90s cap incomplete) | **H1 wins; H2 did not finish** |

### Result 2 — steady-state, clean link, 1GB file (`h2-vs-h1-steady.csv`, 8 rows, all sha256-verified)

This isolates exactly the case ASK 4's premise is about — clean (0% loss),
high RTT, past slow start — with a file large enough to reach steady state.

| RTT | loss | H1 x8 conn (MB/s) | H2 x8 stream (MB/s) | H2 vs H1 |
|---:|---:|---:|---:|---:|
| 100 | 0% | 22.43 (median of 2) | 22.27 (median of 2) | tied |
| 250 | 0% | 21.70 (median of 2) | 12.34 (median of 2) | **H1 1.8x faster** |

The 250ms/0% pair reproduced tightly across both reps (H1: 47.24s, 47.15s;
H2: 82.99s, 83.07s) — this is not noise. (assumed mechanism, not measured
further: curl's HTTP/2 flow-control window is shared across the 8
multiplexed streams on one connection, and as RTT grows the
bandwidth-delay product outgrows that shared window well before it outgrows
8 independent H1 congestion windows. This would be a *second*, RTT-driven
failure mode distinct from the loss-driven "shared congestion window" ASK 4
names — investigating which one dominates would need packet captures and is
out of scope here.)

### Verdict

**The premise does not hold, in either half.** ASK 4 predicted H2 wins on
clean high-RTT links and loses under loss. Measured: it does not clearly
win anywhere — tied at RTT 0-100ms clean, and *slower* than plain H1 at the
one RTT (250ms) large and clean enough to reach steady state (1.8x slower,
measured, reproduced across reps) — and it loses badly and increasingly
under loss, up to complete failure to finish within a generous time budget
at 250ms/0.5% loss while H1 completed every single one of its 72+8 runs.
There is no crossover in this data where H2 wins by a margin worth having;
the closest thing to a win (100ms RTT, light loss, +14% to +40%) sits
inside a regime where H1 is already degraded and neither is fast in
absolute terms.

**Recommendation: do not build ASK 4.** A day spent adding stream
multiplexing to bigcurl would, on this evidence, produce a mode that is at
best tied with what bigcurl already does and at worst substantially worse,
with no clean-link RTT regime measured here where it pays for itself. If
this is revisited, the RTT-driven flow-control-window hypothesis above
would be the first thing to check (a bigger `--http2-default-window`-style
setting, if bigcurl ever grew HTTP/2 support, might close the 250ms/0%
gap) — but that is future work, not evidence this run produced.

### What this did NOT do

* Did not modify `cli/bigcurl` or `cli/bigcurl-test` — this proxies with
  curl's own H1/H2, per the task's scope.
* Did not test on Starlink or the droplet — netem only. Real-world loss is
  bursty, not the uniform-random model netem applies; a burstier loss
  process could plausibly change the loss-side numbers (probably not their
  direction).
* Did not sweep the stream count (fixed at 8, matching the suite's existing
  `-n8` baseline) or file size beyond the two points above (32MB, 1GB) —
  a fuller RTT x size x stream-count grid would firm up exactly where the
  250ms/0% gap opens, but the two points measured are enough to answer
  "is this worth building," which was the question.
* Did not chase the flow-control-window hypothesis with packet captures;
  it is offered as the most likely mechanism, marked (assumed), not as a
  confirmed root cause.
* Did not add HTTP/2 support to bigcurl itself — that is the entire point
  of measuring first.

## ASK 2: is perl in the byte path worth removing? (`byteproxy.sh`)

ASK 2 proposes taking perl out of bigcurl's byte path — today, each curl
worker writes to a pipe that a single perl process `sysread`s and
`syswrite`s into the output file (see `cli/bigcurl`'s own header comment).
Candidates: `curl -o` per piece with incremental append (perl still copies
each finished piece once — 2x writes total), or `curl | dd` (no perl
anywhere in the byte path). ASKS.md cites a droplet ceiling of 71 MB/s for
dd vs 45 for perl vs 77 for curl alone as the justification.

That 45 was flagged as suspect by the ASK 1 worker (see the `ask1-parallel`
merge commit and `tuner-knee.pl`'s header): it was measured against
whatever pool size bigcurl's tuner happened to pick, and the tuner
overshoots badly on this CPU-bound host (pinned ladder from that work: curl
71.9 | auto 41.9 | n2 61.9 | n4 62.0 | n8 57.7 | n16 43.1 | n20 38.4). If
45 was a tuner artefact rather than perl's true cost, ASK 2 might be
solving the wrong problem. This section re-measures perl's cost **at
matched connection count**, which the 71-vs-45 comparison was not.

**Instruments, named plainly.** `bigcurl -n N` is bigcurl itself, pinned —
`-n` disables the tuner entirely (`elsif ($fixed_conns) { # pinned by -n:
no growth, and no shrinking on mere noise }`), so this is a real pool size,
not wherever the tuner drifts to. `byteproxy.sh curlo N` and `byteproxy.sh
curldd N` (new, this task) are **not bigcurl** — no resume, no block
bitmap, no byte-exact progress, no stall detection, no adaptive pool. They
are ceiling instruments: N curl processes fetch equal-size ranges of the
same file concurrently, at the same N as the `bigcurl -n N` they are
compared against, with zero perl involvement in reading or writing the
downloaded bytes. `curlo` writes each piece directly with curl's own `-o`
and joins them with one `cat` at the end (this *understates* the real
candidate 1, which would pay an open/append/close per piece rather than
one sequential join — so treat curlo's number as optimistic for candidate
1). `curldd` streams each range through `curl -r a-b | dd of=out
bs=1M seek=... conv=notrunc` straight into its slice of the final file —
a direct proxy for candidate 2, no concatenation pass. Both were verified
byte-correct against a locally built range-serving test origin before
touching real hardware (sha256-exact at N=1/2/4/8/16, plus a refusal test
for `curldd` on a non-block-aligned size — see below).

**Portability note, stated up front because it bears on the recommendation
independent of speed:** `curldd`'s `dd seek=` is in units of `bs`, and
BSD/macOS `dd` has no `oflag=seek_bytes` (GNU/Linux-only) to seek an
arbitrary byte offset with `bs>1`. `byteproxy.sh` only works when every
piece boundary is a multiple of its 1 MiB block size — true for this
suite's 1 GiB fixture split into 1/2/4/8/16 pieces, and it **refuses to
run** (loud exit 1, not a silently wrong offset) when that doesn't hold,
verified against a 64 MiB + 500 byte fixture at N=4. A real `curl | dd`
implementation handling arbitrary file sizes and piece counts on macOS
would need a different mechanism (bs=1 is byte-exact but pays a syscall
per byte). This is a genuine hole in candidate 2 against the ask's own
HARD REQUIREMENT, separate from whatever its throughput turns out to be.

**Method.** Droplet (1 core) pulling `big-1g.bin` from Hetzner over the
tailnet, `bench.pl` with `curl,bigcurl-N,curlo-N,curldd-N` interleaved
(rep-major, not tool-major, same as every other suite here), N in {1, 2,
4} — 1 is the cleanest isolation point (no connection-count confound at
all between the perl and no-perl arms), 2 and 4 bracket the droplet
optimum the ASK-1 ladder found. 6 reps at N=1/2 (3 initial + 3 more taken
after the CPU numbers below turned out noisier than the throughput ones),
3 reps at N=4. Every run sha256-verified against a hash recomputed fresh
on the Hetzner host for this task (`cb87776a...483cd`), never reused from
a script or CSV. Full data: `ask2-droplet.csv` (49 rows incl. header, all
verified).

**Noise floor, measured, not assumed.** `curl` alone (single stream, no
splitting, no perl) is run in every batch as a control — it should not
depend on N at all, so its spread across batches is a direct read on how
noisy this host+link is on this day. Across all 9 `curl` reps: 81.2, 71.8,
81.8, 64.2, 77.9, 79.2, 69.6, 64.1, 74.4 MB/s — median 74.4, range 17.7
(24% of median), stdev 6.8. Any wall-clock effect smaller than that is not
distinguishable from noise with 3-6 reps.

### Result — throughput, median MB/s (droplet -> Hetzner, matched N)

| N | curl (ref) | bigcurl -n N | curlo-N (candidate 1 ceiling) | curldd-N (candidate 2 ceiling) |
|---:|---:|---:|---:|---:|
| 1 (n=6/6/3/6) | 74.4* | 57.2 | 57.3 | 65.8 |
| 2 (n=6/6/3/6) | 74.4* | 58.8 | 62.8 | 65.6 |
| 4 (n=3) | 69.6 | 57.6 | 57.8 | 74.2 |

\* curl's own median across all 9 reps, since it's N-independent by
construction; the per-batch curl medians (81.2, 77.9, 69.6) span the noise
range above and would be misleading to read as three different numbers.

### Result — CPU-seconds per GB transferred (perl's actual mechanism cost)

Wall-clock throughput on this link is noisy (see above); CPU time is not —
it isn't subject to link jitter, only to scheduler contention on the one
core, and it is literally where perl's `sysread`/`syswrite` loop spends
cycles. `times()` in `bench.pl` sums the perl process and every reaped
child, so this includes every curl/dd subprocess each tool spawns.

| N | curl (ref) | bigcurl -n N | curlo-N | curldd-N |
|---:|---:|---:|---:|---:|
| 1 | 2.11 | 3.52 | 3.85 | 3.17 |
| 2 | 2.13 | 4.02 | 4.14 | 3.38 |
| 4 | 2.28 | 4.71 | 4.26 | 3.42 |

Individual-rep ranges for bigcurl-N vs curldd-N **do not overlap at N=4**
(bigcurl-4 min 4.42 > curldd-4 max 3.44 — a clean separation) but **do
overlap at N=1 and N=2** (one curldd-2 rep hit 4.41 CPU-s/GB during a
contention event that also crashed that rep's throughput to 43 MB/s,
alongside curlo-2's simultaneous crash to 38 MB/s in the same rep — the
host was doing something else at that moment, not an instrument fault).
N=4 is therefore the only cell where "perl costs more CPU than the no-perl
ceiling" is established beyond noise, not just in the median.

### Perl's cost vs the no-perl ceiling (curldd), matched N, both metrics

| N | wall-clock cost | CPU cost |
|---:|---:|---:|
| 1 | 13.1% | 11.2% |
| 2 | 10.3% | 19.2% |
| 4 | 22.3% | **37.9%** (clean separation, see above) |

Both metrics agree on direction — perl's overhead **grows with N**, it
does not sit at a fixed percentage — and the cleanest, most confident
reading (N=4, non-overlapping CPU ranges) is also the pool size the ASK-1
ladder found near-optimal, i.e. the size bigcurl would actually want to
run at on this host.

### What ASKS.md's 71-vs-45-vs-77 figures reproduce, and what they do not

- **curl alone (77 cited):** measured 64-82 MB/s across batches, median
  74.4 — consistent within this link's noise. Reproduced.
- **dd ceiling (71 cited):** curldd-4 measured 74.2 MB/s (74.2, 76.4,
  71.9) — consistent. Reproduced, at N=4 specifically.
- **perl (45 cited): NOT reproduced at any matched N.** `bigcurl -n N`
  measured 57.2-58.8 MB/s at N=1/2/4 — 27-31% above the cited 45, at
  every pool size tested, including the near-optimal one. This matches
  the ASK-1 worker's hypothesis: 45 was the tuner's auto-picked pool
  (measured elsewhere as 41.9), not perl's cost at a sane, matched N.
  **Mark 45 "not reproduced," not "wrong"** — its exact original
  measurement conditions aren't known, only that pinning connection count
  does not reproduce it.

### Candidate 1 — `curl -o` per piece with incremental append: dead on arrival

`curlo-N` (its optimistic ceiling — real incremental append would cost
more, not less) is a wash with `bigcurl -n N` at every N measured: 57.3 vs
57.2 (N=1), 62.8 vs 58.8 (N=2, curlo's best showing at +6.7%, inside this
link's ~9% noise floor), 57.8 vs 57.6 (N=4). It also costs *more* CPU than
bigcurl at N=1 and N=2 (3.85 vs 3.52; 4.14 vs 4.02), only pulling slightly
ahead at N=4 (4.26 vs 4.71) — and that's before paying for the block
bitmap, byte-exact progress, and real (not proxied) incremental-append
logic candidate 1 would need. **Reject candidate 1 regardless of how the
dd question resolves** — it does not buy enough to be worth its own cost,
independent of anything below.

### Candidate 2 — `curl | dd`: a real, N-growing effect, but not portable as measured

Unlike candidate 1, candidate 2's ceiling is genuinely ahead of bigcurl,
and the gap grows with N rather than staying flat — the opposite of a
noise artifact, which would not have a consistent direction. At the
cleanest, most defensible point (N=4, non-overlapping CPU ranges): **perl
costs ~38% CPU and ~22% wall-clock** versus the no-perl ceiling, at the
connection count this host would actually run at. At N=1-2 the same
direction holds but the individual-rep ranges overlap, so call those
"probably real, not proven at this rep count."

This lands **in the gap the decision rule didn't resolve** (≲15% close /
≳40% build) rather than cleanly on either side — below the build bar on
wall-clock at every N, at-or-near it only on CPU at the realistic
operating point. Layered on top of that: the portability hole above means
`curl | dd` as literally specified does not satisfy the ask's own HARD
REQUIREMENT for arbitrary sizes on macOS without further engineering
(a different seeking mechanism, decided and built, not proxied).

### Verdict

**Do not build ASK 2 as specified in ASKS.md.** Candidate 1 is dead on
this data — reject it outright. Candidate 2 shows a real and directionally
consistent effect (growing with N, cleanly separated from noise only at
N=4), but (a) it lands in the decision rule's unresolved grey zone rather
than clearing the 40% bar that would justify a day of work, and (b) the
specific mechanism measured here (`dd seek=`) has a portability defect
against the ask's own hard requirement that would need solving first, on
top of losing the block bitmap, byte-exact progress, and stall detection
candidate 2 would also cost. None of that rules out revisiting perl's
per-byte cost cheaper: the CPU numbers say the *mechanism* (perl's
sysread/syswrite loop, not perl-the-language) is real and grows with pool
size, which argues for first trying to shrink that loop's overhead
directly (larger read chunks, fewer wakeups per byte) — a smaller, fully
portable change with none of dd's seek-alignment risk — before spending a
day removing perl from the byte path entirely. That is a different, much
smaller ask than the one on the table, and is not scoped or measured here.

### What this did NOT do

* Did not modify `cli/bigcurl` or `cli/bigcurl-test` — `byteproxy.sh` and
  `bench.pl`'s new `curlo-N`/`curldd-N` tool types are the only additions;
  `bigcurl -n N` is invoked as an unmodified black box (sha256-compared
  against this worktree's `cli/bigcurl` before every droplet run).
* Did not get a valid CPU-abundant control. The Hetzner-loopback attempt
  (`ask2-hetzner.csv`, 16 cores, N=4, 3 reps) finishes in well under a
  second per run — 1 GiB over loopback is fast enough that process
  fork/exec cost dominates over per-byte cost, and it shows curldd-4
  costing *more* CPU per GB than bigcurl-4 there (2.77 vs 1.43) — the
  opposite direction from the droplet, for a reason unrelated to the
  ask (curldd spawns twice as many processes as bigcurl for the same N,
  and that fixed cost swamps everything else at sub-second runtimes).
  This is reported as a failed control, not as evidence the effect
  reverses on abundant CPU. A valid version would need a rate-limited or
  latency-added Hetzner path long enough to reach steady state, which
  needs `lab.sh` — the LANE seat needs that instrument for long stretches,
  and building a second lab-based suite was out of scope for the time
  available here.
* Did not sweep N above 4 or below 1, or try file sizes other than 1 GiB.
* Did not chase the N=1/N=2 CPU-range overlap with more reps once the
  N=4 result (the operationally relevant pool size) came back clean and
  non-overlapping — more reps there would sharpen confidence at N=1/2 but
  would not change which side of the decision rule this lands on.
* Did not implement any candidate. A number and a recommendation were the
  deliverable; this branch touches nothing under `cli/`.

## Diagnostic scripts from the second pass

These are the experiments that found the root causes, kept because the report
cites their numbers:

| file | what it showed |
|---|---|
| `lossdiag.sh` | 8 raw curls doing one 4 MB range each get the same ~3 MB/s as bigcurl under loss — scheduling was not the problem |
| `lossdiag2.sh` | aria2c with 4 MB pieces falls to raw-curl speed; 32 curls x 1 MB is the fastest configuration — granularity is |
| `fast.sh` | loopback and fast-link A/B between builds |
| `diag.sh` | why bigcurl trailed aria2 on a clean 250 ms link (span cap shrinking as the pool filled) |
| `trace.py` | reads `bigcurl -l` output and prints connections and speed over time |
| `dc-cap8.sh` | the connection-capped scenario alone, re-run after the tuner changed |

## Files behind the published figures

| CSV | suite |
|---|---|
| `lab-results.csv` | netem grid, final build, 3 reps, every run verified |
| `starlink-results.csv` | Starlink desktop -> both origins, final build |
| `dc-results.csv` | droplet -> Hetzner, final build (cap-8 rows from `dc-cap8.sh`) |
| `steady-results.csv`, `overhead-results.csv` | 1 GB clean-path and loopback runs |
| `extra.log` | behaviour checks and the 200-file timing |
| `h2-vs-h1-lab.csv` | ASK 4: curl H1 vs curl H2, netem grid, 32MB file, 3 reps, every run verified |
| `h2-vs-h1-steady.csv` | ASK 4: curl H1 vs curl H2, netem, 1GB file, clean link only, 2 reps, every run verified |
| `ask2-droplet.csv` | ASK 2: droplet -> Hetzner, matched-N (curl/bigcurl-N/curlo-N/curldd-N), 1GB file, 6 reps at N=1/2, 3 at N=4, every run verified |
| `ask2-hetzner.csv` | ASK 2 attempted control: Hetzner loopback, N=4, 3 reps — inconclusive, see "What this did NOT do" in the ASK 2 section |

`compile-data.py`, `mkcharts.py`, `mkreport.py` and `build.py` turn those into
`bigcurl-benchmarks.html` from `report.tmpl.html`.

**Note on the table above, as of this pass:** the last four rows
(`h2-vs-h1-lab.csv`, `h2-vs-h1-steady.csv`, `ask2-droplet.csv`,
`ask2-hetzner.csv`) were committed by earlier work in this run but were not
actually read by `compile-data.py` — `grep` for each of them in that file
returned nothing. The pipeline built a report that never mentioned ASK 2 or
ASK 4 at all, despite three of the five items in `ASKS.md` having been closed
by measurement using exactly this data. This pass (`report-refresh`) wired
all four into `compile-data.py` and added the corresponding tables and prose
to `report.tmpl.html` (new "Experiment 5" and "Experiment 6" sections) — see
the git log for the `report-refresh` branch for the exact diff. The table
above is accurate again as written.

`tuner-knee.pl` is deliberately **not** part of this build pipeline: it is a
live local timing simulation (real sleeps, a real loopback TCP server), so
its output is not guaranteed bit-for-bit reproducible run to run, which would
break the determinism check below if it fed the report. Its own header says
the same about its numbers not being hardware-transferable in magnitude. The
connection-tuner ladder cited in the report's new "Experiment 6" section
(curl 71.9 | auto 41.9 | n2 61.9 | n4 62.0 | n8 57.7 | n16 43.1 | n20 38.4) is
quoted from hardware measurement recorded in the `ask1-parallel` merge commit
message (`c2c1623`), not from a CSV committed to this pass — there is no
CSV backing it in this tree. `tuner-knee.pl` was run once by hand as a
corroborating check that the overshoot's *direction* reproduces locally
(pool trace climbed 4 → 12 → 20 before correcting back down, matching the
shape of the real droplet trace 4 → 12 → 20), not to source any number in
the report.

**A units caveat on the existing ASK 2 write-up above ("CPU-seconds per GB
transferred" tables):** recomputing `ask2-droplet.csv` and `ask2-hetzner.csv`
directly for the new report sections turned up absolute CPU-seconds/GB
figures that run about 7.4% above the ones printed earlier in this file (for
example bigcurl-1: 3.78 here vs 3.52 above). The raw `cpu_user`/`cpu_sys`
values agree exactly — the difference is that this pass's numbers divide by
`bytes/2**30` (binary GiB), the same convention `compile-data.py`'s
pre-existing `overhead` CPU table already uses, while the ASK 2 write-up
above appears to have divided by decimal GB (1e9 bytes; 2**30/1e9 =
1.0737..., which is exactly the observed ratio). Every *percentage* in the
ASK 2 write-up above (11.2% / 19.2% / 37.9% CPU cost, 13.1% / 10.3% / 22.3%
wall-clock cost) is a ratio between two tools at the same N, so the GB/GiB
choice cancels out — those numbers were independently recomputed from the
CSV for this pass and match exactly. Only the absolute CPU-seconds-per-GB
figures in the older prose are off by that constant unit factor; the new
report sections use the binary-GiB convention for consistency with the rest
of the report and this file's caveat is here so the two don't quietly
disagree from a reader's point of view. The `bigcurl-benchmarks.html` build
is only as good as `report-data.json`, which is regenerated from the CSVs on
every build — it was not affected by this units question either way.

## Rebuilding the report and checking it hasn't drifted

    rm -f ../../bigcurl-benchmarks.html
    python3 compile-data.py && python3 mkcharts.py && python3 mkreport.py && python3 build.py
    shasum -a 256 ../../bigcurl-benchmarks.html
    wc -c ../../bigcurl-benchmarks.html

**Always delete the HTML before rebuilding.** `build.py` overwrites the file
whether or not it already exists, but if a prior step in the pipeline fails
silently the file can be left stale, and a stale file compared against
itself will report "byte-identical" and mean nothing.

As of the **final measurement pass** (build `8066b6a`; the five core suites
remeasured, and the ASK-by-ASK Outcomes section added to the report):

    sha256: cdbc08a59d2174fc7c470cce3a759930a5f8e0a38d1cf6f48fa5d3eb986b2af2
    bytes:  68411

verified by deleting the file, asserting it was gone, and rebuilding it twice
from scratch — the second rebuild also deleting `charts.json`, `tables.json`
and `report-data.json` so nothing was carried over. Both rebuilds produced
894 lines of byte-identical output (`diff` empty, both hashing and sizing as
above) and the built file contains zero unreplaced `{{...}}` placeholders.

The check is only worth running if it can fail: it is asserted that the HTML
is absent before each build and non-empty after, and the line count compared
is printed, so a build that silently failed to write cannot be read as
"byte-identical" against a stale file left on disk.

The previous pass (`report-refresh`) built sha256
`192d31aca862b32bcddc212360e360546920b333407703223b2f4b230707547e` (58053
bytes); that hash was reproduced exactly from the committed CSVs at the start
of this pass, before any new data landed, which is what establishes that the
pipeline is deterministic and the comparison below is meaningful. The hash
changed because five of the CSVs were replaced with fresh measurements and a
new Outcomes section was added.

The next pass that changes the report should replace the hash and byte count
above with its own, checked the same way.

## Regime signal: can bigcurl tell a lossy link from a contended one? (`regime-probe.pl`, `trace-signal.pl`)

Two capabilities in `cli/bigcurl` are switched off because nothing observable
at runtime separates the regimes they help from the regimes they hurt: the
connection tuner's growth rate (fast growth wins under loss, loses on the
1-core droplet) and `$HEDGE_TAIL_BLOCKS` (hedging wins under loss, loses on
Starlink). This pass measures whether such a signal exists. **It changes
nothing under `cli/`** — `bigcurl` is run as an unmodified black box.

The candidate signals, what the `-l` trace actually exposes, and the
predictions and thresholds registered *before* measuring are in `SIGNALS.md`.

### Instruments

* `regime-probe.pl` — plain `curl` only, no bigcurl. Fires N simultaneous
  equal-sized range requests and derives, per connection, transfer rate and
  duration, then reports `spread_cv` (stddev/mean of per-connection rate),
  `straggler` (max/median per-connection duration), and `speedup`
  (aggregate at N connections / aggregate at 1). It measures the quantities
  the trace *cannot*: bigcurl computes a per-request rate internally
  (`$req_rate`) but never emits it.
* `trace-signal.pl` — runs bigcurl `-l` N times and derives from the trace
  alone: retries/MB, stall fraction, steady-state throughput CV, pool
  trajectory (`progress.conns`), and tail fraction.

Both refuse to report rather than average over a partial measurement.
`regime-probe.pl` discards any rep in which a connection returned the wrong
status or byte count and dies if every rep was discarded; `trace-signal.pl`
discards a rep failing sha256 or yielding fewer than three steady-state
progress samples, dies if none survive, and warns below three.

Rate the CV only in steady state: `progress.speed` is an EMA starting at zero,
and including the ramp read a CV of 0.87 against an idle loopback origin.

### Validating the instruments first (no host time)

`regime-synthorigin.py` is a local range-capable origin with three selectable,
*known* impairment models — a per-connection rate cap, one global rate cap
split N ways, and random per-connection pauses. Point the probe at it before
trusting any field number (CLAUDE.md's ASK 3 lesson: a previous worker
reported "0 duplicates" from a binary it had forgotten to instrument).

    RATE_MBPS=0.4 python3 regime-synthorigin.py 18899 /path/to/dir &
    ./regime-probe.pl --url http://127.0.0.1:18899/big.bin \
        --span $((4*1024*1024)) --conns 8 --reps 4 \
        --label ctlA-perconn-cap --csv regime-controls.csv

then `SHARED_MBPS=3.2` for control B and `STALL_P=0.05 STALL_MS=500` for
control C. Results are in `regime-controls.csv` and tabulated in `SIGNALS.md`;
they establish that `straggler` and `speedup` are **orthogonal** axes.

### Running the netem cells (Hetzner)

    scp regime-probe.pl trace-signal.pl regime-lab.sh lab.sh \
        root@<hetzner>:/root/
    scp ../../cli/bigcurl root@<hetzner>:/root/bigcurl
    ssh root@<hetzner> 'sha256sum /root/bigcurl'      # compare against git
    ssh root@<hetzner> 'bash /root/regime-lab.sh 5'

`regime-lab.sh` sets each cell explicitly and reads `tc qdisc show` back on
*both* veth ends before and after, refusing to report on any mismatch — the
lab is not assumed clean, and a previous worker has left netem configured.
It recomputes the fixture sha256 on the host on every run. Cells:
`clean-rtt250-loss0`, `lossy-rtt100-loss0.5`, `lossy-rtt250-loss0.5`, all at
200mbit against `/srv/bench/shard-1.bin`.

The probe span is per-cell on purpose: a per-connection spread is only
comparable at equal transfer *duration*. A 0.5%-loss flow at 250 ms RTT moves
roughly 30x less than a clean one, so an equal span would compare a 25 s
transfer against a 1 s transfer and score the shorter one as the steadier link.

**netem loss is a model of a lossy link, not a lossy link.** Every row from
these cells carries that caveat.

### Running the real-network clients

Same two instruments, no netem. `--sha` must be computed on the *origin* host
immediately before the run:

    SHA=$(ssh root@<hetzner> 'sha256sum /srv/bench/shard-1.bin' | awk '{print $1}')

CPU-bound (the 1-core droplet as client, pulling from Hetzner over the tailnet
— this is the host on which slowing pool growth measured +25%):

    scp regime-*.pl regime-client.sh trace-signal.pl root@<droplet>:/root/
    scp ../../cli/bigcurl root@<droplet>:/root/bigcurl
    ssh root@<droplet> 'bash /root/regime-client.sh --label cpubound-droplet \
        --base http://100.82.150.18:8080 --path big-1g.bin --sha <SHA> \
        --span $((64*1024*1024)) --reps 5 --bigcurl /root/bigcurl \
        --workdir /tmp/rswork'

Bandwidth-contended (this desktop on real Starlink, the link ASK 3's hedging
regression was measured on):

    ./regime-client.sh --label starlink-desktop \
        --base http://100.82.150.18:8080 --path shard-1.bin --sha <SHA> \
        --span $((16*1024*1024)) --reps 5 \
        --bigcurl ../../cli/bigcurl --workdir /tmp/rswork

`regime-client.sh` range-checks the origin before measuring, so a client
silently receiving 200s fails as a configuration error rather than as a pile
of discarded reps.

### Outputs

Compute the separation margins and check the pre-registered thresholds with:

    ./regime-verdict.py regime-signal-probe.csv regime-signal-probe-rep2.csv \
        -- regime-signal-trace.csv regime-signal-trace-rep2.csv

It tests strict non-overlap (lowest lossy rep vs highest non-lossy rep, across
every pass) rather than comparing medians, and refuses to draw a verdict from
fewer than four rows per side.

`regime-probe.csv` and `regime-trace.csv` (one row per regime), collected off
the hosts into `regime-signal-probe.csv` and `regime-signal-trace.csv`. The
verdict, with spreads, is the table at the end of `SIGNALS.md`.

## Regression sweep

Seven commits touched `cli/bigcurl` between the build `lab-results.csv` /
`dc-results.csv` / `starlink-results.csv` were measured against
(`da87807`, the file as first written) and the current tip (`ca7df5e`):
probe-free start (`35fb076`), a 100%-progress-snapshot fix (`b588249`),
rename-into-place (`f07a639`), committed regression tests plus an
empty-file probe fix (`ebd02e6`), the `prepare_job()` open-guard fix
(`9c34286`), and the tmpdir-collision fix (`ca7df5e`). Each was measured
only on the scenario it targeted. This is the first time the cumulative
result has been checked against the headline scenarios.

**One thing fell out of reading the diff before measuring anything:** the
connection tuner's growth-rate experiment from ASK 1
(`72622fe`/`0021228`/`17d54a0`) is a real ancestor of the current tip but
nets to a **zero-line diff** against `da87807` — `17d54a0` reverted it
byte-for-byte, which is why `git log -- cli/bigcurl` doesn't even show
those commits (history simplification drops a merge that is tree-same for
the path). Confirmed directly: `git diff da87807 ca7df5e -- cli/bigcurl`
touches only `block_size`, `run_probe_batch`/`run_probe_each`/
`apply_probe`, `state_clear`, and `prepare_job` — no hunk anywhere near the
pool-growth code. So the mechanism ASKS.md's open question is most worried
about (tuner growth rate under loss) is provably unchanged from the
original build; what *did* change is entirely in probe/first-block
handling and job setup. That narrows, but does not eliminate, the risk:
the probe is now a real ranged GET for up to `PROBE_RANGE` (1 MiB) instead
of a HEAD or a 1-byte range, which is genuine extra bytes-under-loss on
the very first request of every job — plausibly a wash (it replaces a
request that used to happen anyway) or plausibly a cost, not yet measured
under loss before this sweep.

### Cells chosen, and why

Full re-runs of every committed grid would cost more host time than this
task can spend on the shared lab/droplet hosts. Three regions were chosen
because a regression there would matter most:

1. **Lossy netem, `rtt100ms/loss0.5pct` and `rtt250ms/loss0.5pct`.** The
   exact two cells ASKS.md's open question names as where the tuner
   experiment regressed 19.5% and 28% (before being reverted). This is
   where bigcurl beats plain curl by ~25x — the product's reason to exist —
   and where the new ranged-GET probe's extra first-request bytes could
   plausibly cost the most under loss.
2. **`rtt25ms/loss0.5pct`, clean-link `rtt250ms/loss0pct`.** Cheaper
   cells from the same grid, included because they were nearly free once
   the lab was up: one gives a second, lighter-loss lossy point; the other
   isolates clean high-RTT, which is where probe-free start is most likely
   to show a *win* rather than a regression (fewer round trips before the
   first payload byte).
3. **Droplet plain origin (`do-sfo>hz-ore/plain`), 1-core, CPU-bound.**
   The `prepare_job()` open-guard fix and the tmpdir-collision fix both
   touch `prepare_job()`, which runs once per job on the byte path's setup
   side; a CPU-starved host is where extra syscalls per job would show up
   first. This is also the scenario the ASK 1/ASK 2 tuner-overshoot
   findings were measured on.

### Comparison basis

**Both**, per cell, stated explicitly below: the committed CSVs
(`lab-results.csv`, `dc-results.csv`) are read for an inherited reference,
but the load-bearing comparison is a **re-taken control** — `da87807`'s
`cli/bigcurl` (`git show da87807:cli/bigcurl`, extracted to
`bigcurl-old`), rebuilt on today's provision and measured back-to-back
against the current tip (`bigcurl-new`) on the same hosts, same day. The
committed CSVs describe a previous provision (different fixture bytes,
different sha256, per `REPRODUCE.md`'s own note on fixture regeneration);
the old-vs-new control removes that confound entirely, at the cost of
double the host time. `curl` itself is not re-run per build on the two
expensive lossy cells (`rtt100/250ms loss0.5pct`) — its performance cannot
depend on which bigcurl binary happens to sit on disk, so one shared
`curl`-only reference (interleaved reps, same cell, same session) stands
in for both builds' noise floor there, saving the dominant cost of those
cells (curl alone ran 93–183s per rep at these settings in the original
grid). Every other tool/cell combination keeps `curl` in the same
interleaved run as the bigcurl builds it is compared against.

### Regression thresholds (fixed before measuring)

* **0% / 0.1% loss cells, and the droplet:** new build >20% slower than
  old build on median MB/s is flagged. The droplet's own measured noise
  floor (`ask2-droplet.csv`, curl alone, 9 reps) was 24% of its median —
  20% is already inside that noise band, so a flag here is a prompt to
  look closer, not an automatic verdict.
* **0.5% loss cells:** new build >40% slower is flagged. The committed
  `lab-results.csv` shows same-build, same-cell spreads approaching that
  over just 3 reps under loss (e.g. `bigcurl-8` at `rtt100ms/loss0.5pct`:
  8.539 / 7.401 / 6.465 MB/s — 27% spread with nothing else changing).
* **Any `ok=0` row (sha256 mismatch or timeout) is an automatic
  regression** regardless of throughput.
* The expected, hoped-for result is that nothing crosses these
  thresholds. A result inside them is not "inconclusive" — it is the
  finding this task exists to establish.

### Results

**Build identities**, verified by sha256 recomputed from git before every
single rep — never trusted from a filename on either host:

| tag | commit | sha256 (cli/bigcurl) |
|---|---|---|
| `old` | `da87807` (bigcurl as first written) | `7da926fad3acfcc4e4d7d56a837e4578b8e27cb8d675e08729524473255df5b2` |
| `tip` | `ae9f6f3` (the shipped build this sweep was asked to check) | `fc6bead602281bcaa0b3694bb5870c99fdd4e68ecefcd55de3653be081df1b9c` |
| `fixed` | `575115d` (probe-size's fix commit, including its own follow-up comment-only lab-evidence note) | `6690f3ec383fb0b8e66bcf33e6ed00eab0efd15d248a8153875b8231b4f0bd57` |

`fixed` is pinned to that one commit deliberately. The `bigcurl` branch
moved twice more while this sweep was running (the scope-guard merge, then
ASK 3's hedging landing on top of it) — re-staging `fixed` from a moving
tip partway through would have made the three arms internally
inconsistent, which matters more than tracking currency. `fixed`'s file
was re-derived from git (`git show bigcurl:cli/bigcurl` at the commit
above) and re-verified by hash after a stale copy was caught on Hetzner
(see the mid-run correction — a `probe-size` comment-only follow-up commit
had changed the file's hash without changing its behaviour, confirmed by
stripping comments from both sides and hashing again: identical). ASK 3's
hedging ships with `$HEDGE_TAIL_BLOCKS = 0` (off by default), so it is not
expected to affect anything measured here, but that is an expectation
about a build this sweep did not test, not a measurement.

**Mechanism.** `old` differs from `tip` in exactly six commits (diffed
directly, not inferred): probe-free start, a progress-snapshot fix,
rename-into-place, committed regression tests plus an empty-file fix, and
two `prepare_job()` fixes (open-guard, tmpdir collision). The connection
tuner's own growth-rate code is provably byte-identical between `old` and
`tip` (see "One thing fell out of reading the diff," above) — ASK 1's
tuner experiment fully reverted. What changed is real: `block_size()`
returns 256KB for a file this size, but the probe's `probe_request_size()`
falls back to the hardcoded 1 MiB `PROBE_RANGE` whenever `-B` isn't given,
so `tip`'s probe now fetches ~4x a real block's worth of bytes over one
serialized connection before the parallel pool starts. At high RTT, TCP
slow start alone costs roughly a fixed ~1.5s to deliver that first
megabyte — a cost the old HEAD-only probe never paid. That fixed cost is a
*large* fraction of a fast, clean-link transfer and a *small* fraction of
a slow, loss-dominated one, which is exactly the shape of the results
below: big relative effect on the clean 250ms cell, no measurable effect
on `bigcurl-8` under loss or on the CPU-bound droplet, and one real but
sub-threshold effect on `bigcurl-auto` under loss where the tuner adds its
own timing sensitivity on top.

**Clean high-RTT, `rtt250ms/loss0pct`** (comparison: re-taken control,
`old` vs `tip` only — `fixed` wasn't staged yet when this cell was run;
n=3, near-zero within-run noise, curl noise floor <6%):

| tool | old (MB/s) | tip (MB/s) | delta | threshold | verdict |
|---|---:|---:|---:|---:|---|
| curl (ref) | 6.76 | 6.76 | -0.1% | — | noise-floor check |
| bigcurl-8 | 4.14 | 3.47 | -16.3% | 20% | not flagged (real, below bar) |
| bigcurl-auto | 6.60 | 5.04 | -23.6% | 20% | **FLAGGED** |

This cell has almost no within-run spread (e.g. `bigcurl-8` old:
4.135/4.143/4.143), so both deltas are real effects, not noise, even
though only `bigcurl-auto` clears the pre-registered bar. This is the
regression `probe-size` built `fixed` for. It was not re-measured against
`fixed` — by the time `fixed` existed, host-time was redirected to the
loss cells per the discussion below, and this cell's own before/after
(`extra.log`'s 200-file numbers plus this table) was already enough to
justify the fix independent of the loss-cell question.

**Lossy netem, `rtt100ms/loss0.5pct` and `rtt250ms/loss0.5pct`, n=3,
three-way (`old`/`tip`/`fixed`)** — the cells that matter most, since this
is the regime bigcurl exists for:

| cell | tool | old | tip | delta | fixed | delta | verdict |
|---|---|---:|---:|---:|---:|---:|---|
| rtt100/0.5% (curl ref 0.33-0.44) | bigcurl-8 | 4.38 | 4.25 | -2.9% | 4.94 | +12.9% | ok, full overlap |
| rtt100/0.5% | bigcurl-auto | 8.80 | 7.81 | -11.2% | 10.06 | +14.4% | ok — tip's low rep (3.78) is a within-tip outlier, not a build effect |
| rtt250/0.5% (curl ref 0.19-0.25) | bigcurl-8 | 2.47 | 2.61 | +5.8% | 2.51 | +1.5% | ok, full overlap |
| rtt250/0.5% | bigcurl-auto | 5.37 | 3.53 | -34.2% | 4.51 | -15.9% | close, not flagged at n=3 — see below |

At n=3, `rtt250ms/loss0.5pct` / `bigcurl-auto` was the one ambiguous cell:
under the 40% bar, but with a large enough delta and a specific enough
mechanism (the same probe cost, now competing with loss-driven variance
instead of clean-link determinism) to be worth resolving rather than
leaving as "probably noise." This is also the cell where an n=3 read was
initially relayed upstream as "the regression does not reach the lossy
cells" — which the n=8 extension below overturned. Recorded here plainly
so a later reader does not have to reconstruct from commit order that
three reps were not enough on this cell and eight were.

**`rtt250ms/loss0.5pct` / `bigcurl-auto`, extended to n=8** (all three
arms, same `fixed`=`6690f3ec` throughout):

| build | n | median | range | stdev |
|---|---:|---:|---|---:|
| old | 8 | 4.10 MB/s | [2.76, 5.60] | 0.95 |
| tip | 8 | 2.88 MB/s | [2.12, 4.11] | 0.61 |
| fixed | 8 | 3.99 MB/s | [3.44, 5.16] | 0.56 |

Ranges still technically overlap pairwise at n=8 (that is expected under
loss-driven variance and is why medians/ranges alone were not enough at
n=3). The common-language effect size — P(a > b) over all cross-pairs,
using every point instead of just the extremes — resolves it:

* P(old > tip) = 0.86 — a real, large effect. A randomly picked `old` rep
  beats a randomly picked `tip` rep 86% of the time; that is not what
  overlapping noise looks like.
* P(old > fixed) = 0.56 — indistinguishable from chance (0.50 = no
  difference).
* P(fixed > tip) = 0.92 — the cleanest evidence in this sweep that the
  fix does what it claims, in this cell.

**Verdict on this cell, stated exactly: the regression is real here, at
roughly -30% median, established with high confidence at n=8 — and it
still does not cross the 40% threshold fixed before any measurement was
taken.** Both facts are kept, deliberately, rather than collapsing them
into one. The threshold was not moved after seeing the number in either
direction: a large, real effect that stays "unflagged" is a true
statement about where a pre-registered bar sits, not a discrepancy to be
smoothed over. `bigcurl-8` and `rtt100ms/loss0.5pct` were not extended to
n=8 — both showed full distribution overlap with no consistent direction
at n=3, which is a qualitatively different, lower-priority state than an
ambiguous-but-directional n=3 result, and chasing it further would have
been measuring what's easy rather than what's informative.

**Droplet, CPU-bound, `do-sfo>hz-ore/plain`, n=3+1 warmup, three-way:**

| tool | old | tip | delta | fixed | delta |
|---|---:|---:|---:|---:|---:|
| curl (ref) | 82.10 | 80.85 | -1.5% | 74.94 | -8.7% |
| bigcurl-8 | 56.74 | 59.53 | +4.9% | 57.91 | +2.1% |
| bigcurl-auto | 45.50 | 45.94 | +1.0% | 46.99 | +3.3% |

Every build's range overlaps every other's on every tool; no delta
approaches the 20% threshold. This is the predicted result: the probe
regression is a fixed serialized-latency cost, and this host's bottleneck
is CPU/per-byte, not round trips — there's little for an RTT-bound cost to
bite on here.

### Bottom line

The six commits between `da87807` and the shipped `tip` (`ae9f6f3`)
introduced one real regression — a fixed ~1.5s serialized probe cost that
shows clearly on a clean high-RTT link (`bigcurl-auto` -23.6%, **flagged**)
and, at n=8, reaches into the lossy regime on `bigcurl-auto` as well
(~-30% at `rtt250ms/loss0.5pct`, real but **not flagged** against the
pre-registered 40% bar). It does not show on `bigcurl-8` at any RTT or
loss level tested, and does not show on the CPU-bound droplet at all.
`probe-size`'s fix (commit `575115d`, hash `6690f3ec…`) resolves the clean
high-RTT case by construction (request one congestion window for a lone
URL, keep the 1MB batch behaviour for many) and, in the one lossy cell
measured at n=8, restores performance statistically indistinguishable
from `old` (P(old > fixed) = 0.56). The core product claim — bigcurl's
large advantage over plain curl under loss — is intact throughout: even
`tip`'s slowest lossy numbers stay one to two orders of magnitude above
curl's noise-floor-matched reference in every cell measured.

### What this did NOT measure

* The full RTT × loss grid (only 4 of 12 cells re-run) — the other 8 were
  judged lower-risk (light/no loss at low RTT, where neither the probe
  change nor the tuner has much to bite on) and not worth the host time.
* Starlink (`starlink-results.csv`) — real-Starlink time was not
  available in this run; the netem lab is the closest controlled proxy
  this task could afford, and is named as such, not substituted silently.
* `steady-results.csv` / `overhead-results.csv` (1 GB clean-path and
  loopback) — loopback in particular is dominated by fork/exec cost, not
  the byte path, and was judged unlikely to move from these changes.
* The `rate4m` / `rate4m+cap8` droplet scenarios from `dc-results.csv` —
  only the CPU-bound `plain` scenario was re-run; the rate-capped
  scenarios are link-limited, not CPU-limited, so they are less likely to
  show a `prepare_job()`/probe-cost regression and were deprioritized
  under the same host-time budget.
* The 200-file / many-small-files case — already directly measured by the
  ASK 5 work itself (`extra.log`) on both the before and after builds; not
  re-measured here.

## Final measurement pass (build `8066b6a`)

Every figure in the report's five core suites was remeasured end to end
against one build and one build only: `cli/bigcurl` at commit `8066b6a`,
sha256 `a4d34295405f0fd95590ece896ef3396c20dd4ba08aeb65753c02a1a0fbacf1b`,
73/73 tests passing. The build was identified on each host **by hash against
git**, never by filename — `/root/bigcurl-*` was used inconsistently by
several earlier workers and the names cannot be trusted.

Suites run, one at a time, under an exclusive host lease:

| suite | host | rows | verified |
|---|---|---|---|
| `grid.sh` (netem, 12 cells x 6 tools x 3 reps) | Hetzner | 216 | 216/216 |
| `steady.sh` (1 GB, clean, 100/250 ms) | Hetzner | 16 | 16/16 |
| `overhead.sh` (loopback, 1 GB) | Hetzner | 15 | 15/15 |
| `extra.sh` (behaviours + 200 files) | Hetzner | 6 checks | 6/6 pass |
| `dc.sh` (droplet -> Hetzner, 1 GB) | droplet | 36 | see below |
| `starlink.sh` (desktop -> both origins) | desktop | see below | |

### Two method faults found and fixed before measuring

**Every hardcoded fixture digest in the suite scripts was stale.** `grid.sh`
carried `7db7af5b` for `lab-32m.bin` where the origin serves `f6bd35ad`;
`dc.sh`, `steady.sh` and `overhead.sh` carried `d0a9a598` for `big-1g.bin`
where the origin serves `cb87776a`. Run as they stood, every suite would
have recorded `ok=0` for every run. The digests are now **recomputed on the
origin at run time** (`grid.sh`, `steady.sh`, `overhead.sh`) or required
from the environment with no default (`dc.sh`, `starlink.sh`, which run on a
different machine from the origin they pull from). Do not reintroduce a
literal here.

**`lab.sh set` now reads the qdisc back** on both veth ends and aborts if the
applied delay or loss is not what was asked for, so a suite cannot silently
inherit a previous worker's netem configuration and label its numbers with
conditions that were never applied. The check was proven in both directions
before being trusted: it passes on a correctly applied cell and aborts when
the qdisc is clobbered to `delay 999ms`.

### Starlink fixtures had to be regenerated

`starlink.sh` names `big-96m.bin` and `big-48m.bin`. Neither existed on
either origin — `setup-server.sh` does not create them, so they were ad-hoc
fixtures from an earlier pass that did not survive re-provisioning. They were
regenerated at the same sizes with the same method `setup-server.sh` uses
(`head -c <n> /dev/urandom`). **The bytes therefore differ from the ones the
committed `starlink-results.csv` was measured against**; the sizes, and so
the throughput comparison, are unchanged, and every run is verified against a
digest computed on the origin after regeneration.

`starlink.sh` also pointed at a `bench.pl` inside a previous session's
scratch directory and at the shared working copy's `bigcurl`. Both now
resolve from the script's own checkout.

### The Starlink link was degraded on the night of this pass

Read the Starlink table's ratios, not its absolute numbers. Single-stream
curl measured **31-52% of what the same suite measured on the earlier pass**
on the same three paths (3.60 -> 1.23, 4.35 -> 2.25, 3.38 -> 1.03 MB/s), and
every other tool fell with it. That is weather and contention on a real,
shared consumer link, not a change in any downloader — and it is why the
netem lab exists alongside the Starlink table rather than instead of it.

bigcurl fell least (-7% to -45%) and curl most (-48% to -69%), which is the
direction the whole thesis predicts: the more degraded the link, the more a
single stream loses relative to several. But at n=2 per cell on a link this
variable, treat small differences between the parallel tools as unresolved.
On this pass bigcurl led aria2c by 8-29% across the three paths where the
earlier, healthier pass had them level; that difference is not separated by
this sample size and should not be quoted as a win.

### Headline figures are computed, not typed

The report's verdict tiles and summary prose used to carry their numbers as
literals in `report.tmpl.html`. They went stale the moment the suites were
rerun — the published headline read "29x curl" from a cell where curl's own
three repetitions span 36x. Every headline figure is now computed in
`compile-data.py` (`out['head']`) and rendered through a `{{hl_*}}`
placeholder, so a remeasurement moves the headline with the data instead of
silently contradicting the table below it. The build asserts zero unreplaced
`{{...}}` remain.

### curl's throughput under netem loss is bimodal — read "N x curl" with care

The single most important caveat on the netem table. In the lossy,
high-latency cells curl does not have a throughput so much as two of them:
at `rtt100ms/loss0.5pct` its three repetitions measured **0.32, 1.10 and
11.62 MB/s — a 36x spread within one cell**, and at `rtt100ms/loss0.1pct`
3.74/9.75/13.12, a 3.5x spread. A single TCP connection under netem's
per-connection loss model either gets through slow start or collapses into
repeated timeouts, and which one happens is a coin flip.

With n=3 the median is then simply whichever rep landed in the middle, and
it is not a stable estimator. This is why the previously published headline
of "29x curl at 100 ms / 0.5% loss" does not reproduce: the same cell on the
same build measures **8.2x** this pass, and neither number is trustworthy.
Every other tool in those cells (aria2c, axel, bigcurl) has a rep spread
under 2.6x, so comparisons *among the multi-connection tools* are sound; it
is specifically the ratio against single-stream curl that is unstable.

Cells where curl's own reps span more than 3x are flagged in the analysis
and should not be used for a headline figure. `rtt250ms/loss0.5pct` is the
cell to quote instead: curl measures 0.23 MB/s with a 1.2x rep spread and
bigcurl 3.42 MB/s with a 1.5x spread, so the 15x there is a comparison of
two stable numbers.

### What this pass did NOT measure

* **ASK 1 and ASK 3 have no CSV in this tree.** The `--next` throughput
  comparison (63.9/54.5 vs 64.5/55.4 MB/s) and every hedging figure
  (+32%/+23%/+43% under netem, -31% on Starlink) are carried from the passes
  that produced them and are marked `(inherited)` in the report. Only ASK 3's
  shipped default was re-read from the build.
* **ASK 2 and ASK 4 were not re-run.** `ask2-*.csv` and `h2-vs-h1-*.csv` are
  the earlier passes' measurements; this pass recomputed the published
  figures from those CSVs but did not put the hosts under those suites again.
* **No regression sweep, no regime sweep.** `regression-*.csv` and
  `regime-*.csv` are unchanged from the passes that produced them.
* **The two stuck `while pgrep` processes on Hetzner were left alone.** They
  predate this run, wait on scripts that no longer exist, and are excluded
  from any process count — a naive `ps | grep` reads the host as busy when
  it is idle.

## Scripts

| file | what it does |
|---|---|
| `setup-server.sh` | provision an origin (nginx + fixtures + tools) |
| `lab.sh` | netns + netem controlled network |
| `grid.sh` | RTT × loss sweep in the lab |
| `bench.pl` | the measurement harness |
| `starlink.sh` | desktop → both origins, over real Starlink |
| `dc.sh` | droplet → hetzner, datacentre to datacentre |
| `steady.sh` | clean high-RTT path with a 1 GB file (isolates slow start) |
| `overhead.sh` | loopback, no network limit — pure orchestration cost |
| `extra.sh` | server behaviours, chaos-resume, many-small-files |
| `analyze.py` | median tables and speedup vs curl |
| `h2-vs-h1.sh` | ASK 4: curl H1 (N connections) vs curl H2 (N multiplexed streams), RTT x loss grid, env-overridable for the steady-state addendum |
| `byteproxy.sh` | ASK 2: fetch a URL as N ranged curl processes with zero perl in the byte path (`curlo` / `curldd` modes) — the ceiling instrument `bigcurl -n N` is compared against at matched N |
| `regime-probe.pl` | regime signal: per-connection rate spread, straggler ratio and parallel speedup, using plain curl only |
| `trace-signal.pl` | regime signal: retries/MB, stall fraction, throughput CV, pool trajectory and tail fraction, from bigcurl's `-l` trace |
| `regime-lab.sh` | regime signal: the three netem cells on Hetzner, with `tc` read back on both veth ends |
| `regime-client.sh` | regime signal: the same instruments from the droplet and from Starlink |
| `regime-synthorigin.py` | regime signal: local origin with three known impairment models, for validating the probe |
| `regime-verdict.py` | regime signal: separation margins and pre-registered threshold checks over the result CSVs |
| `regression-lab.sh` | regression sweep: one netem cell, one bigcurl build, appended to `regression-lab.csv` — see "Regression sweep" above |
| `regression-dc.sh` | regression sweep: the droplet's plain origin, one bigcurl build, appended to `regression-dc.csv` |
| `regression-analyze.py` | regression sweep: N-build comparison (any number of tags) anchored on an "old" baseline, thresholds fixed before measuring; imports `analyze.py`'s `aggregate()` rather than duplicating it |
