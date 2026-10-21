"""Called only by the owned native-process fixture, never on real data."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("realm_backup", ROOT/"tools/postgres/realm_backup.py")
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


def refused(function):
    try:
        function()
    except RuntimeError:
        return
    raise AssertionError("unsafe operation accepted")


def main():
    assert os.environ.get("MANDATE_PG_FIXTURE") == "owned-local-cluster"
    directory = (ROOT/os.environ["MANDATE_PG_FIXTURE_DIR"].removeprefix("res://")).resolve()
    assert directory.is_relative_to((ROOT/".godot/verification/postgres-readiness").resolve())
    pg = backup.Pg(os.environ["MANDATE_PG_FIXTURE_BIN"])
    if os.environ.get("MANDATE_PG_FULL_STATE") == "1":
        full_state(pg, directory)
        return
    godot = Path(os.environ["MANDATE_PG_FIXTURE_GODOT"])
    profiles, accounts = directory/"profiles.db", directory/"accounts.tres"
    bundle, output = directory/"bundle", directory/"restored"
    with backup.Guard(pg):
        refused(lambda: backup.create(pg, profiles, accounts, directory/"active-refused", godot))
    assert not (directory/"active-refused").exists()
    # Refuse live grants without silently revoking them in an offline tool.
    pg.command("psql", ["-X", "-w", "-v", "ON_ERROR_STOP=1"], "UPDATE economy.inventory_sessions SET phase='ready';")
    refused(lambda: backup.create(pg, profiles, accounts, directory/"grants-refused", godot))
    assert not (directory/"grants-refused/manifest.json").exists()
    pg.command("psql", ["-X", "-w", "-v", "ON_ERROR_STOP=1"], "UPDATE economy.inventory_sessions SET phase='revoked';")
    # Representative persistent values outside the real client's inventory.
    # Earlier contract suites prove these domain rules; this fixture proves the
    # bundle preserves nonempty revenue, reservation, fill and sequence state.
    pg.command("psql", ["-X", "-w", "-v", "ON_ERROR_STOP=1"], """
BEGIN;
INSERT INTO economy.accounts VALUES(901);
INSERT INTO economy.account_wallets(account_id,yang) VALUES(901,1510);
UPDATE economy.account_wallets SET yang=1560,reserved_yang=90,wallet_revision=wallet_revision+1 WHERE account_id=900;
INSERT INTO economy.account_shop_revenue VALUES(900,12345);
INSERT INTO economy.exchange_books VALUES('upgrade_ore');
INSERT INTO economy.exchange_assets VALUES(900,'upgrade_ore',1,0),(901,'upgrade_ore',99,0);
INSERT INTO economy.exchange_orders(order_id,account_id,base_asset,quote_asset,side,quantity,remaining,price_num,price_den,reserved_amount,received,status)
VALUES(repeat('a',32),900,'upgrade_ore','yang','buy',10,9,10,1,90,1,'active'),
      (repeat('b',32),901,'upgrade_ore','yang','sell',1,0,10,1,0,10,'filled');
INSERT INTO economy.exchange_fills(maker_id,taker_id,base_quantity,yang_amount) VALUES(repeat('a',32),repeat('b',32),1,10);
COMMIT;
""")
    # Corrupt profile identity and verify failure, then use the actual good file.
    wrong = directory/"wrong-profile.db"
    shutil.copyfile(profiles, wrong)
    with sqlite3.connect(wrong) as db:
        db.execute("UPDATE meta SET value=? WHERE key='pg_profile_id'", ("0"*32,))
    db.close()
    refused(lambda: backup.create(pg, wrong, accounts, directory/"profile-refused", godot))
    wrong_accounts = directory/"wrong-accounts.tres"
    wrong_accounts.write_text(accounts.read_text(encoding="utf-8").replace("processfixture", "otheraccount"), encoding="utf-8")
    refused(lambda: backup.create(pg, profiles, wrong_accounts, directory/"accounts-refused", godot))
    db = sqlite3.connect(profiles)
    prior_xp = db.execute("SELECT experience FROM players").fetchone()[0]
    db.close()
    # Leave committed SQLite WAL behind as a crashed writer would. No active
    # process/connection remains, and capture must include those committed bytes.
    subprocess.run([sys.executable, "-c", "import sqlite3,os,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA wal_autocheckpoint=0'); c.execute('UPDATE players SET experience=experience+11'); c.commit(); os._exit(0)", str(profiles)],
                   check=True, creationflags=backup.HIDDEN)
    assert Path(str(profiles)+"-wal").is_file()
    manifest = backup.create(pg, profiles, accounts, bundle, godot)
    refused(lambda: backup.create(pg, profiles, accounts, bundle, godot))
    refused(lambda: backup.restore(pg, bundle, output, godot))  # populated source!
    assert not output.exists()
    # Change one byte, not the manifest, and prove verification occurs before SQL.
    bad = directory/"bad-bundle"
    shutil.copytree(bundle, bad)
    with (bad/"economy.dump").open("ab") as stream:
        stream.write(b"tampered")
    refused(lambda: backup.restore(pg, bad, output, godot))
    assert not output.exists()
    admin = backup.Pg(pg.bin, dict(pg.env, PGDATABASE="postgres"))
    admin.command("psql", ["-X", "-w", "-v", "ON_ERROR_STOP=1"], "CREATE DATABASE mandate_restored;")
    target = backup.Pg(pg.bin, dict(pg.env, PGDATABASE="mandate_restored"))
    audit = backup.restore(target, bundle, output, godot)
    assert audit == manifest["audit"]
    refused(lambda: backup.restore(target, bundle, output, godot))
    assert audit["tables"]["item_instances"]["count"] == 2
    assert audit["tables"]["market_commands"]["count"] > 0
    assert audit["tables"]["exchange_fills"]["count"] == 1
    assert audit["tables"]["account_shop_revenue"]["count"] == 1
    db = sqlite3.connect(output/"profiles.db")
    assert db.execute("SELECT experience FROM players").fetchone()[0] == prior_xp + 11
    db.close()
    assert target.query("SELECT reserved_yang FROM economy.account_wallets WHERE account_id=900;") == 90
    assert target.query("SELECT yang FROM economy.account_shop_revenue WHERE account_id=900;") == 12345
    # Sequence next values also remain safe after restore (no reused fill ID).
    assert target.query("SELECT nextval('economy.exchange_fills_fill_id_seq');") == 2
    print("POSTGRES_BACKUP_FILES_OK: exact table/sequence audit, identity, checksums, live-grant/session refusal and empty-target restore")


def full_state(pg, directory):
    bundle, output = directory/"full-bundle", directory/"full-restored"
    with backup.Guard(pg):
        refused(lambda: backup.create_full(pg, directory/"active-refused"))
    manifest = backup.create_full(pg, bundle)
    assert manifest["audit"]["tables"]["realm.accounts"]["count"] == 1
    assert manifest["audit"]["tables"]["realm.players"]["count"] == 1
    assert manifest["audit"]["tables"]["item_instances"]["count"] == 2
    refused(lambda: backup.restore_full(pg, bundle, output))
    assert not output.exists()
    bad = directory/"bad-full-bundle"
    shutil.copytree(bundle, bad)
    with (bad/"realm.dump").open("ab") as stream:
        stream.write(b"tampered")
    refused(lambda: backup.restore_full(pg, bad, output))
    assert not output.exists()
    admin = backup.Pg(pg.bin, dict(pg.env, PGDATABASE="postgres"))
    admin.command("psql", ["-X", "-w", "-v", "ON_ERROR_STOP=1"], "CREATE DATABASE mandate_restored;")
    target = backup.Pg(pg.bin, dict(pg.env, PGDATABASE="mandate_restored"))
    assert backup.restore_full(target, bundle, output) == manifest["audit"]
    assert target.query("SELECT experience FROM realm.players;") == 41
    assert target.query("SELECT nextval('realm.account_ids');") > target.query("SELECT max(master_account_id) FROM realm.accounts;")
    assert target.query("SELECT nextval('realm.player_ids');") > target.query("SELECT max(player_id) FROM realm.players;")
    print("POSTGRES_FULL_BACKUP_OK: all-state archive, exact fingerprints/sequence restore, tamper/populated-target/live-session refusal")


if __name__ == "__main__":
    main()
