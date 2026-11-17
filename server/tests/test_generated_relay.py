import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from contextlib import closing
from unittest.mock import patch
import requests
from fastapi import FastAPI
from PIL import Image
from server.services.generated_library import GeneratedLibrary
from server.services.generated_relay import GeneratedRelay
from server.api.routes_generated import router
from server.tests.test_routes_generated import serve


class GeneratedRelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        for name in ('local-source','remote-source'): (root/name).mkdir()
        self.local = GeneratedLibrary(root/'local-source',root/'local')
        self.remote = GeneratedLibrary(root/'remote-source',root/'remote')
        image=root/'input.png'; Image.new('RGB',(24,32),'blue').save(image)
        self.digest=self.local.import_download(image)
        with closing(self.local.connect()) as db, db:
            db.execute('INSERT INTO manual_tags VALUES(?,?,?)',(self.digest,'artist','Example artist'))
        self.relay = GeneratedRelay(self.local); self.addCleanup(self.relay.http.close)
        self.app=FastAPI(); self.app.include_router(router)
        self.app.state.settings=SimpleNamespace(auth_token='fixture-token')
        self.app.state.generated_library=self.remote

    def test_upload_tags_and_idempotent_retry_preserve_host_edits(self):
        with serve(self.app) as port:
            self.relay.configure(f'http://127.0.0.1:{port}','fixture-token')
            self.relay.tick()
            self.assertEqual(self.relay.status()['items'][0]['state'],'sent')
            self.assertEqual(self.remote.media_path(self.digest,False).read_bytes(),self.local.media_path(self.digest,False).read_bytes())
            with closing(self.remote.connect()) as db, db:
                self.assertEqual(db.execute('SELECT name FROM manual_tags').fetchone()[0],'Example artist')
                db.execute('INSERT INTO manual_tags VALUES(?,?,?)',(self.digest,'free','host edit'))
            # Simulate a lost acknowledgement after host commit.
            with closing(self.local.connect()) as db, db:
                db.execute("UPDATE generated_transfers SET state='pending',next_try=0")
            self.relay.tick()
            with closing(self.remote.connect()) as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM images').fetchone()[0],1)
                self.assertEqual(db.execute('SELECT COUNT(*) FROM manual_tags').fetchone()[0],2)

    def test_offline_queue_survives_restart_and_authentication_failure(self):
        with serve(self.app) as port:
            url=f'http://127.0.0.1:{port}'
            self.relay.configure(url,'wrong-token'); self.relay.tick()
            self.assertEqual(self.relay.status()['items'][0]['state'],'pending')
            self.assertIn('認証',self.relay.status()['items'][0]['error'])
            reloaded=GeneratedRelay(self.local)
            self.addCleanup(reloaded.http.close)
            reloaded.configure(url,'fixture-token')
            with patch.object(reloaded.http,'post',side_effect=requests.ConnectionError('offline')):
                reloaded.tick()
            self.assertEqual(reloaded.status()['items'][0]['state'],'pending')
            reloaded.configure(url,'fixture-token'); reloaded.tick()
            self.assertEqual(reloaded.status()['items'][0]['state'],'sent')

    def test_existing_tailnet_policy_works_without_bearer_and_rejects_forwarded_identity(self):
        self.app.state.settings.auth_token=None
        self.app.state.settings.tailnet_without_token=True
        with serve(self.app) as port:
            url=f'http://127.0.0.1:{port}'
            self.relay.configure(url,''); self.relay.tick()
            self.assertEqual(self.relay.status()['items'][0]['state'],'sent')
            self.assertEqual(requests.post(url+'/generated/search',json={},timeout=3).status_code,200)
            self.assertEqual(requests.post(url+'/generated/search',json={},headers={'Forwarded':'for=100.64.0.1'},timeout=3).status_code,401)

    def test_disabled_host_keeps_original_and_credentials_are_not_stored(self):
        self.app.state.generated_library=None
        with serve(self.app) as port:
            self.relay.configure(f'http://127.0.0.1:{port}','fixture-token'); self.relay.tick()
            row=self.relay.status()['items'][0]
            self.assertEqual(row['state'],'pending');self.assertIn('ライブラリ',row['error'])
            self.assertTrue(self.local.media_path(self.digest,False).exists())
            with closing(self.local.connect()) as db:
                row=dict(db.execute('SELECT * FROM generated_transfers').fetchone())
                self.assertNotIn('fixture-token',str(row))
