"""Shared host lifetime lock and exclusive offline maintenance lock."""
import sqlite3
from contextlib import contextmanager


@contextmanager
def host_lock(data_dir, exclusive=False):
    data_dir.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(data_dir / "maintenance.sqlite", timeout=1)
    try:
        db.execute("CREATE TABLE IF NOT EXISTS host_guard(id INTEGER PRIMARY KEY)")
        db.commit()
        db.execute("BEGIN EXCLUSIVE" if exclusive else "BEGIN")
        db.execute("SELECT * FROM host_guard").fetchall()
        yield
    finally:
        db.rollback()
        db.close()
