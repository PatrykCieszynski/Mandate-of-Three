"""Inventory production GDScript SQL call sites; no database is opened.

This is a conservative source inventory, not a SQL transpiler/parser. Expressions
and dynamic SQL remain verbatim. The companion disposable Godot fixture captures
the resulting schema, including SQL assembled by loops or table helpers.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CALL = re.compile(r"(?<=\.)\b(?:query_with_bindings|query|create_table|insert_row|insert_rows|select_rows|update_rows|delete_rows|drop_table|query_async|execute_async|transaction_async|execute)\s*\(")
DYNAMIC = re.compile(r'''(?<=\.)call\s*\(\s*["'](?:query_async|execute_async|transaction_async|query|execute)["']''')
FEATURES = {
    "sqlite_transaction": r"BEGIN\s+IMMEDIATE|\b(?:PRAGMA|WAL|VACUUM)\b",
    "sqlite_catalog": r"sqlite_master|sqlite_schema|table_info|index_info|schema_version",
    "sqlite_upsert": r"INSERT\s+OR\s+(?:IGNORE|REPLACE)",
    "sqlite_row_identity": r"last_insert_rowid|AUTOINCREMENT|last_insert_row_id|ROWID",
    "sqlite_types": r"typeof\s*\(|\bBLOB\b",
    "json_sql": r"\bjson_(?:extract|each|valid|type|array_length)\b",
    "triggers_views": r"\bTRIGGER\b|\bVIEW\b|RAISE\s*\(",
    "conflict_constraints": r"ON\s+CONFLICT|CREATE\s+UNIQUE|CHECK\s*\(|FOREIGN\s+KEY|REFERENCES\s+",
}


def mask_literals(source):
    """Keep offsets/newlines, hide GDScript comments and quoted string contents."""
    masked = list(source)
    literals = []
    index = 0
    while index < len(source):
        start = index
        if source[index] == "#":
            end = source.find("\n", index)
            index = len(source) if end == -1 else end
        elif source[index] in "\"'":
            quote = source[index]
            delimiter = quote * 3 if source.startswith(quote * 3, index) else quote
            index += len(delimiter)
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                else:
                    index += 1
            content = source[start + len(delimiter):index - len(delimiter)]
            if re.match(r"\s*(?:SELECT|INSERT|CREATE|ALTER|DROP|DELETE|UPDATE|REPLACE|PRAGMA|BEGIN|COMMIT|ROLLBACK|VACUUM|WITH|EXPLAIN)\b", content, re.I):
                literals.append({"line": source.count("\n", 0, start) + 1,
                                 "source": source[start:index]})
        else:
            index += 1
            continue
        for offset in range(start, min(index, len(source))):
            if masked[offset] != "\n":
                masked[offset] = " "
    return "".join(masked), literals


def inventory():
    files = []
    for path in sorted((ROOT / "source").rglob("*.gd")):
        source = path.read_text(encoding="utf-8-sig")
        if not re.search(r"\bSQLite\b|\bGodotSociDatabase\b|\bSociQueryDispatcher\b|\.db\b|\.query_with_bindings\b|\.select_rows\b|\.create_table\b", source):
            continue
        code, literals = mask_literals(source)
        calls = []
        matches = list(CALL.finditer(code))
        matches += [match for match in DYNAMIC.finditer(source)
                    if code[match.start():].startswith("call")]
        for match in sorted(matches, key=lambda value: value.start()):
            # Include dynamic expressions. Query methods outside persistence may
            # be orchestration; report those too, rather than silently omit them.
            depth, end = 1, code.find("(", match.start()) + 1
            while depth and end < len(code):
                depth += (code[end] == "(") - (code[end] == ")")
                end += 1
            expression = source[match.start():end]
            calls.append({"line": source.count("\n", 0, match.start()) + 1,
                          "api": match.group().split("(")[0].strip(),
                          "expression": expression})
        flags = {name: [n for n, line in enumerate(source.splitlines(), 1)
                        if re.search(pattern, line, re.I)]
                 for name, pattern in FEATURES.items()}
        flags = {name: lines for name, lines in flags.items() if lines}
        if calls or literals:
            files.append({"path": path.relative_to(ROOT).as_posix(),
                          "calls": calls, "sql_looking_literals": literals,
                          "dialect_and_schema_references": flags})
    return {"format": 1,
            "scope": "source/**/*.gd with SQLite/native SOCI/db references; candidate call expressions, SQL-looking literals and lexical feature references, not emitted SQL or full semantic analysis",
            "files": files,
            "counts": {"files": len(files), "call_sites": sum(len(f["calls"]) for f in files),
                       "sql_looking_literals": sum(len(f["sql_looking_literals"]) for f in files)}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".godot/verification/postgres-readiness/sqlite-source-inventory.json")
    args = parser.parse_args()
    report = inventory()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("SQL_SOURCE_INVENTORY_OK", report["counts"])
