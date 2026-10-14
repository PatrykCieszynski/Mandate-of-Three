"""Aggregate real P0 samples and plans; missing native SQL is null, never inferred."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import statistics

ROOT=Path(__file__).resolve().parents[1]


def distribution(values):
    ordered=sorted(values)
    return {'n':len(ordered),'p50_ms':statistics.median(ordered)/1000,'p95_ms':ordered[math.ceil(len(ordered)*.95)-1]/1000,'max_ms':ordered[-1]/1000}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'.godot/verification/auction-p0/summary.json')
    args=parser.parse_args()
    groups=defaultdict(list); plans=[]; profiles=[]
    for file in sorted((ROOT/'.godot/verification/auction-p0').glob('*/raw.json')):
        raw=json.loads(file.read_text())
        if raw.get('probe_only'): continue
        wait_mode=raw.get('wait_mode','frame')
        profiles.append({'profile':raw['profile'],'wait_mode':wait_mode,'file':str(file.relative_to(ROOT)).replace('\\','/'),'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'gate_failures':len(raw['failures']),'telemetry':raw['telemetry'],'cold_definition':raw['cold_definition'],'poll_max_us':raw['poll_max_us'],'gate_us':raw['gate_us']})
        plans.extend({'profile':raw['profile'],'wait_mode':wait_mode,**plan} for plan in raw['plans'])
        for row in raw['records']:
            key=(raw['profile'],wait_mode,row['state'],row['case'],row['adapter'],row['phase'])
            groups[key].append(row)
    results=[]
    for (profile,wait_mode,state,case,adapter,phase),rows in sorted(groups.items()):
        record={'profile':profile,'wait_mode':wait_mode,'state':state,'case':case,'adapter':adapter,'phase':phase,'samples':len(rows),'rows':sorted({r['rows'] for r in rows}),'matches':sorted({r['matches'] for r in rows}),'cursors':sorted({r['cursor'] for r in rows}),'gate_failures':sum(r['wall_us']>2000000 or r.get('sql_us',0)>2000000 for r in rows),'metrics':{}}
        for metric in ['wall_us','sql_us','native_total_us','prepare_us','describe_us','copy_us','marshal_us','queue_us','completion_wait_us','conversion_us','projection_us']:
            if metric=='queue_us' and adapter=='soci' and rows and metric in rows[0] and 'marshal_us' not in rows[0]:
                record['metrics']['submit_to_worker_us']=distribution([r[metric] for r in rows])
                record['metrics'][metric]=None;continue
            values=[r[metric] for r in rows if metric in r]
            record['metrics'][metric]=distribution(values) if values else None
        residual=[max(0,r['wall_us']-r['native_total_us']-r['queue_us']-r.get('marshal_us',0)-r['completion_wait_us']-r['conversion_us']) for r in rows if 'native_total_us' in r]
        record['metrics']['submit_resume_other_us']=distribution(residual) if residual else None
        record['sql_calls']=sorted({r['sql_calls'] for r in rows if 'sql_calls' in r})
        record['native_statement_executions']=sorted({r['profile_executions'] for r in rows if 'profile_executions' in r})
        results.append(record)
    output={'gate_us':2000000,'profiles':profiles,'groups':results,'plans':plans,'interpretation':'sql_us is measured sqlite3_step wall time only; preparation separately where available. Warm=30 samples except measured very slow diagnostic cases=3. Cold=fresh configured reader connection, not OS cache purge. All rows/cursors projected against production MarketSearchSqlite before aggregation.'}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(output,indent=2)+'\n')
    print(f'AUCTION_P0_SUMMARY groups={len(results)} profiles={len(profiles)} output={args.output}')


if __name__=='__main__':main()
