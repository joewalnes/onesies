#!/usr/bin/env python3
import json, os
C = json.load(open('charts.json')); T = json.load(open('tables.json'))
HTML = open('report.tmpl.html').read()
D = json.load(open('report-data.json'))
T['runs'] = f"{D['runs']:,}"
for k, v in list(C.items()) + list(T.items()):
    HTML = HTML.replace('{{' + k + '}}', v)
# AIDEV-NOTE: repo root, relative to this file -- was a hardcoded personal path.
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'bigcurl-benchmarks.html')
open(out, 'w').write(HTML)
print('built', len(HTML), 'bytes ->', out)
