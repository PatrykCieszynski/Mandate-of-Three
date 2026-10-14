"""Prepare isolated pinned sources for P0; never overwrite release v0.4.0.

All source transformations are diagnostic instrumentation in ignored storage.
No addon repository, production API or installed native payload is modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.godot/verification/auction-p0/native'
PINS = {
    'addon': ('PatrykCieszynski/godot-soci', 'a9229e4af0a5420f681c19211de25bf181467fae'),
    'godotcpp': ('godotengine/godot-cpp', 'b8530af7546a3fcae80cef2477526569fd42ffc2'),
    'soci': ('SOCI/soci', 'a9e51707d565baa6e02634453d5e81b84062c94a'),
    'fmt': ('fmtlib/fmt', '407c905e45ad75fc29bf0f9bb7c5c2fd3475976f'),
    'gdsqlite': ('2shady4u/godot-sqlite', '162ffbae0b0c8a933ba63bbb50da6cc0402950f8'),
}


def rewrite(path, old, new):
    text = path.read_text(encoding='utf-8')
    if old not in text:
        raise ValueError('Pinned diagnostic patch no longer matches: ' + str(path))
    path.write_text(text.replace(old, new), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true')
    options = parser.parse_args()
    if not WORK.resolve().is_relative_to(ROOT.resolve() / '.godot/verification'):
        raise ValueError('Unsafe P0 staging directory')
    WORK.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT/'tests/fixtures/auction_p0_sources.json').read_text())
    provenance = {}
    for name, (repo, commit) in PINS.items():
        archive = WORK / (name + '.tar.gz')
        if not archive.exists():
            if not options.download:
                raise ValueError('Run preparation explicitly with --download first')
            url = f'https://api.github.com/repos/{repo}/tarball/{commit}'
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'Mandate-P0'}), timeout=60) as response:
                archive.write_bytes(response.read())
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        if sha != lock[name]['archive_sha256']: raise ValueError('Pinned P0 source archive mismatch: '+name)
        provenance[name] = {'repo':repo, 'commit':commit, 'archive_sha256':sha}
        # Re-extract a clean copy, without deleting any directory or changing a checkout.
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            prefix = members[0].name.split('/')[0]
            for member in members:
                parts = Path(member.name).parts[1:]
                if not parts or not member.isfile():
                    continue
                target = WORK / name / Path(*parts)
                if not target.resolve().is_relative_to(WORK.resolve()):
                    raise ValueError('Unsafe source archive path')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(tar.extractfile(member).read())
    archive = WORK / 'sqlite3534.tar.gz'
    if not archive.exists():
        if not options.download: raise ValueError('SQLite source missing')
        with urllib.request.urlopen('https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz', timeout=60) as response:
            archive.write_bytes(response.read())
    expected = 'c24374e9393a943157f533f96e89e6c5743e5f5aad169d8393cff3088ca5ccbe5cc0561681ace49c349d0fe402298ee2624d319f422967247ce0792e3b3aa01e'
    if hashlib.sha512(archive.read_bytes()).hexdigest() != expected: raise ValueError('Pinned vcpkg SQLite SHA512 mismatch')
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if member.isfile() and Path(member.name).name in ['sqlite3.c','sqlite3.h','sqlite3ext.h']:
                destination = WORK / 'sqlite3534' / Path(member.name).name
                destination.parent.mkdir(exist_ok=True)
                destination.write_bytes(tar.extractfile(member).read())
    provenance['sqlite3534'] = {'version':'3.53.4','vcpkg_commit':'e456309491fd875487bf02b8a0dca76c1b1b00cc','sha512':expected}
    addon = WORK / 'addon'
    header = addon / 'include/godot_soci/query_worker.h'
    rewrite(header, 'bool truncated = false;', 'bool truncated = false;\n    int64_t p0_submitted=0, p0_queued=0, p0_started=0, p0_finished=0, p0_sql_us=0, p0_sql_calls=0, p0_profile_ns=0, p0_profiles=0, p0_prepare_us=0, p0_describe_us=0, p0_copy_us=0;')
    rewrite(header, 'int max_rows = 1000;', 'int max_rows = 1000;\n    int64_t p0_submitted=0, p0_queued=0;')
    for path in [addon/'src/query_dispatcher.cpp', addon/'src/query_worker.cpp']:
        rewrite(path, '#include "godot_soci/', '#include "p0_timing.h"\n\n#include "godot_soci/')
    worker = addon / 'src/query_worker.cpp'
    rewrite(worker, 'result.query = job.query;', 'result.query = job.query;\n    result.p0_submitted=job.p0_submitted; result.p0_queued=job.p0_queued; result.p0_started=p0_now();\n    P0Scope p0_scope(session, result);')
    rewrite(worker, 'statement.prepare(job.sql);', 'auto p0_phase=p0_now();\n        statement.prepare(job.sql); result.p0_prepare_us=p0_now()-p0_phase;')
    rewrite(worker, 'statement.define_and_bind();\n\n        if (job.query)', 'p0_phase=p0_now(); statement.define_and_bind(); result.p0_describe_us=p0_now()-p0_phase;\n\n        if (job.query)')
    rewrite(worker, 'result.rows.push_back(copy_row(record));', 'auto p0_copy=p0_now(); result.rows.push_back(copy_row(record)); result.p0_copy_us+=p0_now()-p0_copy;')
    dispatcher = addon / 'src/query_dispatcher.cpp'
    rewrite(dispatcher, 'job.id = next_id_++;', 'job.id = next_id_++; job.p0_submitted=p0_now();')
    rewrite(dispatcher, 'queue_.push_back(std::move(job));', 'job.p0_queued=p0_now(); queue_.push_back(std::move(job));')
    rewrite(dispatcher, 'result["ok"] = completed.ok;', '''result["p0"] = p0_metrics(completed);
    result["ok"] = completed.ok;''')
    rewrite(dispatcher, 'ready.emplace_back(request, as_dictionary(completed));', '''auto p0_conversion=p0_now();
        Dictionary p0_result=as_dictionary(completed);
        Dictionary p0_info=p0_result["p0"];
        p0_info["conversion_us"]=p0_now()-p0_conversion;
        p0_info["completion_wait_us"]=p0_conversion-completed.p0_finished;
        p0_result["p0"]=p0_info;
        ready.emplace_back(request, p0_result);''')
    # Exact sqlite3_step time, independent of row copying, in the pinned backend.
    backend = WORK/'soci/src/backends/sqlite3/statement.cpp'
    rewrite(backend, '#include', '#include "p0_sql_step.h"\n#include')
    rewrite(backend, 'sqlite3_step(stmt_)', 'p0_sql_step(stmt_)')
    # Diagnostic godot-sqlite class shares precisely the same SQLite library as SOCI.
    for path in (WORK/'gdsqlite/src').rglob('*'):
        if path.suffix in ['.cpp','.hpp']:
            text=path.read_text(); path.write_text(text.replace('SQLite','SQLiteP0'))
    gdheader=WORK/'gdsqlite/src/gdsqlite.hpp'
    rewrite(gdheader, 'bool open_db();', 'Dictionary p0_get_metrics();\n    bool open_db();')
    gdsource=WORK/'gdsqlite/src/gdsqlite.cpp'
    rewrite(gdsource, '#include', '#include "p0_sql_step.h"\n#include')
    rewrite(gdsource, 'void SQLiteP0::_bind_methods() {', 'void SQLiteP0::_bind_methods() {\n    ClassDB::bind_method(D_METHOD("p0_get_metrics"), &SQLiteP0::p0_get_metrics);')
    rewrite(gdsource, 'sqlite3_step(stmt)', 'p0_sql_step(stmt)')
    rewrite(gdsource, 'const char *pzTail;', 'p0_sql_reset();\n\tconst char *pzTail;')
    gdsource.write_text(gdsource.read_text()+'''\nDictionary godot::SQLiteP0::p0_get_metrics() {
    Dictionary d; d["sql_us"]=p0_sql_elapsed; d["sql_calls"]=p0_sql_calls; return d;
}\n''')
    registration=addon/'src/register_types.cpp'
    rewrite(registration, '#include', '#include "gdsqlite.hpp"\n#include')
    # Register after the existing native database so the fixture uses real adapters.
    text=registration.read_text()
    import re
    match=re.search(r'(ClassDB::register_class|GDREGISTER_CLASS).*GodotSociDatabase.*;',text)
    if not match: raise ValueError('Pinned registration pattern not found')
    registration.write_text(text[:match.end()]+'\n    ClassDB::register_class<SQLiteP0>();'+text[match.end():])
    for name in ['CMakeLists.txt','p0_timing.h','p0_sql_step.h','build_profile.json']:
        shutil.copyfile(ROOT/'tests/fixtures/auction_p0_native'/name, WORK/name)
    (WORK/'source-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print('AUCTION_P0_NATIVE_PREPARED '+str(WORK))


if __name__=='__main__': main()
