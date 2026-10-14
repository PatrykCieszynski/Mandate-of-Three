"""Preserve measured timings/plans/provenance before deleting disposable P0 stores."""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'.godot/verification/auction-p0'
OUT=ROOT/'docs/evidence/auction-soci-p0'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    subprocess.run([sys.executable,str(ROOT/'tests/summarize-auction-p0.py')],check=True)
    summary=json.loads((WORK/'summary.json').read_text())
    groups=summary['groups']
    fields=['profile','wait_mode','state','case','adapter','phase','samples','rows','matches','gate_failures']
    metrics=['wall_us','sql_us','native_total_us','prepare_us','describe_us','copy_us','marshal_us','queue_us','completion_wait_us','conversion_us','projection_us','submit_resume_other_us']
    fields += [f'{m}_{p}' for m in metrics for p in ['p50_ms','p95_ms','max_ms']]
    with (OUT/'distributions.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fields);writer.writeheader()
        for g in groups:
            row={k:g[k] for k in fields if k in g}
            for m in metrics:
                for p in ['p50_ms','p95_ms','max_ms']:
                    row[f'{m}_{p}']=(g['metrics'].get(m) or {}).get(p,'')
            writer.writerow(row)
    samples=[];runs=[]
    for file in sorted(WORK.glob('*/raw.json')):
        raw=json.loads(file.read_text())
        if raw.get('probe_only'):continue
        name=file.parent.name
        runs.append({'run':name,'raw_sha256':sha(file),'wait_mode':raw.get('wait_mode','frame'),'gate_us':raw['gate_us'],'failures':raw['failures'],'telemetry':raw['telemetry'],'cold_definition':raw['cold_definition'],'godot':raw['godot']})
        samples.extend({'run':name,'profile':raw['profile'],'wait_mode':raw.get('wait_mode','frame'),**r} for r in raw['records'])
    keys=sorted({k for r in samples for k in r})
    with (OUT/'samples.csv').open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,keys);writer.writeheader();writer.writerows(samples)
    (OUT/'plans.json').write_text(json.dumps(summary['plans'],indent=2)+'\n',encoding='utf-8')
    provenance={'runs':runs,'source_pins':json.loads((WORK/'native/source-provenance.json').read_text()),'variants':{},'link_selection':{},'limits':'Fresh configured connections, no OS cache purge; missing sql_us stays missing. Original historical linker logs unavailable. Invalid /OD compiler samples and probes excluded.'}
    for variant in sorted((WORK/'native/variants').iterdir()):
        config=variant/'configuration.json'
        if not config.exists():continue
        provenance['variants'][variant.name]={'configuration':json.loads(config.read_text()),'dll_sha256':sha(variant/'p0_soci.dll'),'sqlite_library_sha256':sha(variant/'sqlite3.lib')}
    for label in ['before','after']:
        data=json.loads((WORK/'link-audit'/label/'link-selection.json').read_text())
        # Keep the selected relative path, not a workstation-specific absolute path.
        data['imported_location']=data['imported_location'].split('/link-audit/',1)[1]
        provenance['link_selection'][label]=data
    for tag,cache in [('v0.4.0','soci-release'),('v0.4.1','soci-release-041')]:
        provenance[tag]=json.loads((ROOT/'.godot/verification'/cache/'provenance.json').read_text())
    (OUT/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n',encoding='utf-8')
    for name in ['quick-summary.json','wait-mode-comparison.json']:
        (OUT/name).write_bytes((WORK/name).read_bytes())
    for file in WORK.glob('pure-*-broad.csv'):(OUT/file.name).write_bytes(file.read_bytes())
    # Preserve the exact standalone input SQL/bindings and expected ordered IDs.
    for state in ['baseline','lookup']:
        source=WORK/f'diag-353-o2-nodebug-{state}-broad'/(state+'-broad-pure.txt')
        (OUT/(state+'-broad-pure.txt')).write_bytes(source.read_bytes())
    assert len(samples)>0 and any(r['profile']=='release041' and r['wait_mode']=='signal' for r in samples)
    print(f'AUCTION_P0_EVIDENCE samples={len(samples)} groups={len(groups)} runs={len(runs)} destination={OUT}')

if __name__=='__main__':main()
