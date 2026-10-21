"""Offline single-World realm bundle. Requires supervised writers stopped.

Uses libpq environment (PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSFILE etc), never
connection secrets on argv or in the manifest. Restore only trusted bundles:
PostgreSQL archives and Godot resources are executable input, not a safe format
for importing downloads. No server process is stopped or started by this tool.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
HIDDEN = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
FILES = ("economy.dump", "profiles.db", "accounts.tres")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def publish_json(path, value):
    temporary = path.with_suffix(".partial")
    with temporary.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(value, indent=2)+"\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def sync_files(directory, names):
    for name in names:
        # Windows CRT _commit requires a writable descriptor even with no writes.
        with (directory/name).open("r+b") as stream:
            os.fsync(stream.fileno())


class Pg:
    def __init__(self, binaries, env=None):
        self.bin = Path(binaries)
        self.env = dict(os.environ if env is None else env)
        self.env["PGAPPNAME"] = "mandate-offline-bundle"
        self.env["PGCONNECT_TIMEOUT"] = "3"
        self.env["PGCLIENTENCODING"] = "UTF8"

    def command(self, name, args=(), sql=None):
        binary = self.bin / (name + (".exe" if os.name == "nt" else ""))
        result = subprocess.run([str(binary), *map(str, args)], input=sql,
                                capture_output=True, text=True, encoding="utf-8",
                                env=self.env, timeout=180, creationflags=HIDDEN)
        # libpq errors can echo a connection string. Keep raw diagnostics private.
        require(result.returncode == 0, name + " failed; bundle not verified")
        return result.stdout.strip()

    def query(self, sql):
        output = self.command("psql", ["-X", "-w", "-At", "-v", "ON_ERROR_STOP=1"], sql)
        return json.loads(output)

    def idle(self, guard_pid=0):
        require(self.query(f"SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND pid<>{int(guard_pid)};") == 0,
                "Other database sessions exist; stop all writers/readers first")


class Guard:
    """Hold SHARE locks throughout copying/dumping; never terminate another SQL.

    This backs up a stopped realm, not live gameplay: a restarted DB writer is
    blocked and detected, but only the operator/supervisor can freeze account-file
    writers. No claim of a distributed maintenance lease.
    """
    def __init__(self, pg):
        env = dict(pg.env, PGAPPNAME="mandate-offline-guard")
        binary = pg.bin / ("psql.exe" if os.name == "nt" else "psql")
        self.process = subprocess.Popen([str(binary), "-X", "-w", "-Atq", "-v", "ON_ERROR_STOP=1"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, encoding="utf-8",
                                        env=env, creationflags=HIDDEN)
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line.strip())
        self.lines.put(None)

    def execute(self, sql):
        require(self.process.poll() is None, "Backup lock owner stopped")
        self.process.stdin.write(sql + "\nSELECT 'BUNDLE_GUARD_READY';\n")
        self.process.stdin.flush()
        lines = []
        while True:
            line = self.lines.get(timeout=20)
            require(line is not None, "Cannot acquire/retain economy locks")
            if line == "BUNDLE_GUARD_READY":
                return lines
            lines.append(line)

    def __enter__(self):
        try:
            self.execute("SET statement_timeout='10s'; SET lock_timeout='1s'; SET idle_in_transaction_session_timeout=0; BEGIN; DO $$ DECLARE r record; BEGIN FOR r IN SELECT schemaname,tablename FROM pg_tables WHERE schemaname IN ('economy','realm') ORDER BY schemaname,tablename LOOP EXECUTE format('LOCK TABLE %I.%I IN SHARE MODE',r.schemaname,r.tablename); END LOOP; END $$;")
            self.pid = int(self.execute("SELECT pg_backend_pid();")[0])
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        if self.process.poll() is None:
            try:
                self.process.stdin.write("ROLLBACK;\n\\q\n"); self.process.stdin.flush()
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill(); self.process.wait(timeout=5)
        self.process.stdin.close(); self.process.stdout.close()


def inspect(pg, profile=None, accounts=None, godot=None):
    """Exact per-table content fingerprints include receipts, custody and money.

    Offline audit only: sorting/aggregation is deliberately not a runtime query.
    Sequences are included separately because they are not table rows.
    """
    tables = pg.query("SELECT coalesce(json_agg(tablename ORDER BY tablename),'[]') FROM pg_tables WHERE schemaname='economy';")
    require(tables, "Missing economy schema")
    fingerprints = {}
    for table in tables:
        require(re.fullmatch(r"[a-z_]+", table), "Unexpected economy relation")
        fingerprints[table] = pg.query(f"SELECT json_build_object('count',count(*),'md5',md5(coalesce(string_agg(row_to_json(t)::text,E'\\n' ORDER BY row_to_json(t)::text),''))) FROM economy.{table} t;")
    native = profile is None
    if native:
        realm_tables = pg.query("SELECT coalesce(json_agg(tablename ORDER BY tablename),'[]') FROM pg_tables WHERE schemaname='realm';")
        require(realm_tables, "Missing PostgreSQL realm state")
        for table in realm_tables:
            require(re.fullmatch(r"[a-z_]+", table), "Unexpected realm relation")
            fingerprints["realm."+table] = pg.query(f"SELECT json_build_object('count',count(*),'md5',md5(coalesce(string_agg(row_to_json(t)::text,E'\\n' ORDER BY row_to_json(t)::text),''))) FROM realm.{table} t;")
    meta = pg.query("SELECT json_object_agg(key,value) FROM economy.meta;")
    authority, identity = meta.get("economy_authority_id", ""), meta.get("world_profile_id", "")
    require(all(re.fullmatch(r"[0-9a-f]{32}", value) for value in (authority, identity)), "Missing realm/profile identity")
    require(pg.query("SELECT count(*) FROM economy.inventory_sessions WHERE phase<>'revoked';") == 0,
            "Live session grants remain; finish maintenance first")
    require(pg.query("SELECT count(*) FROM economy.inventory_intents WHERE state='pending';") == 0,
            "Pending inventory work remains")
    require(pg.query("SELECT count(*) FROM economy.item_instances i LEFT JOIN economy.item_custody c USING(uid) WHERE c.uid IS NULL;") == 0,
            "Item without durable custody")
    require(pg.query("SELECT count(*) FROM economy.account_wallets w WHERE w.reserved_yang<>coalesce((SELECT sum(o.reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=w.account_id AND o.side='buy' AND o.status='active'),0);") == 0,
            "Yang reservations do not match active orders")
    require(pg.query("SELECT count(*) FROM economy.exchange_assets a WHERE a.reserved<>coalesce((SELECT sum(o.reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=a.account_id AND o.base_asset=a.asset_id AND o.side='sell' AND o.status='active'),0);") == 0,
            "Asset reservations do not match active orders")
    mappings = pg.query("SELECT coalesce(json_object_agg(character_id::text,account_id),'{}') FROM economy.characters;")
    if native:
        rows = pg.query("SELECT coalesce(json_agg(json_build_array(p.player_id,a.account_name,a.master_account_id)),'[]') FROM realm.players p JOIN realm.accounts a USING(account_name);")
        profile_accounts = pg.query("SELECT coalesce(json_agg(json_build_array(account_name,master_account_id)),'[]') FROM realm.accounts;")
        master_ids = dict(profile_accounts)
    else:
        return inspect_legacy(pg, profile, accounts, godot, fingerprints, authority, identity, mappings)
    return finish_inspection(pg, rows, profile_accounts, master_ids, mappings, fingerprints, authority, identity, native=True)


def inspect_legacy(pg, profile, accounts, godot, fingerprints, authority, identity, mappings):
    with closing(sqlite3.connect(profile.as_uri() + "?mode=ro", uri=True)) as db:
        require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "Profile integrity check failed")
        require(db.execute("SELECT value FROM meta WHERE key='pg_profile_id'").fetchone() == (identity,), "Profile identity mismatch")
        for table in ("account_wallets", "item_instances"):
            exists = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
            require(not exists or db.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == 0, "Legacy economic data in profile file")
        rows = db.execute("SELECT p.player_id,a.account_name,a.master_account_id FROM players p LEFT JOIN accounts a ON p.account_name=a.account_name").fetchall()
        profile_accounts = db.execute("SELECT account_name,master_account_id FROM accounts").fetchall()
    # Let Godot decode its own trusted resource format; no regex parsing of TRES.
    with tempfile.TemporaryDirectory(prefix="mandate-account-audit-") as temporary:
        output = Path(temporary) / "identities.json"
        result = subprocess.run([str(godot), "--headless", "--path", str(ROOT), "--script",
                                 "res://tools/postgres/account_manifest.gd", "--", str(accounts), str(output)],
                                capture_output=True, timeout=30, creationflags=HIDDEN)
        require(result.returncode == 0 and output.is_file() and b"SCRIPT ERROR" not in result.stderr, "Master account resource validation failed")
        master_ids = json.loads(output.read_text(encoding="utf-8"))
    return finish_inspection(pg, rows, profile_accounts, master_ids, mappings, fingerprints, authority, identity)


def finish_inspection(pg, rows, profile_accounts, master_ids, mappings, fingerprints, authority, identity, native=False):
    require(all(isinstance(account, int) and account > 0 and master_ids.get(name) == account for name, account in profile_accounts), "Master/profile account mismatch")
    require(all(isinstance(account, int) and account > 0 and master_ids.get(name) == account and mappings.get(str(character)) == account for character, name, account in rows), "PostgreSQL/profile character mismatch")
    if native:
        sequences = pg.query("SELECT coalesce(json_agg(json_build_array(schemaname,sequencename,last_value) ORDER BY schemaname,sequencename),'[]') FROM pg_sequences WHERE schemaname IN ('economy','realm');")
    else:
        sequences = pg.query("SELECT coalesce(json_agg(json_build_array(sequencename,last_value) ORDER BY sequencename),'[]') FROM pg_sequences WHERE schemaname='economy';")
    return {"authority_id": authority, "profile_id": identity, "tables": fingerprints,
            "sequences": sequences, "profiles": len(rows), "master_accounts": len(master_ids),
            "schema_versions": pg.query("SELECT json_object_agg(feature,version) FROM economy.schema_versions;")}


def create_full(pg, destination):
    """Format 2: credentials, profiles, economic state and sequences in one archive."""
    require(not destination.exists(), "Bundle destination already exists")
    pg.idle()
    destination.mkdir(parents=False, mode=0o700)
    with Guard(pg) as guard:
        audit = inspect(pg)
        pg.command("pg_dump", ["-w", "--format=custom", "--schema=economy", "--schema=realm", "--no-owner", "--no-privileges", "--lock-wait-timeout=3s", "--file", destination/"realm.dump"])
        guard.execute("SELECT 1;")
        pg.idle(guard.pid)
        require(inspect(pg) == audit, "Realm changed during capture")
        sync_files(destination, ("realm.dump",))
        manifest = {"format": 2, "complete": True, "created_unix": int(time.time()),
                    "precondition": "supervised writers stopped; no automatic restart",
                    "audit": audit, "sha256": {"realm.dump": digest(destination/"realm.dump")}}
        publish_json(destination/"manifest.json", manifest)
    return manifest


def restore_full(pg, bundle, destination):
    require(not destination.exists(), "Restore directory already exists")
    manifest = json.loads((bundle/"manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("format") == 2 and manifest.get("complete") is True, "Incomplete/unsupported bundle")
    require(set(manifest.get("sha256", {})) == {"realm.dump"}, "Bundle file list mismatch")
    require(digest(bundle/"realm.dump") == manifest["sha256"]["realm.dump"], "Bundle checksum mismatch")
    pg.idle()
    require(pg.query("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S','f');") == 0,
            "Restore requires an empty, separately created database")
    database = pg.env.get("PGDATABASE", "")
    require(re.fullmatch(r"[a-zA-Z_][a-zA-Z_0-9]*", database), "PGDATABASE must be a plain database name")
    destination.mkdir(parents=False, mode=0o700)
    pg.command("pg_restore", ["-w", "--exit-on-error", "--single-transaction", "--no-owner", "--no-privileges", "-d", database, bundle/"realm.dump"])
    with Guard(pg) as guard:
        audit = inspect(pg)
        require(audit == manifest["audit"], "Restored data differs from the captured audit")
        pg.idle(guard.pid)
    publish_json(destination/"RESTORE_VERIFIED.json", {"format": 2, "audit": audit})
    return audit


def create(pg, profiles, accounts, destination, godot):
    profiles, accounts = profiles.resolve(), accounts.resolve()
    require(profiles.is_file() and accounts.is_file(), "Missing profile/account file")
    require(not destination.exists(), "Bundle destination already exists")
    pg.idle()
    destination.mkdir(parents=False, mode=0o700)
    # No COMPLETE manifest is produced on any failed/partial backup.
    with Guard(pg) as guard, closing(sqlite3.connect(profiles.as_uri()+"?mode=rw", uri=True, timeout=1)) as db:
        db.execute("PRAGMA locking_mode=EXCLUSIVE")
        db.execute("BEGIN EXCLUSIVE")
        require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "Profile integrity failed")
        account_hash = digest(accounts)
        # SQLite serialization includes committed WAL, not an unchecked DB copy.
        # A second read connection cannot read our exclusive lock, so serialize the
        # locked connection's committed image (BEGIN EXCLUSIVE made no changes).
        (destination / "profiles.db").write_bytes(db.serialize())
        shutil.copyfile(accounts, destination / "accounts.tres")
        audit = inspect(pg, destination / "profiles.db", destination / "accounts.tres", godot)
        pg.command("pg_dump", ["-w", "--format=custom", "--schema=economy", "--no-owner", "--no-privileges", "--lock-wait-timeout=3s", "--file", destination / "economy.dump"])
        guard.execute("SELECT 1;")
        pg.idle(guard.pid)
        require(digest(accounts) == account_hash == digest(destination / "accounts.tres"), "Account file changed during capture")
        db.rollback()
        manifest = {"format": 1, "complete": True, "created_unix": int(time.time()),
                    "precondition": "supervised writers stopped; no automatic restart",
                    "audit": audit, "sha256": {name: digest(destination/name) for name in FILES},
                    "postgres": pg.command("pg_dump", ["--version"]),
                    "source_commit": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip(),
                    "soci": json.loads((ROOT/"tools/soci/release.json").read_text(encoding="utf-8"))["tag"]}
        sync_files(destination, FILES)
        publish_json(destination / "manifest.json", manifest)
    return manifest


def restore(pg, bundle, destination, godot):
    require(not destination.exists(), "Restore directory already exists")
    manifest = json.loads((bundle/"manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("format") == 1 and manifest.get("complete") is True, "Incomplete/unsupported bundle")
    require(set(manifest.get("sha256", {})) == set(FILES), "Bundle file list mismatch")
    for name in FILES:
        require(digest(bundle/name) == manifest["sha256"][name], "Bundle checksum mismatch")
    pg.idle()
    require(pg.query("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S','f');") == 0,
            "Restore requires an empty, separately created database")
    require(pg.query("SELECT count(*) FROM pg_namespace WHERE nspname='economy';") == 0, "Economy schema already exists")
    destination.mkdir(parents=False, mode=0o700)
    # A trusted custom archive is restored in one transaction. No --clean/drop.
    database = pg.env.get("PGDATABASE", "")
    require(re.fullmatch(r"[a-zA-Z_][a-zA-Z_0-9]*", database), "PGDATABASE must be a plain database name, not a connection string")
    pg.command("pg_restore", ["-w", "--exit-on-error", "--single-transaction", "--no-owner", "--no-privileges", "-d", database, bundle/"economy.dump"])
    for name in ("profiles.db", "accounts.tres"):
        shutil.copyfile(bundle/name, destination/name)
        require(digest(destination/name) == manifest["sha256"][name], "Restored file checksum mismatch")
    with Guard(pg) as guard:
        audit = inspect(pg, destination/"profiles.db", destination/"accounts.tres", godot)
        require(audit == manifest["audit"], "Restored data differs from the captured audit")
        pg.idle(guard.pid)
    sync_files(destination, ("profiles.db", "accounts.tres"))
    publish_json(destination/"RESTORE_VERIFIED.json", {"format": 1, "audit": audit})
    return audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("backup", "restore"))
    parser.add_argument("--pg-bin", type=Path, required=True)
    parser.add_argument("--godot", type=Path, default=ROOT/".godot/Godot_v4.7.2-stable_win64_console.exe")
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profiles", type=Path)
    parser.add_argument("--accounts", type=Path)
    parser.add_argument("--writers-stopped", action="store_true", help="Operator confirms all supervisors/automatic restarts are disabled and realm writers stopped")
    parser.add_argument("--full-state", action="store_true", help="All-PostgreSQL realm; no SQLite profile or Master resource files")
    args = parser.parse_args()
    require(args.writers_stopped, "Explicit stopped-writer precondition required")
    pg = Pg(args.pg_bin)
    if args.action == "backup":
        if args.full_state:
            create_full(pg, args.bundle.resolve())
            print("REALM_BACKUP_VERIFIED format=2")
            return
        require(args.profiles is not None and args.accounts is not None, "Provide profile and account files")
        create(pg, args.profiles, args.accounts, args.bundle.resolve(), args.godot.resolve())
    else:
        require(args.output is not None, "Provide new restore output directory")
        if args.full_state:
            restore_full(pg, args.bundle.resolve(), args.output.resolve())
        else:
            restore(pg, args.bundle.resolve(), args.output.resolve(), args.godot.resolve())
    print("REALM_" + args.action.upper() + "_VERIFIED")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        # Only our fixed, non-secret admission/verification messages reach here.
        raise SystemExit(str(error)) from None
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError, queue.Empty):
        # Do not echo libpq configuration, SQL, credentials or account resources.
        raise SystemExit("Realm bundle operation failed; no verified success. Preserve partial output for private diagnosis.")
