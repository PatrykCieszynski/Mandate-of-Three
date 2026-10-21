"""Explicit durable, loopback-only development PostgreSQL. Never deletes old data.

This checkout owns its data directory. No installed PostgreSQL service is touched.
Credentials stay in ignored runtime files/environment, never command-line args.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT/".godot/runtime/postgres-local"
HIDDEN = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def run(argv, env=None, sql=None):
    if Path(argv[0]).stem == "pg_ctl" and "start" in argv:
        # A Windows daemon can inherit PIPE handles and keep communicate() open
        # after pg_ctl exits. A private file avoids that lifecycle dependency.
        with (DIRECTORY/"control.log").open("a", encoding="utf-8") as stream:
            result = subprocess.run(list(map(str, argv)), stdout=stream, stderr=stream,
                                    env=env, creationflags=HIDDEN, timeout=40)
        if result.returncode:
            raise RuntimeError("Development PostgreSQL startup failed; see private control.log")
        return ""
    result = subprocess.run(list(map(str, argv)), input=sql, capture_output=True,
                            encoding="utf-8", env=env, creationflags=HIDDEN, timeout=90)
    if result.returncode or "SCRIPT ERROR" in result.stderr:
        # libpq/SOCI errors may contain credentials: private log only.
        with (DIRECTORY/"control.log").open("a", encoding="utf-8") as stream:
            stream.write(result.stdout+result.stderr)
        raise RuntimeError("Development PostgreSQL command failed; see ignored private control.log")
    return result.stdout


def start(pg_bin, port):
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    state_path = DIRECTORY/"connection.json"
    data = DIRECTORY/"data"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state["port"] != port or Path(state["pg_bin"]).resolve() != pg_bin:
            raise RuntimeError("Existing development cluster configuration differs; no data was changed")
    else:
        if data.exists():
            raise RuntimeError("Unclaimed PostgreSQL directory exists; refusing to initialize over it")
        state = {"format": 1, "pg_bin": str(pg_bin), "port": port,
                 "password": secrets.token_hex(32), "admin_password": secrets.token_hex(32)}
        with state_path.open("x", encoding="utf-8") as stream:
            json.dump(state, stream)
    extension = ".exe" if os.name == "nt" else ""
    binary = lambda name: pg_bin/(name+extension)
    # Strip ambient PG service/options/database settings, retaining normal OS env.
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("PG")}
    env.update(PGHOST="127.0.0.1", PGPORT=str(port), PGUSER="mandate_admin", PGDATABASE="postgres",
               PGPASSWORD=state["admin_password"], PGCONNECT_TIMEOUT="3", PGCLIENTENCODING="UTF8")
    if not (data/"PG_VERSION").exists():
        password_file = DIRECTORY/"init-password"
        try:
            password_file.write_text(state["admin_password"]+"\n", encoding="utf-8")
            run([binary("initdb"), "-D", data, "-U", "mandate_admin", "--encoding=UTF8", "--locale=C",
                 "--auth-host=scram-sha-256", "--auth-local=scram-sha-256", "--pwfile", password_file])
        finally:
            password_file.unlink(missing_ok=True)
    status = subprocess.run([str(binary("pg_ctl")), "-D", str(data), "status"], capture_output=True, creationflags=HIDDEN)
    if status.returncode == 3:
        run([binary("pg_ctl"), "-D", data, "-l", DIRECTORY/"postgres.log", "-o",
             f"-h 127.0.0.1 -p {port} -c max_connections=32 -c log_min_error_statement=panic", "-w", "-t", "30", "start"])
    elif status.returncode:
        raise RuntimeError("Cannot determine owned PostgreSQL cluster state")
    psql = [binary("psql"), "-X", "-w", "-At", "-v", "ON_ERROR_STOP=1"]
    # Fixed local identifiers; generated hex passwords only, not player content.
    if run(psql, env, "SELECT count(*) FROM pg_roles WHERE rolname='mandate_game';").strip() == "0":
        run(psql, env, f"CREATE ROLE mandate_game LOGIN PASSWORD '{state['password']}';")
    if run(psql, env, "SELECT count(*) FROM pg_database WHERE datname='mandate_dev';").strip() == "0":
        run(psql, env, "CREATE DATABASE mandate_dev OWNER mandate_game;")
    connection = f"host=127.0.0.1 port={port} dbname=mandate_dev user=mandate_game password={state['password']}"
    engine = ROOT/".godot/Godot_v4.7.2-stable_win64_console.exe"
    child_env = dict(env, MANDATE_PG_PROVISION="1", MANDATE_ECONOMY_CONNECTION=connection)
    child_env.update(APPDATA=str(DIRECTORY/"appdata"), LOCALAPPDATA=str(DIRECTORY/"localappdata"))
    for key in ("APPDATA", "LOCALAPPDATA"):
        Path(child_env[key]).mkdir(exist_ok=True)
    result = run([engine, "--headless", "--path", ROOT, "--mode=world-server", "--script",
                  "res://tools/postgres/provision_economy.gd"], child_env)
    if "SCRIPT ERROR" in result or "POSTGRES_ECONOMY_PROVISIONED authority_id=" not in result:
        raise RuntimeError("Development schema provisioning not verified")
    authority = result.split("POSTGRES_ECONOMY_PROVISIONED authority_id=", 1)[1].splitlines()[0].strip()
    state.update(connection=connection, authority_id=authority)
    temporary = DIRECTORY/"connection.partial"
    temporary.write_text(json.dumps(state, indent=2)+"\n", encoding="utf-8")
    temporary.replace(state_path)
    print("POSTGRES_DEV_READY: owned loopback cluster; credentials in ignored runtime configuration")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True)
    parser.add_argument("--port", type=int, default=55432)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Use an unprivileged TCP port")
    try:
        start(args.pg_bin.resolve(), args.port)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error) if isinstance(error, RuntimeError) else "Development PostgreSQL setup failed; private files preserved", file=sys.stderr)
        sys.exit(1)
