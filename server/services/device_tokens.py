"""Host-managed device credentials. Only token hashes are persisted."""
import hashlib
import hmac
import secrets
import sqlite3
import time
from contextlib import closing


class DeviceTokens:
    def __init__(self, path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self.connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS device_tokens (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, digest TEXT NOT NULL,
                    created REAL NOT NULL, revoked REAL
                );
            """)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    def issue(self, name):
        name = name.strip()
        if not name or len(name) > 128:
            raise ValueError("Use a device name between 1 and 128 characters")
        identifier = secrets.token_hex(12)
        token = f"pv1.{identifier}.{secrets.token_urlsafe(32)}"
        with closing(self.connect()) as db, db:
            db.execute("INSERT INTO device_tokens VALUES (?,?,?,?,NULL)",
                       (identifier, name, hashlib.sha256(token.encode()).hexdigest(), time.time()))
        return identifier, token

    def verify(self, token):
        parts = token.split(".")
        if len(parts) != 3 or parts[0] != "pv1" or len(token) > 256:
            return None
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM device_tokens WHERE id=? AND revoked IS NULL", (parts[1],)).fetchone()
        if row and hmac.compare_digest(row["digest"], hashlib.sha256(token.encode()).hexdigest()):
            return row["id"]
        return None

    def configured(self):
        with closing(self.connect()) as db:
            # Revoking the last device must never enable anonymous access.
            return db.execute("SELECT 1 FROM device_tokens LIMIT 1").fetchone() is not None

    def list(self):
        with closing(self.connect()) as db:
            return [dict(row) for row in db.execute(
                "SELECT id,name,created,revoked FROM device_tokens ORDER BY created DESC")]

    def revoke(self, identifier):
        with closing(self.connect()) as db, db:
            return db.execute("UPDATE device_tokens SET revoked=COALESCE(revoked,?) WHERE id=?",
                              (time.time(), identifier)).rowcount > 0
