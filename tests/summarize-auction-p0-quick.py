"""Summarize the bounded standalone SOCI / Godot adapter comparison."""
import csv
import io
import json
import math
from pathlib import Path
import statistics

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'.godot/verification/auction-p0'

def stats(values):
    ordered=sorted(values)
    return {'n':len(values),'p50_ms':statistics.median(values)/1000,
            'p95_ms':ordered[math.ceil(len(values)*.95)-1]/1000,'max_ms':max(values)/1000}

def main():
    results=[]
    for profile in ['diag-353-o2-nodebug','release','release041']:
        for state in ['baseline','lookup']:
            path=OUT/f'{profile}-{state}-broad/raw.json'
            if not path.exists():continue
            raw=json.loads(path.read_text(encoding='utf-8'))
            for adapter in sorted({r['adapter'] for r in raw['records']}):
                rows=[r for r in raw['records'] if r['adapter']==adapter and r['phase']=='warm']
                results.append({'profile':profile,'state':state,'adapter':adapter,
                                'rows':sorted({r['rows'] for r in rows}),
                                'wall':stats([r['wall_us'] for r in rows]),
                                'sql':stats([r['sql_us'] for r in rows]) if 'sql_us' in rows[0] else None,
                                'gate_failures':sum(r['wall_us']>2000000 or r.get('sql_us',0)>2000000 for r in rows)})
    for state in ['baseline','lookup']:
        path=OUT/f'pure-353-o2-nodebug-{state}-broad.csv'
        if not path.exists():continue
        lines=path.read_text(encoding='utf-8-sig').splitlines()
        # First line is SQLite runtime version; the second is the CSV header.
        rows=[r for r in csv.DictReader(io.StringIO('\n'.join(lines[1:]))) if r['phase']=='warm']
        results.append({'profile':'standalone-353-o2-nodebug','state':state,'adapter':'pure_soci',
                        'version':lines[0].split(',')[1], 'rows':sorted({int(r['rows']) for r in rows}),
                        'wall':stats([int(r['wall_us']) for r in rows]),
                        'sql':stats([int(r['sql_us']) for r in rows]),
                        'gate_failures':sum(int(r['wall_us'])>2000000 or int(r['sql_us'])>2000000 for r in rows)})
    (OUT/'quick-summary.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
    for r in results:
        wall=r['wall'];sql=r['sql']
        print(f"{r['state']:8} {r['profile']:26} {r['adapter']:20} n={wall['n']:2} "
              f"wall={wall['p50_ms']:.3f}/{wall['p95_ms']:.3f}/{wall['max_ms']:.3f} "
              f"sql={sql['p50_ms'] if sql else 'unavailable'} FAIL={r['gate_failures']}")

if __name__=='__main__':main()
