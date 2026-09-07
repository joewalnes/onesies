
import csv, statistics, collections, json, os
import analyze as az
def med(path):
    # AIDEV-NOTE: grouping/median logic lives in analyze.py (median_map) --
    # this just points it at one file, same as analyze.py's own CLI does.
    return az.median_map(az.load([path]))
lab = med('lab-results.csv'); sl = med('starlink-results.csv')
dc = med('dc-results.csv'); st = med('steady-results.csv'); oh = med('overhead-results.csv')
def grab(m, labels, tools): return {l: {t: m.get((l, t)) for t in tools} for l in labels}
out = {}
rtts=[0,25,100,250]; losses=['0','0.1','0.5']
tools6=['curl','aria2-8','axel-8','bigcurl-8','bigcurl-16','bigcurl-auto']
out['lab'] = {f'{r}|{l}': {t: lab.get((f'rtt{r}ms/loss{l}pct', t)) for t in tools6} for r in rtts for l in losses}
out['starlink'] = grab(sl, ['starlink>do-sfo/plain','starlink>hz-ore/plain','starlink>hz-ore/rate4m'],
                       ['curl','aria2-8','aria2-16','bigcurl-8','bigcurl-16','bigcurl-auto'])
out['sweep'] = {k: sl.get(('starlink>hz-ore/sweep', k)) for k in
                ['curl','bigcurl-1','bigcurl-2','bigcurl-4','bigcurl-8','bigcurl-16','bigcurl-32']}
out['dc'] = grab(dc, ['do-sfo>hz-ore/plain','do-sfo>hz-ore/rate4m','do-sfo>hz-ore/rate4m+cap8'],
                 ['curl','aria2-8','aria2-16','bigcurl-8','bigcurl-16','bigcurl-auto'])
out['steady'] = grab(st, ['steady/rtt100ms/loss0pct','steady/rtt250ms/loss0pct'],
                     ['curl','aria2-8','bigcurl-8','bigcurl-auto'])
out['overhead'] = {t: oh.get(('localhost/1GB', t)) for t in ['curl','aria2-8','axel-8','bigcurl-8','bigcurl-auto']}
cpu = collections.defaultdict(list)
for r in csv.DictReader(open('overhead-results.csv')):
    cpu[r['tool']].append((float(r['cpu_user'])+float(r['cpu_sys']))/(int(r['bytes'])/2**30))
out['cpu_per_gb'] = {t: round(statistics.median(v),2) for t,v in cpu.items()}
n = 0
for f in ['lab-results.csv','starlink-results.csv','dc-results.csv','steady-results.csv','overhead-results.csv']:
    if os.path.exists(f): n += sum(1 for _ in csv.DictReader(open(f)))
out['runs'] = n

# AIDEV-NOTE: ASK 4 (h2-vs-h1-*.csv) and ASK 2 (ask2-*.csv) sections below.
# Neither CSV uses the label/tool/ok shape analyze.py's aggregate() expects
# throughout -- h2-vs-h1-*.csv keys on rtt_ms/loss_pct/tool/verified instead
# of label/ok, so it's grouped by hand. ask2-*.csv DOES match that shape, so
# az.load/az.aggregate are reused for mbps and only the CPU figure (not in
# analyze.py at all) is grouped separately, same formula as 'cpu' above.

# --- ASK 4: HTTP/2 multiplexing (curl H1 x8 conn vs curl H2 x8 stream) -----
def h2_group(path):
    rows = list(csv.DictReader(open(path))) if os.path.exists(path) else []
    mbps = collections.defaultdict(list); ok = collections.defaultdict(list)
    for r in rows:
        key = (r['rtt_ms'], r['loss_pct'], r['tool'])
        mbps[key].append(float(r['mbps'])); ok[key].append(int(r['verified']))
    return mbps, ok

def h2_cell(mbps, ok, rtt, loss):
    cell = {}
    for tag, tool in [('h1', 'h1x8conn'), ('h2', 'h2x8stream')]:
        vs = mbps.get((str(rtt), loss, tool)); os_ = ok.get((str(rtt), loss, tool))
        cell[tag] = round(statistics.median(vs), 2) if vs else None
        cell[f'{tag}_ok'] = f'{sum(os_)}/{len(os_)}' if os_ else None
    return cell

h2lab_mbps, h2lab_ok = h2_group('h2-vs-h1-lab.csv')
out['h2lab'] = {f'{r}|{l}': h2_cell(h2lab_mbps, h2lab_ok, r, l) for r in rtts for l in losses}
h2st_mbps, h2st_ok = h2_group('h2-vs-h1-steady.csv')
out['h2steady'] = {str(r): h2_cell(h2st_mbps, h2st_ok, r, '0') for r in [100, 250]}

# --- ASK 2: perl in the byte path, at matched connection count ------------
def ask2_group(path):
    rows = az.load([path]) if os.path.exists(path) else []
    mbps = az.aggregate(rows)
    cpu = collections.defaultdict(list)
    for r in rows:
        cpu[(r['label'], r['tool'])].append(
            (float(r['cpu_user']) + float(r['cpu_sys'])) / (int(r['bytes']) / 2**30))
    return mbps, cpu

def ask2_cell(mbps, cpu, label, n):
    row = {}
    raw = {}
    for tag, tool in [('curl', 'curl'), ('bigcurl', f'bigcurl-{n}'),
                       ('curlo', f'curlo-{n}'), ('curldd', f'curldd-{n}')]:
        mv = mbps.get((label, tool)); cv = cpu.get((label, tool))
        row[tag] = round(statistics.median(mv), 2) if mv else None
        row[f'{tag}_cpu'] = round(statistics.median(cv), 2) if cv else None
        row[f'{tag}_n'] = len(mv) if mv else 0
        raw[tag] = statistics.median(mv) if mv else None
        raw[f'{tag}_cpu'] = statistics.median(cv) if cv else None
    # perl's cost vs. the no-perl ceiling (curldd), matched N -- computed here
    # from full-precision medians, not from the rounded display fields above,
    # so the percentage doesn't pick up rounding error from a second rounding.
    if raw.get('curldd') and raw.get('bigcurl'):
        row['wall_pct'] = round((raw['curldd'] - raw['bigcurl']) / raw['curldd'] * 100, 1)
    if raw.get('curldd_cpu') and raw.get('bigcurl_cpu'):
        row['cpu_pct'] = round((raw['bigcurl_cpu'] - raw['curldd_cpu']) / raw['curldd_cpu'] * 100, 1)
    return row

a2_mbps, a2_cpu = ask2_group('ask2-droplet.csv')
out['ask2'] = {str(n): ask2_cell(a2_mbps, a2_cpu, f'droplet>hz/n{n}', n) for n in [1, 2, 4]}
# curl is run in every batch as an N-independent noise-floor control (see
# REPRODUCE.md's ASK 2 section) -- its spread across all batches, not any
# one batch's median, is the read on how noisy this host+link is.
curl_all = [v for k, vs in a2_mbps.items() if k[1] == 'curl' for v in vs]
out['ask2_curl_all'] = {'median': round(statistics.median(curl_all), 2),
                         'min': round(min(curl_all), 2), 'max': round(max(curl_all), 2),
                         'n': len(curl_all)}
a2h_mbps, a2h_cpu = ask2_group('ask2-hetzner.csv')
out['ask2_hetzner'] = ask2_cell(a2h_mbps, a2h_cpu, 'hetzner/loopback/n4', 4)

n2 = 0
for f in ['h2-vs-h1-lab.csv', 'h2-vs-h1-steady.csv', 'ask2-droplet.csv', 'ask2-hetzner.csv']:
    if os.path.exists(f): n2 += sum(1 for _ in csv.DictReader(open(f)))
out['new_runs'] = n2

# --- ASK-by-ASK outcomes, and the tuner discriminator ---------------------
# AIDEV-NOTE: every figure here that HAS a CSV in this tree is recomputed from
# it. Figures marked 'inherited' in the report have no CSV backing them in
# this pass (ASK 1's --next comparison and ASK 3's hedging measurements were
# recorded in commit messages and in cli/bigcurl's own header, not as CSVs),
# so they are carried as literals and labelled as such in the prose rather
# than being passed off as recomputed. Do not quietly promote one to
# "measured" without adding the CSV it would be computed from.
asks = {}

# ASK 4 -- recomputed above into out['h2lab'] / out['h2steady'].
asks['a4_steady250_h1'] = out['h2steady']['250']['h1']
asks['a4_steady250_h2'] = out['h2steady']['250']['h2']
asks['a4_steady250_x'] = round(out['h2steady']['250']['h1'] / out['h2steady']['250']['h2'], 2)
asks['a4_steady100_h1'] = out['h2steady']['100']['h1']
asks['a4_steady100_h2'] = out['h2steady']['100']['h2']
asks['a4_lab100_0'] = round(out['h2lab']['100|0']['h2'] / out['h2lab']['100|0']['h1'], 2)
asks['a4_lab100_01'] = round(out['h2lab']['100|0.1']['h2'] / out['h2lab']['100|0.1']['h1'], 2)
asks['a4_dnf_ok'] = out['h2lab']['250|0.5']['h2_ok']
# the worst H2 deficit under loss, so "3-5x worse" is a measured range
_deficits = []
for k, c in out['h2lab'].items():
    if c.get('h1') and c.get('h2') and k.split('|')[1] != '0' and c['h2'] < c['h1']:
        _deficits.append(c['h1'] / c['h2'])
asks['a4_loss_worst'] = round(max(_deficits), 1) if _deficits else None
asks['a4_loss_best'] = round(min(d for d in _deficits if d > 2), 1) if _deficits else None

# ASK 2 -- recomputed above into out['ask2'].
asks['a2_bigcurl_lo'] = min(out['ask2'][n]['bigcurl'] for n in ['1','2','4'])
asks['a2_bigcurl_hi'] = max(out['ask2'][n]['bigcurl'] for n in ['1','2','4'])
asks['a2_curldd_lo'] = min(out['ask2'][n]['curldd'] for n in ['1','2','4'])
asks['a2_curldd_hi'] = max(out['ask2'][n]['curldd'] for n in ['1','2','4'])
asks['a2_cpu_pcts'] = [out['ask2'][n]['cpu_pct'] for n in ['1','2','4']]

# ASK 5 -- reread from extra.log, which this pass remeasured on 8066b6a.
asks['a5_bigcurl_s'] = asks['a5_xargs_s'] = None
if os.path.exists('extra.log'):
    import re
    for line in open('extra.log'):
        m = re.search(r'xargs -P8 curl\s*:\s*([0-9.]+)s', line)
        if m: asks['a5_xargs_s'] = float(m.group(1))
        m = re.search(r'bigcurl -i\s*:\s*([0-9.]+)s', line)
        if m: asks['a5_bigcurl_s'] = float(m.group(1))

# Future work -- the tuner discriminator, from the regime probe CSVs.
# S8 (parallel speedup) is the axis that separates a CPU/contention-bound
# regime from a link-bound one. The threshold 2.0 was fixed before measuring.
probe_rows = []
for f in ['regime-signal-probe.csv', 'regime-signal-probe-rep2.csv']:
    if os.path.exists(f): probe_rows += list(csv.DictReader(open(f)))
ctl_rows = list(csv.DictReader(open('regime-controls.csv'))) if os.path.exists('regime-controls.csv') else []
sp = collections.defaultdict(list)
for r in probe_rows: sp[r['label']].append(float(r['speedup']))
tuner = {}
if sp:
    tuner['threshold'] = 2.0
    tuner['cpubound'] = round(statistics.median(sp['cpubound-droplet']), 2) if 'cpubound-droplet' in sp else None
    others = [v for k, vs in sp.items() if k != 'cpubound-droplet' for v in vs]
    tuner['others_lo'] = round(min(others), 2) if others else None
    tuner['others_hi'] = round(max(others), 2) if others else None
    if tuner['cpubound'] and tuner['others_lo']:
        tuner['gap_x'] = round(tuner['others_lo'] / tuner['cpubound'], 1)
    # the clean cell was measured twice; its replication is the noise read
    cl = sp.get('clean-rtt250-loss0', [])
    if len(cl) >= 2:
        tuner['clean_reps'] = [round(v, 4) for v in cl]
        tuner['clean_spread_pct'] = round(abs(cl[0] - cl[1]) / statistics.mean(cl) * 100, 2)
    # the synthetic shared-cap control is a contention model and should also
    # read low -- that is a confirmation of the axis, not a counterexample
    for r in ctl_rows:
        if r['label'] == 'ctlB-shared-cap': tuner['ctl_shared_cap'] = round(float(r['speedup']), 2)
# S7 (straggler) is the half that did NOT resolve. Pre-registered at 1.5.
st = {}
for r in probe_rows: st.setdefault(r['label'], []).append(float(r['straggler']))
lossy = {k: v for k, v in st.items() if k.startswith('lossy-')}
nonlossy = {k: v for k, v in st.items() if not k.startswith('lossy-')}
if lossy and nonlossy:
    tuner['s7_threshold'] = 1.5
    # pass 1 has every cell; pass 2 re-ran a subset. Report the margin between
    # the lowest lossy and the highest non-lossy reading, per pass.
    p1 = list(csv.DictReader(open('regime-signal-probe.csv')))
    p1_lossy = min(float(r['straggler']) for r in p1 if r['label'].startswith('lossy-'))
    p1_non = max(float(r['straggler']) for r in p1 if not r['label'].startswith('lossy-'))
    tuner['s7_margin1'] = round((p1_lossy / p1_non - 1) * 100)
    allnon = max(v for vs in nonlossy.values() for v in vs)
    alllossy = min(v for vs in lossy.values() for v in vs)
    tuner['s7_margin2'] = round((alllossy / allnon - 1) * 100)
    tuner['s7_crosser'] = round(allnon, 2)
out['asks'] = asks
out['tuner'] = tuner

# --- headline figures ------------------------------------------------------
# AIDEV-NOTE: the verdict tiles and the summary prose used to carry these as
# literals typed into report.tmpl.html, and they went stale the moment the
# suites were rerun -- the published headline said "29x curl" from a cell
# where curl's own three reps span 36x. They are computed here so a
# remeasurement moves the headline with the data instead of silently
# contradicting it. Pick headline cells where BOTH tools are stable.
BC = ['bigcurl-8', 'bigcurl-16', 'bigcurl-auto']
def cell(l, t): return lab.get((l, t))
hl = {}
for tag, l in [('l250', 'rtt250ms/loss0.5pct'), ('l100', 'rtt100ms/loss0.5pct')]:
    hl[tag + '_curl'] = round(cell(l, 'curl'), 2)
    hl[tag + '_aria'] = round(cell(l, 'aria2-8'), 2)
    hl[tag + '_axel'] = round(cell(l, 'axel-8'), 2)
    hl[tag + '_bc'] = round(max(cell(l, t) for t in BC), 2)
    hl[tag + '_x'] = round(max(cell(l, t) for t in BC) / cell(l, 'curl'), 1)
# clean-link parity, and the rep spread that makes the 100ms cell unquotable
import csv as _csv
_reps = collections.defaultdict(list)
for r in _csv.DictReader(open('lab-results.csv')):
    _reps[(r['label'], r['tool'])].append(float(r['mbps']))
_c = sorted(_reps[('rtt100ms/loss0.5pct', 'curl')])
hl['curl_bimodal_lo'] = round(_c[0], 2); hl['curl_bimodal_hi'] = round(_c[-1], 2)
hl['curl_bimodal_x'] = round(_c[-1] / _c[0])
# how many of the 12 cells is the DEFAULT mode within 5% of the best tool in
hl['within5'] = sum(1 for l in set(k[0] for k in lab)
                    if cell(l, 'bigcurl-auto') >= 0.95 * max(
                        cell(l, t) for t in ['curl','aria2-8','axel-8'] + BC))
hl['cells'] = len(set(k[0] for k in lab))
# bigcurl against the other MULTI-CONNECTION tools -- both stable estimators
_leads = []
for l in set(k[0] for k in lab):
    b = max(cell(l, t) for t in BC); o = max(cell(l, 'aria2-8'), cell(l, 'axel-8'))
    _leads.append(b / o - 1)
hl['mc_ahead'] = sum(1 for d in _leads if d > 0)
hl['mc_lead_lo'] = round(min(d for d in _leads if d > 0) * 100)
hl['mc_lead_hi'] = round(max(_leads) * 100)
hl['mc_behind_by'] = round(-min(_leads) * 100)
# datacentre
for tag, l in [('plain', 'do-sfo>hz-ore/plain'), ('rate', 'do-sfo>hz-ore/rate4m'),
               ('cap8', 'do-sfo>hz-ore/rate4m+cap8')]:
    hl['dc_' + tag + '_curl'] = round(dc.get((l, 'curl')), 2)
    hl['dc_' + tag + '_aria'] = round(max(dc.get((l, 'aria2-8')), dc.get((l, 'aria2-16'))), 2)
    hl['dc_' + tag + '_auto'] = round(dc.get((l, 'bigcurl-auto')), 2)
    hl['dc_' + tag + '_bc8'] = round(dc.get((l, 'bigcurl-8')), 2)
    hl['dc_' + tag + '_bcbest'] = round(max(dc.get((l, t)) for t in BC), 2)
hl['dc_rate_x'] = round(hl['dc_rate_bcbest'] / hl['dc_rate_curl'], 1)
hl['dc_vps_x'] = round(hl['dc_plain_auto'] / hl['dc_plain_curl'], 2)
# starlink
_sl = 'starlink>hz-ore/plain'
hl['sl_curl'] = round(sl.get((_sl, 'curl')), 2)
hl['sl_aria'] = round(max(sl.get((_sl, 'aria2-8')), sl.get((_sl, 'aria2-16'))), 2)
hl['sl_bc'] = round(max(sl.get((_sl, t)) for t in BC), 2)
out['head'] = hl

json.dump(out, open('report-data.json','w'), indent=1)
print('report-data.json: runs =', n, ' new_runs =', n2)
print('  asks:', {k: v for k, v in asks.items() if k.startswith(('a5', 'a4_steady250'))})
print('  tuner:', tuner)
