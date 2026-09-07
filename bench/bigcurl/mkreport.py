#!/usr/bin/env python3
import json
D = json.load(open('report-data.json'))
C = json.load(open('charts.json'))
def f(v, d=2): return '—' if v is None else f'{v:.{d}f}'
def speedup(c):
    """Best non-curl tool's throughput as a multiple of curl's, in one {tool: mbps} row."""
    best = max((v for k, v in c.items() if k != 'curl' and v), default=0)
    return best / c['curl'] if c.get('curl') else 0

# ---- lab table -----------------------------------------------------------
rtts = [0, 25, 100, 250]; losses = ['0', '0.1', '0.5']
labtools = ['curl', 'aria2-8', 'axel-8', 'bigcurl-8', 'bigcurl-16', 'bigcurl-auto']
rows = []
for l in losses:
    for r in rtts:
        c = D['lab'][f'{r}|{l}']
        sp = speedup(c)
        cls = ' class="win"' if sp >= 2 else ''
        cells = ''.join(f'<td>{f(c[t])}</td>' for t in labtools)
        rows.append(f'<tr{cls}><td class="k">{r} ms</td><td class="k">'
                    f'{"—" if l=="0" else l+"%"}</td>{cells}'
                    f'<td class="sp">{sp:.1f}×</td></tr>')
labrows = ''.join(rows)

def simple_table(d, keys, tools, names):
    head = ''.join(f'<th>{t}</th>' for t in names)
    body = ''
    for k, label in keys:
        c = d[k]
        sp = speedup(c)
        body += (f'<tr><td class="k">{label}</td>'
                 + ''.join(f'<td>{f(c[t])}</td>' for t in tools)
                 + f'<td class="sp">{sp:.1f}×</td></tr>')
    return head, body

sl_head, sl_body = simple_table(
    D['starlink'],
    [('starlink>hz-ore/plain', 'Hetzner Oregon · 50 ms · no server limit'),
     ('starlink>do-sfo/plain', 'DO Santa Clara · 24 ms · no server limit'),
     ('starlink>hz-ore/rate4m', 'Hetzner Oregon · 50 ms · 4 MB/s per connection')],
    ['curl', 'aria2-8', 'aria2-16', 'bigcurl-8', 'bigcurl-16', 'bigcurl-auto'],
    ['curl', 'aria2c -x8', 'aria2c -x16', 'bigcurl -n8', 'bigcurl -n16', 'bigcurl'])

dc_head, dc_body = simple_table(
    D['dc'],
    [('do-sfo>hz-ore/plain', 'no server limit'),
     ('do-sfo>hz-ore/rate4m', '4 MB/s per connection'),
     ('do-sfo>hz-ore/rate4m+cap8', '4 MB/s per connection, 8 connections per IP')],
    ['curl', 'aria2-8', 'aria2-16', 'bigcurl-8', 'bigcurl-16', 'bigcurl-auto'],
    ['curl', 'aria2c -x8', 'aria2c -x16', 'bigcurl -n8', 'bigcurl -n16', 'bigcurl'])

st_head, st_body = simple_table(
    D['steady'],
    [('steady/rtt100ms/loss0pct', '100 ms RTT · no loss · 1 GB'),
     ('steady/rtt250ms/loss0pct', '250 ms RTT · no loss · 1 GB')],
    ['curl', 'aria2-8', 'bigcurl-8', 'bigcurl-auto'],
    ['curl', 'aria2c -x8', 'bigcurl -n8', 'bigcurl'])

oh = D['overhead']; cpu = D['cpu_per_gb']
ohrows = ''.join(
    f'<tr><td class="k">{n}</td><td>{f(oh[t],0)}</td><td>{f(cpu.get(t))}</td></tr>'
    for t, n in [('curl','curl'),('aria2-8','aria2c -x8'),('axel-8','axel -n8'),
                 ('bigcurl-8','bigcurl -n8'),('bigcurl-auto','bigcurl')])

# ---- ASK 4: HTTP/2 multiplexing (curl H1 x8 conn vs curl H2 x8 stream) ----
# AIDEV-NOTE: ratio is reported mechanically (H2/H1, shaded "win" >=1.1x, same
# convention as the lab table's speedup column above) rather than the mix of
# "+N%" / "N.Nx faster" prose REPRODUCE.md's human-written ASK 4 table uses --
# that wording was a judgment call per cell, not a formula, so it isn't
# reproducible from the JSON and isn't replicated here. A verified=0 cell is
# rendered as a failure, never as a ratio -- see ASKS.md brief: "must be
# shown as failures, not slow successes."
def h2_ratio(cell):
    h1, h2, h2ok = cell['h1'], cell['h2'], cell['h2_ok']
    if h2ok and int(h2ok.split('/')[0]) == 0:
        return f'<span class="dnf">H2 did not finish ({h2ok} verified)</span>', False
    if not h1 or not h2:
        return '—', False
    r = h2 / h1
    return f'{r:.2f}×', r >= 1.1

h2labrows = []
for l in losses:
    for r in rtts:
        c = D['h2lab'][f'{r}|{l}']
        ratio, win = h2_ratio(c)
        cls = ' class="win"' if win else ''
        h2labrows.append(f'<tr{cls}><td class="k">{r} ms</td><td class="k">'
                          f'{"—" if l=="0" else l+"%"}</td>'
                          f'<td>{f(c["h1"])}</td><td>{f(c["h2"])}</td>'
                          f'<td class="sp">{ratio}</td></tr>')
h2labrows = ''.join(h2labrows)

h2strows = []
for r in [100, 250]:
    c = D['h2steady'][str(r)]
    ratio, win = h2_ratio(c)
    cls = ' class="win"' if win else ''
    h2strows.append(f'<tr{cls}><td class="k">{r} ms</td>'
                     f'<td>{f(c["h1"])}</td><td>{f(c["h2"])}</td>'
                     f'<td class="sp">{ratio}</td></tr>')
h2strows = ''.join(h2strows)
h2steady250_slower = D['h2steady']['250']['h1'] / D['h2steady']['250']['h2']

# ---- ASK 2: perl in the byte path, at matched connection count -----------
a2names = [('curl', 'curl'), ('bigcurl', 'bigcurl -n N'),
           ('curlo', 'curlo-N'), ('curldd', 'curldd-N')]
a2mbrows = ''.join(
    f'<tr><td class="k">N={n}</td>'
    + ''.join(f'<td>{f(D["ask2"][n][t])}</td>' for t, _ in a2names)
    + '</tr>' for n in ['1', '2', '4'])
a2curows = ''.join(
    f'<tr><td class="k">N={n}</td>'
    + ''.join(f'<td>{f(D["ask2"][n][t + "_cpu"])}</td>' for t, _ in a2names)
    + '</tr>' for n in ['1', '2', '4'])
# perl's cost against the no-perl ceiling (curldd), matched N, both metrics --
# same arithmetic REPRODUCE.md's ASK 2 section uses, recomputed from the CSV
# rather than transcribed (wall_pct/cpu_pct come from compile-data.py, from
# full-precision medians, not from the rounded display fields above).
a2costrows = ''.join(
    f'<tr><td class="k">N={n}</td>'
    f'<td>{D["ask2"][n]["wall_pct"]:.1f}%</td><td>{D["ask2"][n]["cpu_pct"]:.1f}%</td></tr>'
    for n in ['1', '2', '4'])
ca = D['ask2_curl_all']
noise_pct = (ca['max'] - ca['min']) / ca['median'] * 100
h = D['ask2_hetzner']

# ---- ASK-by-ASK outcomes + the tuner discriminator ----------------------
# AIDEV-NOTE: these are pass-through formatters over report-data.json's
# 'asks'/'tuner' blocks, which compile-data.py computes from the CSVs. Prose
# lives in report.tmpl.html so the numbers cannot drift from the sentences
# that frame them -- change a measurement and the sentence re-renders.
A = D['asks']; T = D['tuner']
H = D['head']
# headline figures, exposed as {{hl_*}} so the verdict tiles and summary prose
# cannot drift from the CSVs the tables are built from.
hlvals = {}
for k, v in H.items():
    hlvals['hl_' + k] = (f'{v:.2f}' if isinstance(v, float) and abs(v) < 100 and k.endswith(
        ('_curl', '_aria', '_axel', '_bc', '_auto', '_bc8', '_bcbest', '_lo', '_hi', '_vps_x'))
        else (f'{v:.1f}' if isinstance(v, float) else str(v)))
askvals = {
    'a4_s250_h1': f(A['a4_steady250_h1']), 'a4_s250_h2': f(A['a4_steady250_h2']),
    'a4_s250x': f'{A["a4_steady250_x"]:.2f}',
    'a4_s100_h1': f(A['a4_steady100_h1']), 'a4_s100_h2': f(A['a4_steady100_h2']),
    'a4_lab100_0': f'{A["a4_lab100_0"]:.2f}', 'a4_lab100_01': f'{A["a4_lab100_01"]:.2f}',
    'a4_dnf_ok': str(A['a4_dnf_ok']),
    'a4_loss_lo': f'{A["a4_loss_best"]:.1f}', 'a4_loss_hi': f'{A["a4_loss_worst"]:.1f}',
    'a2_bc_lo': f(A['a2_bigcurl_lo'],1), 'a2_bc_hi': f(A['a2_bigcurl_hi'],1),
    'a2_dd_lo': f(A['a2_curldd_lo'],1), 'a2_dd_hi': f(A['a2_curldd_hi'],1),
    'a2_cpu1': f'{A["a2_cpu_pcts"][0]:.1f}', 'a2_cpu2': f'{A["a2_cpu_pcts"][1]:.1f}',
    'a2_cpu4': f'{A["a2_cpu_pcts"][2]:.1f}',
    'a5_bc': f'{A["a5_bigcurl_s"]:.2f}' if A.get('a5_bigcurl_s') else '—',
    'a5_xargs': f'{A["a5_xargs_s"]:.2f}' if A.get('a5_xargs_s') else '—',
    'tn_cpu': f'{T["cpubound"]:.2f}', 'tn_lo': f'{T["others_lo"]:.2f}',
    'tn_hi': f'{T["others_hi"]:.2f}', 'tn_gap': f'{T["gap_x"]:.0f}',
    'tn_thresh': f'{T["threshold"]:.1f}',
    'tn_clean': f'{T["clean_spread_pct"]:.2f}', 'tn_ctlb': f'{T["ctl_shared_cap"]:.2f}',
    's7_thresh': f'{T["s7_threshold"]:.1f}', 's7_m1': str(T['s7_margin1']),
    's7_m2': str(T['s7_margin2']), 's7_cross': f'{T["s7_crosser"]:.2f}',
}

open('tables.json','w').write(json.dumps({
    **askvals, **hlvals,
    'lab': labrows, 'sl_head': sl_head, 'sl_body': sl_body,
    'dc_head': dc_head, 'dc_body': dc_body,
    'st_head': st_head, 'st_body': st_body, 'oh': ohrows,
    'h2lab': h2labrows, 'h2steady': h2strows,
    'h2steady250x': f'{h2steady250_slower:.1f}',
    'a2mb': a2mbrows, 'a2cpu': a2curows, 'a2cost': a2costrows,
    'a2_curl_med': f(ca['median'],1), 'a2_curl_min': f(ca['min'],1),
    'a2_curl_max': f(ca['max'],1), 'a2_curl_n': str(ca['n']),
    'a2_noise_pct': f'{noise_pct:.0f}',
    'a2h_bigcurl_cpu': f(h['bigcurl_cpu']), 'a2h_curldd_cpu': f(h['curldd_cpu']),
    'a2h_bigcurl_mb': f(h['bigcurl'],0), 'a2h_curldd_mb': f(h['curldd'],0),
    'new_runs': f"{D['new_runs']:,}",
}))
print('tables written')
