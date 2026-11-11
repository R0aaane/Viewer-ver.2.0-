from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

from fastapi import FastAPI
from PIL import Image, PngImagePlugin
import requests

from server.api.routes_generated import router, GalleryQuery
from server.services import generated_catalog
from server.services.generated_library import GeneratedLibrary
from server.services.generation_metadata import read_generation
from server.tests.test_routes_generated import serve


def graph_with_ids(prefix):
    def link(key):
        return [prefix + key, 0]
    nodes = {
        "plus": ("CLIPTextEncode", {"text": "sunlit forest"}),
        "minus": ("CLIPTextEncode", {"text": "fog"}),
        "base": ("CheckpointLoaderSimple", {"ckpt_name": "model.safetensors"}),
        "tune": ("LoraLoader", {"model": link("base"), "lora_name": "ink", "strength_model": 0.5}),
        "sample": ("KSamplerAdvanced", {"model": link("tune"), "positive": link("plus"),
            "negative": link("minus"), "noise_seed": 18446744073709551615, "steps": 23,
            "cfg": 5.5, "sampler_name": "euler", "scheduler": "normal"}),
        "unknown": ("CustomNode", {"private_extension": "keep exactly"}),
    }
    return {prefix + n: {"class_type": kind, "inputs": values} for n, (kind, values) in nodes.items()}


class GeneratedGalleryTests(unittest.TestCase):
    def test_indexed_pages_keep_ties_overrides_filters_and_revisions(self):
        with TemporaryDirectory() as temp:
            source = Path(temp) / "output"
            source.mkdir()
            library = GeneratedLibrary(source, Path(temp) / "library")
            ids = [f"{n:064x}" for n in range(1, 7)]
            with closing(library.connect()) as db, db:
                for n, digest in enumerate(ids, 1):
                    db.execute("INSERT INTO images VALUES (?,'png',?)", (digest, "staged" if n == 6 else "ready"))
                    row = db.execute("INSERT INTO generation_info VALUES (?,?,?,NULL,NULL,'{}','sourceCreated')",
                                     (digest, {1: "z", 3: "m", 5: "b"}.get(n, "h"), ((n + 1) // 2) * 100))
                    db.execute("INSERT INTO prompt_search(rowid,text) VALUES (?,?)",
                               (row.lastrowid, "forest" if n in (1, 3) else "ocean"))
                db.execute("INSERT INTO generated_overrides VALUES (?,NULL,1)", (ids[1],))
                db.execute("INSERT INTO generated_overrides VALUES (?,'alpha',0)", (ids[3],))
                for digest in (ids[0], ids[2]):
                    db.execute("INSERT INTO manual_tags VALUES (?,'free','selected')", (digest,))
                    db.execute("INSERT INTO generated_favorites VALUES (?)", (digest,))
                db.execute("INSERT INTO tag_revisions VALUES (?,7)", (ids[2],))
                def search(**query):
                    return generated_catalog.search(db, GalleryQuery(**query))
                def selected(**query):
                    return [row["mediaId"] for row in search(**query)["items"]]
                expected = [ids[4], ids[2], ids[3], ids[0]]
                self.assertEqual(selected(), expected)
                self.assertEqual([selected(limit=1, offset=n)[0] for n in range(4)], expected)
                self.assertFalse(search(limit=1, offset=3)["hasMore"])
                self.assertTrue(search(limit=1, offset=2)["hasMore"])
                self.assertEqual(selected(sort="oldest"), [ids[0], ids[2], ids[3], ids[4]])
                self.assertEqual(selected(sort="name"), [ids[3], ids[4], ids[2], ids[0]])
                self.assertEqual(selected(deleted=True), [ids[1]])
                self.assertEqual(selected(prompt="forest", favorite=True), [ids[2], ids[0]])
                tag = {"category": "free", "name": "selected"}
                self.assertEqual(selected(all_tags=[tag]), [ids[2], ids[0]])
                self.assertEqual(selected(no_tags=[tag]), [ids[4], ids[3]])
                self.assertEqual(selected(from_ms=200, before_ms=300), [ids[2], ids[3]])
                row = search(offset=1, limit=1)["items"][0]
                self.assertEqual(row["tagVersion"], 7)
                self.assertGreater(row["version"], 0)
                self.assertEqual(row["epoch"], db.execute("SELECT epoch FROM sync_meta").fetchone()[0])

    def test_custom_sampler_webp_exif_and_conditioning_output_slots(self):
        graph = graph_with_ids("n")
        del graph["nsample"]
        graph.update({
            "control": {"class_type": "ControlNetApplyAdvanced", "inputs": {
                "positive": ["nplus", 0], "negative": ["nminus", 0]}},
            "guide": {"class_type": "CFGGuider", "inputs": {"model": ["ntune", 0],
                "positive": ["control", 0], "negative": ["control", 1], "cfg": 4}},
            "rng": {"class_type": "RandomNoise", "inputs": {"noise_seed": 12}},
            "select": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
            "schedule": {"class_type": "BasicScheduler", "inputs": {"scheduler": "normal", "steps": 17}},
            "run": {"class_type": "SamplerCustomAdvanced", "inputs": {"sampler": ["select", 0],
                "sigmas": ["schedule", 0], "noise": ["rng", 0], "guider": ["guide", 0]}},
        })
        with TemporaryDirectory() as temp:
            path = Path(temp) / "fixture.webp"
            exif = Image.Exif()
            exif[0x0110] = "prompt:" + json.dumps(graph)
            exif[0x010F] = 'workflow:{"nodes":[]}'
            Image.new("RGB", (10, 20)).save(path, exif=exif)
            raw, info = read_generation(path)
            self.assertEqual(json.loads(raw["prompt"]), graph)
            sampler, = info["samplers"]
            self.assertEqual((sampler["positive"], sampler["negative"]), ("sunlit forest", "fog"))
            self.assertEqual((sampler["seed"], sampler["steps"], sampler["scheduler"]), ("12", 17, "normal"))

    def test_unrecognized_prompt_is_preserved(self):
        with TemporaryDirectory() as temp:
            path = Path(temp) / "partial.png"
            meta = PngImagePlugin.PngInfo()
            meta.add_text("prompt", "{incomplete")
            Image.new("RGB", (3, 2)).save(path, pnginfo=meta)
            raw, info = read_generation(path)
            self.assertEqual(raw["prompt"], "{incomplete")
            self.assertEqual(info, {"dimensions": [3, 2], "samplers": []})

    def test_phase2_upgrade_search_bulk_edit_and_reparse_through_api(self):
        with TemporaryDirectory() as temp:
            root = Path(temp) / "library"
            source = Path(temp) / "output"
            source.mkdir()
            originals = root / "originals"
            originals.mkdir(parents=True)
            ids = []
            with closing(sqlite3.connect(Path(temp) / "phase2-fixture.sqlite")) as db, db:
                db.executescript("""
                    PRAGMA application_id=0x47504C31;
                    CREATE TABLE images(digest TEXT PRIMARY KEY, ext TEXT NOT NULL,state TEXT NOT NULL);
                    CREATE TABLE events(seq INTEGER PRIMARY KEY,digest TEXT NOT NULL UNIQUE);
                """)
                for i in range(2):
                    metadata = PngImagePlugin.PngInfo()
                    graph = json.dumps(graph_with_ids(str(i * 149)), indent=1)
                    metadata.add_text("prompt", graph)
                    metadata.add_text("workflow", '{"nodes":[{"type":"CustomNode"}]}')
                    path = source / f"{i}.png"
                    Image.new("RGB", (10, 20)).save(path, pnginfo=metadata)
                    digest = hashlib.sha256(path.read_bytes()).hexdigest()
                    path.rename(originals / (digest + ".png"))
                    db.execute("INSERT INTO images VALUES (?,'png','ready')", (digest,))
                    db.execute("INSERT INTO events(digest) VALUES (?)", (digest,))
                    ids.append(digest)
                db.commit()
                with closing(sqlite3.connect(root / "generated.sqlite")) as copy:
                    db.backup(copy)

            library = GeneratedLibrary(source, root)
            library.scan()
            app = FastAPI()
            app.include_router(router)
            app.state.settings = SimpleNamespace(auth_token="fixture")
            app.state.generated_library = library
            with serve(app) as port, requests.Session() as client:
                url = f"http://127.0.0.1:{port}/generated"
                client.headers.update({"Authorization": "Bearer fixture"})
                def post(route, data):
                    response = client.post(url + route, json=data, timeout=5)
                    response.raise_for_status()
                    return response.json()
                def search(**query):
                    return [r["mediaId"] for r in post("/search", query)["items"]]
                def tag(category, name):
                    return {"category": category, "name": name}
                series, character, free = tag("series", "空"), tag("character", "空"), tag("free", "再解析")
                for item, selected in [(series, ids), (character, ids[:1]), (free, ids[:1])]:
                    post("/tags", {"media_ids": selected, "tag": item, "operation": "add"})
                target = "/media/" + ids[0]
                client.put(url + target + "/favorite?value=true", timeout=5).raise_for_status()
                for _ in range(2):
                    detail = post(target + "/reanalyze", {})
                    self.assertCountEqual(detail["tags"], [series, character, free])
                    self.assertTrue(detail["favorite"])
                    self.assertEqual(detail["prompt"], json.dumps(graph_with_ids("0"), indent=1))
                    self.assertEqual(detail["workflow"], '{"nodes":[{"type":"CustomNode"}]}')
                    sampler, = detail["generation"]["samplers"]
                    self.assertEqual((sampler["positive"], sampler["negative"]), ("sunlit forest", "fog"))
                    self.assertEqual(sampler["seed"], "18446744073709551615")
                    self.assertEqual(sampler["checkpoint"], ["model.safetensors"])
                    self.assertEqual(sampler["lora"][0]["strength_model"], 0.5)
                self.assertCountEqual(search(prompt="forest fog"), ids)
                self.assertEqual(search(favorite=True, all_tags=[series, free]), ids[:1])
                self.assertEqual(search(any_tags=[free, character]), ids[:1])
                self.assertEqual(search(all_tags=[series], no_tags=[character]), ids[1:])
                self.assertEqual(search(before_ms=1), [])
                self.assertTrue(post("/search", {"limit": 1})["hasMore"])
                self.assertEqual(len(search(limit=1, offset=1)), 1)
                response = client.post(url + "/tags", json={"media_ids": [ids[0], "f"*64],
                    "tag": series, "operation":"remove"}, timeout=5)
                self.assertEqual(response.status_code, 404)
                self.assertCountEqual(search(all_tags=[series]), ids)
                post("/tags", {"media_ids": ids, "tag": series, "operation": "remove"})
                self.assertEqual(search(all_tags=[series]), [])
                app.state.generated_library = GeneratedLibrary(source, root)
                self.assertEqual(search(all_tags=[character], favorite=True), ids[:1])
                # Two devices read the same revisions. Only the first update wins.
                seen = {r["mediaId"]: r["tagVersion"] for r in post("/search", {})["items"]}
                one = ids[0]
                post("/tags", {"media_ids": [one], "expected_versions": {one: seen[one]},
                               "tag": series, "operation": "add"})
                stale = client.post(url + "/tags", json={"media_ids": ids, "expected_versions": seen,
                    "tag": free, "operation": "add"}, timeout=5)
                self.assertEqual(stale.status_code, 409)
                self.assertEqual(search(all_tags=[free]), [one])
                latest = post(target + "/reanalyze", {})
                self.assertEqual(latest["tagVersion"], seen[one] + 1)
                post("/tags", {"media_ids": [one], "expected_versions": {one: latest["tagVersion"]},
                               "tag": series, "operation":"remove"})
