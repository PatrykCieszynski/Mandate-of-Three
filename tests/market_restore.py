"""Fixture-only consistent online backup of a crash-recovered SQLite WAL database."""
from pathlib import Path
import sqlite3
root = Path(__file__).resolve().parents[1]
source = root / '.godot/verification/market-recovery.db'
target = root / '.godot/verification/market-restored.db'
with sqlite3.connect(source) as src, sqlite3.connect(target) as dst:
    src.backup(dst)
    assert dst.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
print('MARKET_WAL_BACKUP_OK')
