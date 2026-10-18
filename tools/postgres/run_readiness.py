"""Run Godot/SOCI against a fresh owned loopback PostgreSQL cluster (opt-in).

No external DSN, existing data directory or system service is accepted. Binaries
are supplied via --pg-bin or tools/postgres/setup.py. No production code imports
this runner. Retain logs/audits, remove only the verified owned cluster on exit.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / ".godot/verification/postgres-readiness"
HIDDEN = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def run(args, *, env=None, log, timeout=45, sql=None):
    with log.open("ab") as output:
        with subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env,
                              stdin=subprocess.PIPE if sql is not None else subprocess.DEVNULL,
                              stdout=output, stderr=subprocess.STDOUT,
                              creationflags=HIDDEN) as process:
            try:
                process.communicate(None if sql is None else sql.encode("utf-8"), timeout=timeout)
            except subprocess.TimeoutExpired:
                # The console Godot launcher may own a GUI executable child.
                # Kill only this fixture's process tree, never by executable name.
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                   stdout=output, stderr=subprocess.STDOUT,
                                   timeout=10, creationflags=HIDDEN)
                else:
                    process.kill()
                process.wait(timeout=10)
                raise RuntimeError(f"{Path(args[0]).name} timed out; see {log.relative_to(ROOT)}")
            if process.returncode:
                raise RuntimeError(f"{Path(args[0]).name} failed ({process.returncode}); see {log.relative_to(ROOT)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, default=ROOT / ".godot/plugin-cache/postgresql-18.6/pgsql/bin")
    parser.add_argument("--godot", type=Path, default=ROOT / ".godot/Godot_v4.7.2-stable_win64_console.exe")
    parser.add_argument("--suite", choices=("readiness", "wallet", "commit-failure", "npc-shop", "inventory", "storage", "upgrade", "shop-seller", "shop-settlement", "account-claims", "auction-search", "exchange-ledger", "exchange-orders", "wallet-concurrency", "inventory-concurrency", "inventory-executor", "inventory-intents", "inventory-sessions", "inventory-runtime", "inventory-session-bridge", "inventory-endpoint"), default="readiness")
    args = parser.parse_args()
    extension = ".exe" if os.name == "nt" else ""
    binaries = {name: args.pg_bin.resolve() / (name + extension)
                for name in ("initdb", "pg_ctl", "psql")}
    if not args.godot.is_file() or not all(path.is_file() for path in binaries.values()):
        raise RuntimeError("Godot/PostgreSQL binaries missing; use --pg-bin and install the pinned SOCI payload")
    run_check = subprocess.run([sys.executable, str(ROOT / "tools/soci/setup.py"), "--check"],
                               cwd=ROOT, capture_output=True, creationflags=HIDDEN)
    if run_check.returncode:
        raise RuntimeError("Pinned SOCI missing/modified; run python tools/soci/setup.py")
    if not VERIFY.resolve().is_relative_to(ROOT.resolve()):
        raise RuntimeError("Refusing redirected fixture root outside the workspace")
    VERIFY.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="run-", dir=VERIFY)).resolve()
    data = directory / "data"
    if not directory.is_relative_to(VERIFY.resolve()) or data.exists():
        raise RuntimeError("Refusing non-owned data directory")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    password = secrets.token_hex(24)
    password_file = directory / "bootstrap-password"
    password_file.write_text(password, encoding="utf-8")
    # Ambient libpq service/hostaddr/options must never redirect a local fixture.
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("PG")}
    env["APPDATA"] = str(directory / "appdata")
    env["LOCALAPPDATA"] = str(directory / "localappdata")
    env["PGPASSWORD"] = password
    control_log = directory / "control.log"
    summary = {"result": "FAIL", "cluster": "owned disposable loopback", "port": port,
               "soci": json.loads((ROOT / "tools/soci/release.json").read_text(encoding="utf-8"))["tag"],
               "suite": args.suite, "started_at_unix": int(time.time())}
    initialized = False
    try:
        run([binaries["initdb"], "-D", data, "-U", "mandate_bootstrap", "--encoding=UTF8",
             "--locale=C", "--auth-host=scram-sha-256", "--auth-local=scram-sha-256",
             "--pwfile", password_file], log=control_log)
        initialized = True
        password_file.unlink()
        options = f"-h 127.0.0.1 -p {port} -c max_connections=12 -c statement_timeout=1000 -c lock_timeout=750 -c idle_in_transaction_session_timeout=2000 -c log_min_error_statement=panic"
        run([binaries["pg_ctl"], "-D", data, "-l", directory / "postgres.log", "-o", options,
             "-w", "-t", "15", "start"], log=control_log)
        psql = [binaries["psql"], "-X", "-h", "127.0.0.1", "-p", str(port), "-U",
                "mandate_bootstrap", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        # Generated credentials exist only in subprocess memory/ignored fixture.
        # SQL is not interpolated from player content; token_hex has no quotes.
        run(psql, env=env, log=control_log, sql=f"CREATE ROLE mandate_fixture LOGIN PASSWORD '{password}';")
        run(psql + ["-c", "CREATE DATABASE mandate_readiness OWNER mandate_fixture;"], env=env, log=control_log)
        env["MANDATE_PG_FIXTURE"] = "owned-local-cluster"
        env["MANDATE_PG_FIXTURE_DIR"] = "res://" + directory.relative_to(ROOT).as_posix()
        env["MANDATE_PG_FIXTURE_CONNECTION"] = f"host=127.0.0.1 port={port} dbname=mandate_readiness user=mandate_fixture password={password} connect_timeout=3"
        scene, marker = {
            "readiness": ("postgres_readiness", "POSTGRES_READINESS_OK"),
            "wallet": ("postgres_wallet", "POSTGRES_WALLET_OK"),
            "commit-failure": ("postgres_commit_failure", "POSTGRES_COMMIT_FAILURE_OK"),
            "npc-shop": ("postgres_npc_shop", "POSTGRES_NPC_SHOP_OK"),
            "inventory": ("postgres_inventory", "POSTGRES_INVENTORY_OK"),
            "storage": ("postgres_storage", "POSTGRES_STORAGE_OK"),
            "upgrade": ("postgres_upgrade", "POSTGRES_UPGRADE_OK"),
            "shop-seller": ("postgres_shop_seller", "POSTGRES_SHOP_SELLER_OK"),
            "shop-settlement": ("postgres_shop_settlement", "POSTGRES_SHOP_SETTLEMENT_OK"),
            "account-claims": ("postgres_account_claims", "POSTGRES_ACCOUNT_CLAIMS_OK"),
            "auction-search": ("postgres_auction_search", "POSTGRES_AUCTION_SEARCH_OK"),
            "exchange-ledger": ("postgres_exchange_ledger", "POSTGRES_EXCHANGE_LEDGER_OK"),
            "exchange-orders": ("postgres_exchange_orders", "POSTGRES_EXCHANGE_ORDERS_OK"),
            "wallet-concurrency": ("postgres_wallet_concurrency", "POSTGRES_WALLET_CONCURRENCY_OK"),
            "inventory-concurrency": ("postgres_inventory_concurrency", "POSTGRES_INVENTORY_CONCURRENCY_OK"),
            "inventory-executor": ("postgres_inventory_executor", "POSTGRES_INVENTORY_EXECUTOR_OK"),
            "inventory-intents": ("postgres_inventory_intents", "POSTGRES_INVENTORY_INTENTS_OK"),
            "inventory-sessions": ("postgres_inventory_sessions", "POSTGRES_INVENTORY_SESSIONS_OK"),
            "inventory-runtime": ("postgres_inventory_runtime", "POSTGRES_INVENTORY_RUNTIME_OK"),
            "inventory-session-bridge": ("postgres_inventory_session_bridge", "POSTGRES_INVENTORY_SESSION_BRIDGE_OK"),
            "inventory-endpoint": ("postgres_inventory_endpoint", "POSTGRES_INVENTORY_ENDPOINT_OK"),
        }[args.suite]
        run([args.godot, "--headless", "--path", ROOT, "--mode=world-server",
             f"res://tests/{scene}.tscn"] + ([] if args.suite == "inventory-endpoint" else ["--quit-after", "1200"]),
            env=env, log=directory / "godot.log", timeout=60)
        output = (directory / "godot.log").read_text(encoding="utf-8", errors="replace")
        if marker not in output or any(word in output for word in ("SCRIPT ERROR", "Parse Error", "POSTGRES_READINESS_FAILED")):
            raise RuntimeError("Godot readiness contract failed; see " + str(directory.relative_to(ROOT) / "godot.log"))
        if args.suite == "inventory-endpoint":
            for role in ("actor", "observer", "restored"):
                client_output = (directory / f"client-{role}.log").read_text(encoding="utf-8", errors="replace")
                if "POSTGRES_INVENTORY_ENDPOINT_CLIENT_OK" not in client_output or any(word in client_output for word in ("SCRIPT ERROR", "Parse Error")):
                    raise RuntimeError(f"Native client {role} failed; see {directory.relative_to(ROOT)}")
        summary["result"] = "PASS"
    finally:
        password_file.unlink(missing_ok=True)
        stopped = not initialized
        if initialized:
            # Address only this freshly initialized data directory, even if start
            # returned an error after spawning the server. Never target by port.
            status = subprocess.run([str(binaries["pg_ctl"]), "-D", str(data), "status"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    creationflags=HIDDEN, timeout=10)
            stopped = status.returncode == 3
            if status.returncode == 0:
                run([binaries["pg_ctl"], "-D", data, "-m", "fast", "-w", "-t", "15", "stop"], log=control_log)
                stopped = True
        summary["stopped"] = stopped
        (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        if stopped and data.exists():
            resolved = data.resolve()
            if resolved != directory / "data" or not resolved.is_relative_to(VERIFY.resolve()) or not resolved.is_relative_to(ROOT.resolve()):
                raise RuntimeError("Refusing unsafe cleanup path")
            shutil.rmtree(resolved)
        if not stopped:
            raise RuntimeError("Owned cluster stop not confirmed; retained data for inspection")
        print("OWNED_POSTGRES_STOPPED", directory.relative_to(ROOT))
    print(marker.removesuffix("_OK") + "_PASS", directory.relative_to(ROOT))


if __name__ == "__main__":
    main()
