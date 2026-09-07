import sys, json
for l in sys.stdin:
    try: e = json.loads(l)
    except Exception: continue
    if e['event'] == 'progress':
        print(f"  t={e['ts']:5.1f}s  conns={e['conns']:3d}  speed={e['speed']/1048576:5.2f} MB/s  pct={e['pct']}")
    elif e['event'] == 'retry':
        print('  retry', e.get('reason'))
    elif e['event'] == 'summary':
        print(f"  summary: {e['speed']/1048576:.2f} MB/s in {e['seconds']}s")
