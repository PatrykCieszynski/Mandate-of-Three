"""D2's existing World/network fixture on Windows or Linux; no live services.

Usage: python tests/run-auction-load.py --godot /absolute/path/to/godot
Requires installed pinned SOCI and godot-sqlite for the current OS.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--without-projection-indexes', action='store_true',
                        help='A/B baseline: remove only the new read indexes in the disposable fixture')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = root / '.godot/verification/auction-d2'
    logs.mkdir(parents=True, exist_ok=True)
    # Refuse to race another network suite or bind over an actual listener.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 18098))
    env = os.environ.copy()
    for variable, directory in [('APPDATA', 'appdata'), ('LOCALAPPDATA', 'localappdata'),
                                ('XDG_DATA_HOME', 'xdg-data'), ('XDG_CONFIG_HOME', 'xdg-config'),
                                ('XDG_CACHE_HOME', 'xdg-cache')]:
        target = logs / directory
        target.mkdir(exist_ok=True)
        env[variable] = str(target)
    processes, handles = [], []
    result_path = logs / 'results.json'
    result_path.unlink(missing_ok=True)
    try:
        deadline = time.monotonic() + 90
        for role, mode, number in [('server', 'world-server', 0), ('client1', 'client', 1), ('client2', 'client', 2)]:
            out = (logs / f'{role}.out.log').open('w', encoding='utf-8')
            err = (logs / f'{role}.err.log').open('w', encoding='utf-8')
            handles.extend([out, err])
            command = [str(args.godot.resolve()), '--headless', '--path', str(root),
                       f'--mode={mode}', 'res://tests/market_load.tscn', f'--test-client={number}']
            if args.without_projection_indexes:
                command.append('--without-projection-indexes')
            process = subprocess.Popen(command, cwd=root, env=env, stdout=out, stderr=err,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            processes.append((role, process))
            if role == 'server':
                time.sleep(1)
        for role, process in processes:
            code = process.wait(timeout=max(1, deadline - time.monotonic()))
            stdout = (logs / f'{role}.out.log').read_text(encoding='utf-8', errors='replace')
            stderr = (logs / f'{role}.err.log').read_text(encoding='utf-8', errors='replace')
            marker = 'MARKET_LOAD_SERVER_OK' if role == 'server' else 'MARKET_LOAD_CLIENT_OK'
            if code != 0 or marker not in stdout or re.search(r'SCRIPT ERROR|Parse Error|PVE_NETWORK_FAILED|Assertion failed', stdout + stderr):
                raise RuntimeError(f'{role} failed; inspect {logs}')
            print(f'{role}: PASS')
        result = json.loads(result_path.read_text(encoding='utf-8'))
        result['host'] = {'platform': platform.platform(), 'processor': platform.processor(),
                          'logical_cpus': os.cpu_count()}
        result['rpc_clients'] = []
        for role in ['client1', 'client2']:
            text = (logs / f'{role}.out.log').read_text(encoding='utf-8', errors='replace')
            line = next(line for line in text.splitlines() if line.startswith('AUCTION_D2_RPC_BENCH '))
            result['rpc_clients'].append(json.loads(line.split(' ', 1)[1]))
        result_path.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print(f'D2 observations: {result_path}')
    finally:
        # Only the three subprocesses created above, never a real World/Master.
        for _, process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
        for handle in handles:
            handle.close()


if __name__ == '__main__':
    main()
