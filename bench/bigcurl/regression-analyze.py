#!/usr/bin/env python3
"""regression-analyze.py - N-build comparison for the regression sweep's
CSVs (regression-lab.csv, regression-dc.csv), anchored on a baseline tag.

Each row's label carries a /<tag> suffix (e.g. "old", "tip", "fixed") added
by regression-lab.sh / regression-dc.sh; this groups by the label with that
suffix stripped, compares every non-baseline tag against "old" for each
tool, and applies the regression thresholds fixed *before* any measurement
was taken (see REPRODUCE.md's "Regression sweep" section for the reasoning):

  * loss 0% / 0.1% cells, and the droplet: >20% slower than "old" is
    flagged. The droplet's own measured noise floor (ask2-droplet.csv) put
    curl's spread at 24% of its median across 9 reps on this exact
    host+link, so 20% is already inside that noise band -- flags here are
    a lower bound on "worth a look," not a hard verdict.
  * loss 0.5% cells: >40% slower than "old" is flagged. These cells are
    dominated by netem's per-packet random loss, which the original
    lab-results.csv shows producing same-build, same-cell spreads
    approaching 30-40% over just 3 reps (e.g. bigcurl-8 at
    rtt100/loss0.5%: 8.539/7.401/6.465).
  * Any row with ok=0 (sha256 mismatch or timeout) is an automatic
    regression regardless of speed -- correctness beats throughput.

AIDEV-NOTE: originally hardcoded to exactly two tags ("old"/"new"). A
three-build comparison came up mid-run (old / tip=currently-shipped /
fixed=candidate fix) to answer "does the fix resolve the regression in the
lossy cells" in the same host session that measures whether the regression
reaches those cells at all -- so this is now generic over any number of
non-"old" tags rather than special-casing a second one. "old" is always
the reference; every other tag found for a given (scenario, tool) pair is
reported against it independently.

This does not replace analyze.py (which has no notion of a build tag) and
does not modify it; it imports its aggregate() to avoid a second copy of
the grouping logic.

Joe Walnes <joe@walnes.com>, 2026, MIT License
https://github.com/joewalnes/onesies
"""
import csv, sys, statistics, collections, pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from analyze import aggregate  # noqa: E402  (AIDEV-NOTE: shared grouping logic, see above)

BASELINE_TAG = 'old'
LOSS_THRESHOLD_PCT = {'0.5': 40.0}
DEFAULT_THRESHOLD_PCT = 20.0


def threshold_for(label):
    if '/loss' in label:
        loss = label.split('/loss')[1].split('pct')[0]
        return LOSS_THRESHOLD_PCT.get(loss, DEFAULT_THRESHOLD_PCT)
    return DEFAULT_THRESHOLD_PCT


def load(path):
    try:
        with open(path) as f:
            rows = list(csv.DictReader(f))
    except FileNotFoundError:
        sys.exit(f"error: {path} not found (run from bench/bigcurl/?)")
    # AIDEV-NOTE: fail loudly on zero rows, same convention as analyze.py --
    # a comparison over no data must not print a quiet, misleading "pass".
    if not rows:
        sys.exit(f"error: {path} exists but has zero data rows")
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: regression-analyze.py <csv> [<csv> ...]")
    rows = []
    for path in sys.argv[1:]:
        rows += load(path)

    agg = aggregate(rows)
    okmap = collections.defaultdict(list)
    for r in rows:
        okmap[(r['label'], r['tool'])].append(int(r['ok']))

    # Split label into (base, tag): "rtt250ms/loss0.5pct/tip" -> ("rtt250ms/loss0.5pct", "tip")
    by_base = collections.defaultdict(dict)  # base -> tool -> tag -> median
    tags_seen = set()
    for (label, tool), vals in agg.items():
        if '/' not in label:
            continue
        base, tag = label.rsplit('/', 1)
        by_base[base].setdefault(tool, {})[tag] = statistics.median(vals)
        tags_seen.add(tag)

    compared = 0
    flagged = []
    w_scn, w_tool, w_val = 26, 14, 10
    header = f"{'scenario':<{w_scn}}{'tool':<{w_tool}}{BASELINE_TAG + ' MB/s':>{w_val}}" \
              f"{'tag':>8}{'MB/s':>{w_val}}{'delta':>9}{'thresh':>8}  verdict"
    print(header)
    print('-' * len(header))
    for base in sorted(by_base):
        thr = threshold_for(base)
        for tool in sorted(by_base[base]):
            tags = by_base[base][tool]
            if BASELINE_TAG not in tags:
                continue
            baseline = tags[BASELINE_TAG]
            baseline_ok = all(okmap.get((f'{base}/{BASELINE_TAG}', tool), [0]))
            for tag in sorted(t for t in tags if t != BASELINE_TAG):
                val = tags[tag]
                compared += 1
                delta_pct = 100.0 * (val - baseline) / baseline if baseline else float('nan')
                val_ok = all(okmap.get((f'{base}/{tag}', tool), [0]))
                if not baseline_ok or not val_ok:
                    verdict = 'FAIL (verification)'
                elif delta_pct <= -thr:
                    verdict = 'FLAGGED (regression)'
                    flagged.append((base, tool, tag, delta_pct, thr))
                else:
                    verdict = 'ok'
                print(f"{base:<{w_scn}}{tool:<{w_tool}}{baseline:>{w_val}.2f}"
                      f"{tag:>8}{val:>{w_val}.2f}{delta_pct:>+8.1f}%{thr:>7.0f}%  {verdict}")

    # AIDEV-NOTE: the real "vacuous gate" guard -- assert a non-trivial number
    # of (scenario, tool, tag) triples were actually compared, not just that
    # the script ran and printed a header.
    if compared == 0:
        sys.exit(f"error: no (scenario, tool) pair had both a '{BASELINE_TAG}' tag and "
                  f"another tag -- nothing was actually compared")

    print(f"\n{compared} (scenario, tool, tag) comparisons against '{BASELINE_TAG}'. "
          f"Tags seen: {sorted(tags_seen)}")
    if flagged:
        print(f"{len(flagged)} FLAGGED:")
        for base, tool, tag, delta_pct, thr in flagged:
            print(f"  {base} / {tool} / {tag}: {delta_pct:+.1f}% (threshold {thr:.0f}%)")
        sys.exit(1)
    print("No regressions past threshold.")


if __name__ == '__main__':
    main()
