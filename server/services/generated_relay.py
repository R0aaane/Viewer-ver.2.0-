"""Durable generated-image outbox. Credentials live only in the local worker memory."""
import hashlib
import logging
import threading
import time
from contextlib import closing
from urllib.parse import urlsplit
import requests


class GeneratedRelay:
    def __init__(self, library):
        self.library = library
        self._target = None
        self._lock = threading.Lock()
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.thread = threading.Thread(target=self._run, name='generated-relay', daemon=True)
        self.http = requests.Session(); self.http.trust_env = False
        with closing(library.connect()) as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS generated_transfers (
                target TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, next_try REAL NOT NULL DEFAULT 0, error TEXT,
                PRIMARY KEY(target,digest));''')

    def start(self): self.thread.start()
    def close(self):
        self.stop.set(); self.wake.set(); self.thread.join(); self.http.close()

    def configure(self, base_url, token):
        value = base_url.rstrip('/')
        parsed = urlsplit(value)
        if parsed.scheme not in ('http','https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError('ホストのHTTP(S)接続先を指定してください')
        if parsed.hostname in ('127.0.0.1','localhost','::1') and parsed.port == 18890:
            raise ValueError('生成元自身には転送できません')
        identifier = hashlib.sha256(value.encode()).hexdigest()
        with self._lock: self._target = (identifier, value, token)
        with closing(self.library.connect()) as db, db:
            db.execute("UPDATE generated_transfers SET next_try=0 WHERE target=? AND state<>'sent'",(identifier,))
        self.wake.set()

    def status(self):
        with self._lock: target = self._target
        if target is None: return {'configured':False,'items':[]}
        with closing(self.library.connect()) as db:
            rows = db.execute('SELECT digest AS mediaId,state,error FROM generated_transfers WHERE target=?',(target[0],)).fetchall()
        return {'configured':True,'items':[dict(row) for row in rows]}

    def tick(self):
        with self._lock: target = self._target
        if target is None: return
        key, url, token = target
        with closing(self.library.connect()) as db, db:
            db.execute("""INSERT OR IGNORE INTO generated_transfers(target,digest,state)
                SELECT ?,i.digest,'pending' FROM images i LEFT JOIN generated_overrides o ON o.digest=i.digest
                WHERE i.state='ready' AND COALESCE(o.deleted,0)=0""",(key,))
            row = db.execute("""SELECT t.* FROM generated_transfers t JOIN images i ON i.digest=t.digest
                LEFT JOIN generated_overrides o ON o.digest=i.digest
                WHERE target=? AND t.state<>'sent' AND next_try<=? AND i.state='ready' AND COALESCE(o.deleted,0)=0
                ORDER BY next_try,digest LIMIT 1""",(key,time.time())).fetchone()
            if row is None: return
            tags = [dict(t) for t in db.execute('SELECT category,name FROM manual_tags WHERE digest=?',(row['digest'],))]
        path = self.library.media_path(row['digest'],False)
        if path is None: return
        error = None
        try:
            import json
            with path.open('rb') as stream:
                response = self.http.post(url+'/generated/upload', headers={'Authorization':'Bearer '+token} if token.strip() else {},
                    files={'file':(path.name,stream,'application/octet-stream')},data={'tags':json.dumps(tags)},timeout=(5,30))
            if response.status_code in (401,403): error = 'ホストの認証設定を確認してください'
            elif response.status_code in (404,503): error = 'ホストの生成画像受信ライブラリが利用できません。ホストの更新・設定を確認してください'
            else:
                response.raise_for_status()
                if response.json().get('mediaId') != row['digest']: raise ValueError('ホストの受信画像IDが一致しません')
        except (requests.RequestException, ValueError, OSError):
            error = 'ホストへ送信できません。接続の復旧後に自動再試行します'
        with closing(self.library.connect()) as db, db:
            attempts = row['attempts']+1
            db.execute('UPDATE generated_transfers SET state=?,attempts=?,next_try=?,error=? WHERE target=? AND digest=?',
                ('pending' if error else 'sent',attempts,time.time()+min(60,5*attempts),error,key,row['digest']))

    def _run(self):
        while not self.stop.is_set():
            try: self.tick()
            except Exception:
                logging.getLogger(__name__).exception("Generated relay iteration failed; durable queue retained")
            self.wake.wait(3); self.wake.clear()
