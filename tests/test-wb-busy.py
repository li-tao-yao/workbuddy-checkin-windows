"""Test busy detection with temporary databases; never read real conversation data."""
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
helper = root.parent / 'wb-busy-check.py'
cutoff = 10000
cases = [
    ('recent activity', ('working', 1, 2, 11000), 1),
    ('recent update with null activity', ('working', 1, 11000, None), 1),
    ('recent creation fallback', ('working', 11000, None, None), 1),
    ('unknown times conservative', ('working', None, None, None), 1),
    ('old stale working record', ('working', 1, 2, None), 0),
    ('completed task', ('completed', 11000, 11000, 11000), 0),
]
with tempfile.TemporaryDirectory(prefix='.wb-busy-test-', dir=root) as tmp:
    tmp_path = Path(tmp).resolve()
    assert tmp_path.is_relative_to(root)
    for index, (label, row, expected) in enumerate(cases):
        db_path = tmp_path / f'{index}.db'
        con = sqlite3.connect(db_path)
        try:
            con.execute('create table sessions(status text,created_at integer,updated_at integer,last_activity_at integer)')
            con.execute('insert into sessions values(?,?,?,?)', row)
            con.commit()
        finally:
            con.close()
        result = subprocess.run([sys.executable, str(helper), str(db_path), str(cutoff)], capture_output=True, text=True, timeout=10)
        if result.returncode != 0 or result.stdout.strip() != str(expected):
            raise SystemExit(f'FAIL busy detection: {label}')
        print(f'PASS busy detection: {label}')
    missing = tmp_path / 'missing.db'
    result = subprocess.run([sys.executable, str(helper), str(missing), str(cutoff)], capture_output=True, text=True, timeout=10)
    if result.returncode != 3 or missing.exists():
        raise SystemExit('FAIL missing database must not be created')
    print('PASS missing database stays read-only')
