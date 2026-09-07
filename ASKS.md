# ASKS — the human's own requests, in priority order

Rank by origin, not volume. One agent is always on the top open item.

## Open

*None.* All five items are resolved — three closed by measurement, two landed.
The open product questions are at the bottom.

## Done

**3. Hedged tail requests — LANDED, OFF BY DEFAULT (`c4d58b1`).**
The mechanism works and the correctness work was the real yield. Measured, tail
= 90%-to-done from the `-l` trace, `-n` fixed in both arms of every cell:
*helps under loss* — rtt250/0.5% **+32%**, rtt100/0.5% **+23%**, and a
connection-capped origin **+43%**, all with complete rank separation at n=3;
*costs on Starlink* — **−31%** (median 4.01s vs 3.06s), the link this ask names
as its own measurement, direction consistent across every rep at n=6-7 though
spreads overlap.
Shipped with `$HEDGE_TAIL_BLOCKS = 0`; `--hedge N` turns it on. **Foreman
decision, reversible in one line**: on-by-default would regress this ask's own
success criterion for anyone on a bandwidth-contended link. Both regimes are
recorded at the knob.
*Found and fixed on the way*: hedging streamed both peers into the same offsets,
and against an origin serving changed bytes produced a file **torn mid-block** —
bytes from two responses inside one span, matching no response the origin ever
sent, with a correct byte count and a complete bitmap. Reproduced against the
pre-fix binary (2 of 4 blocks torn), fixed by buffering the duplicate and
committing only the winner.

**5. Probe-free start — DONE, target exceeded.** The probe is now a real
ranged GET whose body becomes block 0, and a file the probe delivers complete
is renamed into place rather than read back and rewritten. 200-file case:
0.371s → 0.276s (`10f6ccb`), then → 0.126s (`419a851`). The bar in the ask was
the shell loop's 0.20s. Both figures re-measured by the foreman from raw rows;
the second reproduced independently with the exact committed build. Also fixed
a pre-existing bug where every zero-length file failed outright.

**1. Wrap `curl --parallel` — REJECTED on measurement (`c2c1623`).**
As specified it ships silently corrupt downloads: curl's `--range` is a
*global* option, not per-transfer, so with one `--range`/`-o` pair per piece
the last range applies to every transfer. 16 pieces produced 16 files, each
exactly 1MB, correct total size, every one containing the same block — length
checks pass, bytes are wrong. Confirmed with and without `-Z`, via a `-K`
config file, and independently on macOS curl 8.7.1, so it is a property of
curl on both platforms. `--next` between transfers is byte-correct but a wash
at matched connection count (63.9/54.5 vs 64.5/55.4) while costing the block
bitmap, byte-exact progress, and an extra 1GB read+write. bigcurl itself was
never exposed: `run_probe_batch` already uses `--next` and the worker path
issues one range per curl process.
*The droplet gap this ask targeted is a tuner overshoot, not architecture* —
see the open question below.

**4. HTTP/2 multiplexing — REJECTED on measurement (`e7ea9d2`).**
Built the h2c origin the ask asked for (port 8085, cleartext so the
comparison is not confounded by a TLS handshake) and tested the premise before
building anything in bigcurl. Steady-state 1GB clean link: H2 ties H1 at
100ms RTT and is 1.8x *slower* at 250ms. Under loss it is 3-5x worse and fails
to complete at all at 250ms/0.5%. On the shorter 32MB grid H2 does win at
100ms (1.14x at 0% loss, 1.40x at 0.1%) but the win does not survive to steady
state — a slow-start artefact of the short transfer.

**2. Take perl out of the byte path — DO NOT BUILD as specified (`1494dae`).**
The ask's justification (71 dd vs 45 perl vs 77 curl) does not reproduce. curl's
77 and dd's 71 do; the 45 does not, at any matched connection count — bigcurl
measured 57-59 MB/s everywhere tested. The 45 looks like a tuner artefact
(auto was picking a pool around 16-20 where the optimum is 2-4).
At matched N, `curl -o` per piece is a wash or worse — that candidate is dead
outright. `curl | dd` costs perl +11.2%/+19.2%/+37.9% CPU at N=1/2/4, cleanly
separated from noise only at N=4, and it fails this ask's own HARD
REQUIREMENT: dd's byte-offset seek needs GNU-only `oflag=seek_bytes` for
unaligned offsets, so it does not work on macOS.
*The CPU data points at shrinking perl's read/write loop rather than removing
it — smaller, fully portable, and not yet scoped.*

## Open question for the human

**The connection tuner's growth rate is one knob serving two opposed goals.**
Slowing it measured **+25% on the one-core droplet** (41.9 → 52.5 MB/s) and
**regressed the lossy netem cells 19.5% and 28%** (rtt100/loss0.5 8.00 → 6.44;
rtt250/loss0.5 3.32 → 2.39), with the ranges barely overlapping at the worst
cell. Under loss, reaching a large pool quickly is how bigcurl beats plain curl
by ~25x — the thing it exists for. The change was reverted rather than split.
An untested third path: use retry rate to tell the CPU-bound regime from the
lossy one, and grow slowly only in the former.

**The same shape, twice, from independent directions.** The tuner question and
ASK 3 both end in: this helps lossy links and hurts clean ones, and there is no
runtime signal to tell the regimes apart. A retry-rate regime test would settle
both. It is untested and unscoped.
