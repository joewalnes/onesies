#!/usr/bin/env python3
"""Summarise benchmark CSVs: median MB/s per (scenario, tool), plus speedup vs curl."""
import csv, sys, statistics, collections, json

def load(paths):
    rows = []
    missing = []
    for p in paths:
        try:
            with open(p) as f:
                rows += list(csv.DictReader(f))
        except FileNotFoundError:
            missing.append(p)
    # AIDEV-NOTE: used to silently return [] here, so e.g. running from outside
    # bench/bigcurl/ found nothing, printed nothing, and exited 0. Fail loudly instead.
    if missing and len(missing) == len(paths):
        sys.exit(f"error: none of the requested CSVs were found: {', '.join(missing)} "
                  f"(run from bench/bigcurl/?)")
    return rows

# AIDEV-NOTE: aggregate() is also imported by compile-data.py -- it is the one
# place that groups raw CSV rows by (label, tool). Don't fork a second copy.
def aggregate(rows):
    """Group raw mbps values by (label, tool)."""
    agg = collections.defaultdict(list)
    for r in rows:
        agg[(r['label'], r['tool'])].append(float(r['mbps']))
    return agg

def median_map(rows):
    """{(label, tool): median mbps}, rounded for display/JSON."""
    return {k: round(statistics.median(v), 2) for k, v in aggregate(rows).items()}

def table(rows, tools=None, sort_key=None):
    agg = aggregate(rows)
    okc = collections.defaultdict(list)
    for r in rows:
        okc[(r['label'], r['tool'])].append(int(r['ok']))
    labels = sorted({k[0] for k in agg}, key=sort_key)
    if tools is None:
        tools = sorted({k[1] for k in agg})
    return labels, tools, agg, okc

def render(rows, tools=None, sort_key=None, title=''):
    labels, tools, agg, okc = table(rows, tools, sort_key)
    w = max([len(l) for l in labels] + [20]) + 2
    print(f"\n{title}")
    print(f"{'scenario':<{w}}" + ''.join(f"{t:>14}" for t in tools) + f"{'best/curl':>12}")
    print('-' * (w + 14 * len(tools) + 12))
    for l in labels:
        line = f"{l:<{w}}"
        vals = {}
        for t in tools:
            v = agg.get((l, t))
            if v:
                m = statistics.median(v)
                vals[t] = m
                bad = '' if all(okc[(l, t)]) else '!'
                line += f"{m:>13.2f}{bad:<1}"
            else:
                line += f"{'-':>14}"
        base = vals.get('curl')
        best = max((v for k, v in vals.items() if k != 'curl'), default=None)
        line += f"{best / base:>11.2f}x" if base and best and base > 0 else f"{'-':>12}"
        print(line)
    print("  ('!' = at least one run failed or hit the time cap)")

def rtt_key(s):
    try:
        rtt = int(s.split('rtt')[1].split('ms')[0])
        loss = float(s.split('loss')[1].split('pct')[0])
        return (loss, rtt)
    except Exception:
        return (0, 0)

if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which in ('lab', 'all'):
        r = load(['lab-results.csv'])
        if r: render(r, ['curl', 'aria2-8', 'axel-8', 'bigcurl-8', 'bigcurl-auto'],
                     rtt_key, 'LAB: netem RTT x loss, 200 Mbit, 32 MB file (median MB/s)')
    if which in ('starlink', 'all'):
        r = load(['starlink-results.csv'])
        if r: render(r, ['curl', 'aria2-8', 'aria2-16', 'bigcurl-8', 'bigcurl-16', 'bigcurl-auto'],
                     None, 'STARLINK: desktop -> origins (median MB/s)')
        if r: render([x for x in r if 'sweep' in x['label']],
                     ['curl', 'bigcurl-1', 'bigcurl-2', 'bigcurl-4', 'bigcurl-8', 'bigcurl-16', 'bigcurl-32'],
                     None, 'STARLINK: connection sweep (median MB/s)')
    if which in ('dc', 'all'):
        r = load(['dc-results.csv'])
        if r: render(r, ['curl', 'aria2-8', 'aria2-16', 'bigcurl-8', 'bigcurl-16', 'bigcurl-auto'],
                     None, 'DATACENTRE: DO SFO -> Hetzner Oregon (median MB/s)')
    if which in ('overhead', 'all'):
        r = load(['overhead-results.csv'])
        if r: render(r, ['curl', 'aria2-8', 'bigcurl-8', 'bigcurl-auto'], None,
                     'OVERHEAD: localhost, no network limit (median MB/s)')
    # AIDEV-NOTE: ASK 2 -- perl-in-the-byte-path cost, isolated from connection
    # count by comparing bigcurl-N against curlo-N/curldd-N (byteproxy.sh,
    # zero perl in the byte path) at the SAME N, never against bigcurl-auto or
    # single-stream curl (that comparison is confounded by N -- see ASK 1's
    # write-up for why it was misleading there).
    if which in ('ask2', 'all'):
        r = load(['ask2-droplet.csv'])
        if r: render(r, ['curl', 'bigcurl-1', 'curlo-1', 'curldd-1',
                          'bigcurl-2', 'curlo-2', 'curldd-2',
                          'bigcurl-4', 'curlo-4', 'curldd-4'], None,
                     'ASK 2: droplet (1 core, CPU-bound) -> Hetzner, matched-N (median MB/s)')
        r = load(['ask2-hetzner.csv'])
        if r: render(r, ['curl', 'bigcurl-4', 'curlo-4', 'curldd-4'], None,
                     'ASK 2 CONTROL: Hetzner (16 core) -> loopback, matched-N (median MB/s)')
