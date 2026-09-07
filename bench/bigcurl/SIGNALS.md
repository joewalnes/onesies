# Candidate regime signals — written down BEFORE measuring

Question the decision needs: is there a value bigcurl can observe at runtime that
separates **{lossy}** from **{clean high-RTT, CPU-bound origin, bandwidth-contended}**
by a margin larger than run-to-run noise?

If yes, two currently-disabled capabilities become safe to auto-enable:
the fast connection-pool growth rate, and `$HEDGE_TAIL_BLOCKS` (ASK 3).

## What is actually observable today (read from `cli/bigcurl`, no new instrumentation)

The `-l` JSON trace is the only machine-readable output. Its events are:

| event | fields |
|---|---|
| `start` | file, url, size, blocks, block_size, resume, ranges |
| `progress` (every `$LOG_INTERVAL`) | file, done, size, pct, **speed** (EMA), **conns** (live workers), eta |
| `retry` | file, block, attempt, **reason**, backoff |
| `error` | file, message, http |
| `done` | file, bytes, seconds, speed |
| `summary` | files, ok, failed, skipped, bytes, seconds, speed, exit |

NOT observable in the trace (internal state only): `$req_rate` (per-request
bytes/s, computed in `settle_worker` and immediately overwritten), `$conns_limit`,
`$throttle_ceiling`, `$tune_best`, `$tune_errors`/`$tune_reqs`, per-worker TTFB.
`progress.conns` is the count of *live workers*, a lagging proxy for `$conns_limit`.

## Candidate signals

Derived from the trace (observable today):

* **S1 retry rate** — `retry` events per MB transferred.
* **S2 retry reason mix** — fraction of retries whose `reason` is `connection stalled`
  vs `short transfer` vs an HTTP/curl failure. Stalls are the `$STALL_SECS` path.
* **S3 aggregate throughput CV** — stddev/mean of `progress.speed` across a run.
* **S4 pool trajectory** — mean / max / final `progress.conns`, and the number of
  times it decreases. This is the observable shadow of the tuner's own
  experiment: it grows the pool and keeps the growth only if aggregate speed rose.
* **S5 tail ratio** — (t_done - t_90%) / t_done, i.e. `tailmetric.pl`'s quantity
  normalised. This is the quantity hedging is meant to shrink.

Not observable today, measured with an independent instrument to establish
whether the physical signal exists at all (and therefore whether instrumenting
bigcurl to expose it would pay):

* **S6 per-connection speed spread** — CV of per-connection transfer rate across
  N simultaneous range requests to the same origin.
* **S7 straggler ratio** — max/median of per-connection transfer duration for
  equal-sized concurrent ranges. The direct measure of "does one connection get
  stuck while its siblings finish".
* **S8 parallel speedup** — aggregate(N conns) / aggregate(1 conn).

## The hypothesis under test (previous worker's, not assumed)

netem loss is a *per-connection* impairment: each TCP flow drops independently,
so S6/S7 are large and S8 is large (adding flows adds aggregate). A shared
bandwidth bottleneck (Starlink) or a CPU-bound origin splits one pipe N ways:
S6/S7 small (fair share), S8 near 1. If true, S7/S8 separate the regimes and S1
alone does not — because Starlink's loss is **not** zero and would trip a naive
retry-rate threshold.

## Instrument names (stated per the rules of evidence)

* `rtt250/0%`, `rtt100/0.5%`, `rtt250/0.5%` are **netem** cells in a Linux
  network namespace on the Hetzner box (`lab.sh`), server and client on the same
  machine. netem loss is a *model* of a lossy link, not a real one.
* CPU-bound = the 1-core DigitalOcean droplet's nginx reached over the tailnet.
* Bandwidth-contended = real Starlink from the mac desktop. Uncontrolled.

---

# Instrument validation on synthetic controls (measured, before any host time)

CLAUDE.md's ASK 3 lesson is "verify the measurement instrument before trusting
a null result" — a previous worker reported 0 duplicates from a binary it had
forgotten to instrument. So `regime-probe.pl` was first pointed at
`regime-synthorigin.py`, a local origin with three *selectable, known*
impairment models, to check it can tell them apart at all. 127.0.0.1, 8
connections, 4 reps each. This is a **model**, not a link.

| control | impairment | spread_cv | straggler | speedup |
|---|---|---|---|---|
| A `ctlA-perconn-cap` | per-connection rate cap: independent pipes, deterministic | 0.001 | 1.00 | 7.98 |
| B `ctlB-shared-cap`  | one global rate cap split 8 ways: shared bottleneck | 0.033 | 1.03 | **1.05** |
| C `ctlC-stochastic`  | random per-connection pauses: stochastic per-connection impairment | **0.608** | **2.37** | 7.63 |

Raw rows in `regime-controls.csv`.

**The instrument works, and it resolves two orthogonal axes, not one.**

* `straggler` / `spread_cv` separate C from A and B — 2.37 vs 1.00/1.03, a
  factor of 2.3 on straggler and 18-600x on spread_cv. This is *stochastic*
  per-connection impairment: some connections get unlucky and lag.
* `speedup` separates B from A and C — 1.05 vs 7.98/7.63. This is a *shared*
  bottleneck: more connections buy nothing.

A and C are both perfectly parallel (speedup ~8) and differ only in variance;
B is the only one where parallelism does not pay. So "helps a lossy link" and
"hurts a contended one" are **not** two ends of one axis, and no single scalar
should be expected to order all four regimes.

This matters for the two product questions, which turn out to need *different*
signals:

* **Hedging** pays when one connection is unluckily slow while its siblings are
  fine — that is variance, so its discriminator is `straggler`/`spread_cv`.
  Note control A: a link can be perfectly parallel with *zero* straggling, and
  hedging would buy nothing there. Retry rate cannot see this distinction.
* **Fast pool growth** pays when adding connections adds aggregate — that is
  `speedup`. bigcurl's tuner already runs this experiment in-band (it grows the
  pool and keeps the growth only if throughput rose), so its observable shadow
  is the S4 pool trajectory.

# Predictions, written down before the host runs

| regime | predicted straggler | predicted speedup | looks like |
|---|---|---|---|
| netem rtt250/0% (clean high-RTT) | low | high | control A |
| netem rtt100/0.5%, rtt250/0.5% (lossy) | **high** | high | control C |
| 1-core droplet client (CPU-bound) | low | low | control B |
| Starlink desktop (bandwidth-contended) | low | low | control B |

Candidate thresholds, pre-registered so they cannot be loosened afterwards:
**hedge iff `straggler` > 1.5**; **grow fast iff `speedup` > 2.0**. Both must
clear the measured 24% run-to-run noise floor (REPRODUCE.md, ASK 2) by a
margin, or the answer is "no threshold exists".

If Starlink comes back with a *high* straggler, the hedging question has no
observable answer and `$HEDGE_TAIL_BLOCKS` must stay manual. That is the
outcome the trap in this task is pointing at, and it is a first-class result.

---

# Results (measured)

Five cells, n=5 reps each. `clean-rtt250-loss0` and `lossy-rtt100-loss0.5` were
measured **twice**, as independent passes, to reproduce before concluding.
Build under test: `cli/bigcurl` from `6db817c` (contains ASK 3; hedging off by
default, `$HEDGE_TAIL_BLOCKS = 0`), sha256
`a4d34295405f0fd95590ece896ef3396c20dd4ba08aeb65753c02a1a0fbacf1b`, verified
identical on both hosts. `regime-probe.pl` shells out to plain `curl` only,
never to bigcurl. Netem `tc` state was read back on both veth ends before and
after every cell and matched what was set.

## Observable from the `-l` trace today

| cell | S1 retry/MB | S2 stall_frac | S3 speed_cv [lo..hi] | S4 conns_mean | S5 tail_frac [lo..hi] | MB/s |
|---|---|---|---|---|---|---|
| clean-rtt250-loss0 (p1) | **0.000** | 0.000 | 0.324 [0.277..0.329] | 21.0 | 0.217 [0.205..0.232] | 12.73 |
| clean-rtt250-loss0 (p2) | **0.000** | 0.000 | 0.320 [0.280..0.330] | 21.2 | 0.217 [0.216..0.232] | 12.73 |
| lossy-rtt100-loss0.5 (p1) | **0.000** | 0.000 | 0.543 [0.422..0.622] | 18.4 | 0.449 [0.319..0.499] | 11.16 |
| lossy-rtt100-loss0.5 (p2) | **0.000** | 0.000 | 0.444 [0.371..0.540] | 20.9 | 0.368 [0.306..0.401] | 12.97 |
| lossy-rtt250-loss0.5 | **0.000** | 0.000 | 0.675 [0.621..0.855] | 19.7 | 0.426 [0.393..0.527] | 6.30 |
| cpubound-droplet | **0.000** | 0.000 | 0.098 [0.084..0.209] | 15.6 | 0.096 [0.071..0.148] | 45.91 |
| starlink-desktop | **0.000** | 0.000 | 0.107 [0.081..0.223] | 28.4 | 0.114 [0.104..0.191] | 6.51 |

## Measured with plain curl (not observable today)

| cell | spread_cv | S7 straggler | S8 speedup | agg MB/s [min..max] |
|---|---|---|---|---|
| clean-rtt250-loss0 (p1) | 0.442 | 1.161 | 4.33 | 15.54 [15.17..15.97] |
| clean-rtt250-loss0 (p2) | 0.442 | **1.538** | 4.33 | 15.52 [15.20..15.60] |
| lossy-rtt100-loss0.5 (p1) | 0.545 | 2.870 | 3.74 | 10.74 [9.56..13.06] |
| lossy-rtt100-loss0.5 (p2) | 0.543 | 2.403 | 5.20 | 11.86 [9.79..12.07] |
| lossy-rtt250-loss0.5 | 0.272 | 1.756 | 5.88 | 4.06 [3.85..4.64] |
| cpubound-droplet | 0.300 | 1.259 | **1.25** | 106.07 [95.76..117.04] |
| starlink-desktop | 0.183 | 1.249 | **4.99** | 6.72 [3.88..7.91] |

Margins are computed by `regime-verdict.py` as strict non-overlap: the lowest
rep any lossy cell produced against the highest rep any non-lossy cell
produced, across both passes.

# Verdict

## 1. Retry rate — the obvious candidate — is dead, definitively

`retry_per_mb` and `stall_frac` are **identically 0.000 in all seven runs**,
including both 0.5%-loss cells. Packet loss is recovered by TCP inside the
connection; bigcurl's `retry` events fire on connection failures, stalls and
HTTP errors, none of which netem loss produces. There is nothing to threshold:
the signal does not vary at all. Any rule built on retry rate would have been
reading a constant. (This also means the trap in the brief never fires as
described — retry rate does not misfire on Starlink, it fires nowhere.)

## 2. There IS one observable separator: S5 tail_frac (+31%, replicated)

    highest non-lossy rep  0.2324  (clean-rtt250-loss0)
    lowest  lossy    rep   0.3055  (lossy-rtt100-loss0.5, pass 2)
    gap +31%, no overlap in any of 35 reps across both passes

`tail_frac` also ranks correctly against **every** case where the hedging
outcome is already known: it is high on rtt100/0.5% (hedging +23%) and
rtt250/0.5% (+32%), and low on Starlink (−31%), the droplet, and clean
high-RTT where hedging is not needed. A threshold near **0.27** sits in the gap.

**But this threshold is post-hoc.** S5 was pre-registered as a *candidate*;
its numeric value was not. It needs an independent confirmation pass before
anyone ships a rule on it.

**And it is a lagging measure.** `tail_frac` is only known once the tail has
happened, so it cannot gate a decision taken during the same transfer. Using
it would mean carrying it across files, or reading an early-transfer proxy —
neither of which I measured.

## 3. S8 speedup resolves the tuner question, with a 3x margin

    cpubound-droplet      1.25   -> grow slow
    every other cell      3.74 .. 5.88  -> grow fast

The pre-registered threshold of 2.0 sits in a 3x gap, far outside the 24%
noise floor, and the clean cell replicated to within 0.1% (4.3332 / 4.3279).
This cleanly identifies the one host where slowing pool growth measured +25%,
and separates it from the two lossy cells where slowing it regressed 19.5% and
28%. **This is the answer to the tuner question**, and it is the same
experiment the tuner already runs in-band — it grows the pool and keeps the
growth only if aggregate rose. Exposing `$conns_limit` / `$tune_best` history
in the trace would make it observable; today it is not.

## 4. The hedging discriminator FAILED replication — I am not moving the threshold

On pass 1, `straggler` looked like a clean answer: non-lossy topped out at
1.259 and lossy started at 1.756, a 39% gap around the pre-registered 1.5.
**On pass 2 the clean high-RTT cell read 1.5376 and crossed the threshold.**

    clean-rtt250-loss0  p1 1.1608   p2 1.5376   <- same cell, same settings
    lossy-rtt250-loss0.5   1.7563

That leaves 14% between the highest non-hedge cell and the lowest hedge cell,
inside the 24% noise floor. The cause is visible in the clean cell's per-rep
values: eight flows in slow start racing for one 200mbit netem limiter produce
stragglers with no loss involved at all. Reported as **ambiguous**. The
threshold stays at 1.5; loosening it to 1.6 would "fix" this table and would be
a threshold chosen after seeing the number.

What would settle it: more reps per cell (n=20+) to establish whether the clean
cell's straggler distribution genuinely straddles 1.5 or pass 2 was unlucky,
and a cell at rtt250 with a rate limit high enough that slow start is not
contended, which would tell us whether the clean-cell stragglers are an artifact
of the 200mbit cap in the lab rather than a property of clean high-RTT links.

## 5. Starlink is NOT a shared bottleneck — the standing hypothesis is refuted

The hypothesis under test was that netem loss creates per-connection stragglers
while Starlink's bottleneck is shared bandwidth. **Measured, it is not.**
Starlink's parallel speedup is **4.99** — eight connections get five times the
aggregate of one, which is control-A/C behaviour, not control-B's 1.05. The
1-core droplet is the only regime in this set that behaves like a shared
bottleneck (speedup 1.25).

What actually distinguishes Starlink is *where its variance lives*:

* **within a rep, across connections**: spread_cv 0.183, straggler 1.249 — its
  eight connections are uniformly slow, closely matched to each other.
* **between reps, over time**: aggregate 3.88 .. 7.91 MB/s, a ±41% swing, the
  widest of any cell measured and wider than the 24% noise floor.

So Starlink's impairment is **common-mode**: the whole link speeds up and slows
down together. That is a better explanation of ASK 3's −31% than "a duplicate
competes for the same pipe": a hedge duplicate can only recover *per-connection*
bad luck, and on Starlink there is almost none to recover — the duplicate pays
full setup cost against a sibling that was never unluckier than average.

This reframes the hedging rule. The question is not "is this link lossy" but
"is this link's variance per-connection or common-mode", and those need
different measurements — one across connections at an instant, one across time.

# What I did not measure

* **The connection-capped origin** (port 8082), where hedging measured +43%.
  Only the two netem loss cells and Starlink were covered for hedging ground
  truth. A cap is a shared-resource regime and might well behave like the
  droplet on speedup while still rewarding hedging — that would break the
  S7/S8 story and it is the most valuable single gap here.
* **The tuner's growth rate on Starlink and on the clean cell.** Ground truth
  for the tuner exists only for the droplet and the two lossy cells.
* **Any early-transfer proxy for `tail_frac`.** I measured the tail itself,
  which is lagging; whether the first 10% predicts the last 10% is untested.
* **n > 5 per cell.** Every median here rests on five reps, which is why the
  straggler result could flip between passes. The two signals I am willing to
  stand behind (tail_frac at +31%, speedup at 3x) have margins large enough
  that n=5 is adequate; straggler at 14% plainly is not.
* **Hedging or fast growth actually switched on under a signal-derived rule.**
  This pass measures signals, not outcomes; nobody has yet run bigcurl with an
  automatic rule and confirmed it reproduces the hand-set results.
* **Real packet loss.** Every "lossy" number here is **netem**, a model, with
  client and server on one machine. Starlink is the only uncontrolled real link
  measured, and its loss was never characterised independently.
