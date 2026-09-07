#!/usr/bin/env python3
"""Emit static SVG for the report. Horizontal grouped bars: long tool names read
cleanly and every bar can carry a direct value label (the light palette warns on
contrast, so labels are obligatory, not optional)."""
import json
D = json.load(open('report-data.json'))
SERIES = ['curl', 'aria2-8', 'axel-8', 'bigcurl-auto']
NICE = {'curl': 'curl', 'aria2-8': 'aria2c -x8', 'axel-8': 'axel -n8',
        'bigcurl-auto': 'bigcurl', 'aria2-16': 'aria2c -x16',
        'bigcurl-8': 'bigcurl -n8', 'bigcurl-16': 'bigcurl -n16'}
SLOT = {'curl': 1, 'aria2-8': 2, 'aria2-16': 2, 'axel-8': 3,
        'bigcurl-auto': 4, 'bigcurl-8': 4, 'bigcurl-16': 4}

def esc(s): return s.replace('&', '&amp;').replace('<', '&lt;')

def hbars(groups, rows, width=560, bar=13, gap=2, grouppad=20,
          left=104, right=54, top=26, unit='MB/s', ymax=None):
    """groups: [(label, [(tool, value), ...]), ...]"""
    vmax = ymax or max(v for _, rs in groups for _, v in rs if v) * 1.14
    plotw = width - left - right
    y = top
    body, ticks = [], []
    for glabel, rs in groups:
        gh = len(rs) * bar + (len(rs) - 1) * gap
        body.append(f'<text x="{left-12}" y="{y+gh/2:.1f}" class="glab" '
                    f'text-anchor="end" dominant-baseline="middle">{esc(glabel)}</text>')
        for tool, v in rs:
            v = v or 0
            w = max(2.0, plotw * v / vmax)
            body.append(
                f'<rect x="{left}" y="{y}" width="{w:.1f}" height="{bar}" rx="4" '
                f'fill="var(--s{SLOT[tool]})"/>')
            body.append(
                f'<text x="{left+w+7:.1f}" y="{y+bar/2:.1f}" class="vlab" '
                f'dominant-baseline="middle">{v:.2f}</text>')
            y += bar + gap
        y += grouppad
    y -= grouppad
    step = 1 if vmax <= 8 else (5 if vmax <= 26 else (10 if vmax <= 70 else 20))
    t = 0
    while t <= vmax:
        x = left + plotw * t / vmax
        ticks.append(f'<line x1="{x:.1f}" y1="{top-8}" x2="{x:.1f}" y2="{y}" class="grid"/>')
        ticks.append(f'<text x="{x:.1f}" y="{top-13}" class="tick" text-anchor="middle">{t}</text>')
        t += step
    ticks.append(f'<text x="{left-12}" y="{top-13}" class="tick" '
                 f'text-anchor="end">{unit}</text>')
    h = y + 10
    return (f'<svg viewBox="0 0 {width} {h:.0f}" width="100%" height="auto" '
            f'role="img" class="chart">' + ''.join(ticks) + ''.join(body) + '</svg>')

def legend(tools=SERIES):
    out = []
    for t in tools:
        out.append(f'<span class="key"><i style="background:var(--s{SLOT[t]})"></i>'
                   f'{esc(NICE[t])}</span>')
    return '<div class="legend">' + ''.join(out) + '</div>'

# --- lab: two RTT panels, three loss levels each ---------------------------
def lab_panel(rtt):
    groups = []
    for loss in ['0', '0.1', '0.5']:
        cell = D['lab'][f'{rtt}|{loss}']
        lbl = 'no loss' if loss == '0' else f'{loss}% loss'
        groups.append((lbl, [(t, cell[t]) for t in SERIES]))
    return hbars(groups, None, ymax=24)

# --- starlink --------------------------------------------------------------
SL = [('Hetzner Oregon, 50 ms', 'starlink>hz-ore/plain'),
      ('DO Santa Clara, 24 ms', 'starlink>do-sfo/plain'),
      ('Oregon, 4 MB/s per conn', 'starlink>hz-ore/rate4m')]
sl_groups = [(lbl, [(t, D['starlink'][k][t]) for t in
                    ['curl', 'aria2-8', 'aria2-16', 'bigcurl-auto']]) for lbl, k in SL]

# --- connection sweep ------------------------------------------------------
sweep_keys = ['bigcurl-1', 'bigcurl-2', 'bigcurl-4', 'bigcurl-8', 'bigcurl-16', 'bigcurl-32']
def sweep_svg(width=560, h=210, left=44, right=22, top=22, bot=42):
    xs = [1, 2, 4, 8, 16, 32]
    ys = [D['sweep'][k] for k in sweep_keys]
    ref = D['sweep']['curl']
    vmax = 6.0
    plotw, ploth = width - left - right, h - top - bot
    import math
    def px(i): return left + plotw * i / (len(xs) - 1)
    def py(v): return top + ploth * (1 - v / vmax)
    o = [f'<svg viewBox="0 0 {width} {h}" width="100%" height="auto" role="img" class="chart">']
    for t in range(0, 7):
        yy = py(t)
        o.append(f'<line x1="{left}" y1="{yy:.1f}" x2="{width-right}" y2="{yy:.1f}" class="grid"/>')
        o.append(f'<text x="{left-8}" y="{yy:.1f}" class="tick" text-anchor="end" '
                 f'dominant-baseline="middle">{t}</text>')
    o.append(f'<line x1="{left}" y1="{py(ref):.1f}" x2="{width-right}" y2="{py(ref):.1f}" '
             f'class="ref"/>')
    o.append(f'<text x="{width-right}" y="{py(ref)-7:.1f}" class="reflab" text-anchor="end">'
             f'curl, one stream — {ref:.2f}</text>')
    pts = ' '.join(f'{px(i):.1f},{py(v):.1f}' for i, v in enumerate(ys))
    o.append(f'<polyline points="{pts}" fill="none" stroke="var(--s4)" stroke-width="2" '
             f'stroke-linejoin="round"/>')
    for i, v in enumerate(ys):
        o.append(f'<circle cx="{px(i):.1f}" cy="{py(v):.1f}" r="4.5" fill="var(--s4)" '
                 f'stroke="var(--surface)" stroke-width="2"/>')
        o.append(f'<text x="{px(i):.1f}" y="{py(v)-12:.1f}" class="vlab" '
                 f'text-anchor="middle">{v:.2f}</text>')
        o.append(f'<text x="{px(i):.1f}" y="{top+ploth+18:.1f}" class="tick" '
                 f'text-anchor="middle">{xs[i]}</text>')
    o.append(f'<text x="{left+plotw/2:.1f}" y="{h-8}" class="axtitle" text-anchor="middle">'
             f'connections</text>')
    o.append(f'<text x="{left-8}" y="{top-9}" class="tick" text-anchor="end">MB/s</text>')
    o.append('</svg>')
    return ''.join(o)

open('charts.json', 'w').write(json.dumps({
    'lab100': lab_panel(100), 'lab250': lab_panel(250),
    'starlink': hbars(sl_groups, None, ymax=6.2),
    'sweep': sweep_svg(),
    'legend4': legend(), 'legendSL': legend(['curl', 'aria2-8', 'aria2-16', 'bigcurl-auto']),
}))
print('charts written')
