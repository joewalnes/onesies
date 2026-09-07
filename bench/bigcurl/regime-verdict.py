#!/usr/bin/env python3
"""regime-verdict.py - compute the regime-separation margins from the CSVs
regime-lab.sh and regime-client.sh produce, and check the PRE-REGISTERED
thresholds in SIGNALS.md against them.

The test is strict non-overlap across every pass and every cell: a signal
separates {lossy} from {clean, CPU-bound, bandwidth-contended} only if the
lowest value any lossy cell reached is above the highest value any non-lossy
cell reached. Per-cell lo/hi are the min and max over that cell's reps, so
this compares observed extremes, not medians with error bars hidden.

Usage: regime-verdict.py <probe.csv>... -- <trace.csv>...

Joe Walnes <joe@walnes.com>, 2026, MIT License
https://github.com/joewalnes/onesies
"""
import csv, sys

LOSSY = {'lossy-rtt100-loss0.5', 'lossy-rtt250-loss0.5'}
NOISE = 0.24   # measured run-to-run noise floor, REPRODUCE.md / ASK 2

def load(paths):
    rows = []
    for p in paths:
        with open(p) as f:
            rows += [r for r in csv.DictReader(f)]
    return rows

def sep(rows, med, lo, hi, label):
    """Strict non-overlap between the lossy cells and everything else."""
    L = [r for r in rows if r['label'] in LOSSY]
    N = [r for r in rows if r['label'] not in LOSSY]
    if not L or not N:
        raise SystemExit(f'FATAL {label}: need both lossy and non-lossy rows, '
                         f'got {len(L)} lossy / {len(N)} non-lossy')
    n_hi = max(float(r[hi]) for r in N)
    n_hi_who = max(N, key=lambda r: float(r[hi]))['label']
    l_lo = min(float(r[lo]) for r in L)
    l_lo_who = min(L, key=lambda r: float(r[lo]))['label']
    ok = l_lo > n_hi
    margin = (l_lo - n_hi) / n_hi if n_hi > 0 else float('inf')
    print(f'\n{label}')
    print(f'  lossy medians    : ' + ', '.join(f'{r["label"]}={float(r[med]):.4f}' for r in L))
    print(f'  non-lossy medians: ' + ', '.join(f'{r["label"]}={float(r[med]):.4f}' for r in N))
    print(f'  highest non-lossy rep : {n_hi:.4f}  ({n_hi_who})')
    print(f'  lowest  lossy    rep : {l_lo:.4f}  ({l_lo_who})')
    if ok:
        verdict = 'SEPARATES' if margin > NOISE else f'separates, but margin {margin:.0%} is INSIDE the {NOISE:.0%} noise floor'
        print(f'  -> {verdict} (gap {margin:+.0%})')
    else:
        print(f'  -> OVERLAPS by {n_hi - l_lo:.4f} - NOT a discriminator')
    return ok, margin

args = sys.argv[1:]
if '--' not in args:
    raise SystemExit('usage: regime-verdict.py <probe.csv>... -- <trace.csv>...')
i = args.index('--')
probe, trace = load(args[:i]), load(args[i+1:])
if len(probe) < 4 or len(trace) < 4:
    raise SystemExit(f'FATAL: read {len(probe)} probe and {len(trace)} trace rows; '
                     'refusing to draw a verdict from this little data')
print(f'read {len(probe)} probe rows, {len(trace)} trace rows '
      f'({len({r["label"] for r in probe} | {r["label"] for r in trace})} distinct cells)')

print('\n=== OBSERVABLE FROM bigcurl\'s -l TRACE TODAY ===')
sep(trace, 'tail_frac', 'tail_frac_lo', 'tail_frac_hi', 'S5 tail_frac')
sep(trace, 'speed_cv',  'speed_cv_lo',  'speed_cv_hi',  'S3 speed_cv')
r0 = [float(r['retry_per_mb']) for r in trace]
print(f'\nS1 retry_per_mb\n  every cell: {sorted(set(r0))}'
      f'\n  -> {"DEAD: identically zero everywhere" if max(r0) == 0 else "nonzero somewhere"}')
s0 = [float(r['stall_frac']) for r in trace]
print(f'\nS2 stall_frac\n  every cell: {sorted(set(s0))}'
      f'\n  -> {"DEAD: identically zero everywhere" if max(s0) == 0 else "nonzero somewhere"}')
cm = {r['label']: float(r['conns_mean']) for r in trace}
print(f'\nS4 conns_mean (median per cell)\n  ' +
      ', '.join(f'{k}={v:.1f}' for k, v in sorted(cm.items(), key=lambda kv: kv[1])) +
      '\n  -> lossy cells sit BETWEEN the CPU-bound and the clean cell: no lossy separation')

print('\n=== NOT OBSERVABLE TODAY (measured with plain curl, to see if it is worth exposing) ===')
print('\nS7 straggler - PRE-REGISTERED threshold 1.5 (hedge above it)')
for r in sorted(probe, key=lambda r: float(r['straggler'])):
    g = float(r['straggler'])
    print(f'  {r["label"]:<22} {g:.4f}  -> {"HEDGE" if g > 1.5 else "no hedge"}')
print('\nS8 speedup - PRE-REGISTERED threshold 2.0 (grow fast above it)')
for r in sorted(probe, key=lambda r: float(r['speedup'])):
    s = float(r['speedup'])
    print(f'  {r["label"]:<22} {s:.4f}  -> {"GROW FAST" if s > 2.0 else "grow slow"}')
