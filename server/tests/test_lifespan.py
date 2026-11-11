from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import DEFAULT, patch

from server import main


class LifespanTests(unittest.IsolatedAsyncioTestCase):
    @contextmanager
    def services(self):
        settings = SimpleNamespace(
            sqlite_path=Path("unused-test-database"),
            data_dir=Path("unused-test-data"),
            thumbs_dir=Path("unused-test-thumbnails"),
            startup_rescan=True,
            comfy_output_dir=None,
            generated_library_dir=None,
            comfy_url=None,
            comfy_presets_path=None,
            media_roots=["unused-test-root"],
        )
        # No real database, files, server sockets, or user settings are touched.
        with patch.object(main, "settings", settings), patch.multiple(
            main,
            SqliteStore=DEFAULT,
            TagAliasService=DEFAULT,
            MetadataStore=DEFAULT,
            MediaIndexService=DEFAULT,
            MediaStreamService=DEFAULT,
            ThumbnailService=DEFAULT,
            PdfEditService=DEFAULT,
            UrlDownloadService=DEFAULT,
            DeviceTokens=DEFAULT,
            host_lock=DEFAULT,
            persist_host_settings=DEFAULT,
        ) as services:
            metadata = services["MetadataStore"].return_value
            services["DeviceTokens"].return_value.configured.return_value = False
            metadata.seed_missing_media_stats.return_value = 0
            metadata.backfill_configured_tag_aliases.return_value = {
                "removedAliasCount": 0, "migratedLinkCount": 0,
            }
            yield services

    async def test_schema_failure_closes_database(self):
        with self.services() as services:
            store = services["SqliteStore"].return_value
            store.init_schema.side_effect = RuntimeError("schema failed")
            with self.assertRaisesRegex(RuntimeError, "schema failed"):
                async with main.lifespan(SimpleNamespace(state=SimpleNamespace())):
                    self.fail("startup must not reach yield")
            store.close.assert_called_once_with()
            services["ThumbnailService"].assert_not_called()

    async def test_thumbnail_constructor_failure_closes_database(self):
        with self.services() as services:
            services["ThumbnailService"].side_effect = RuntimeError("thumbnail failed")
            with self.assertRaisesRegex(RuntimeError, "thumbnail failed"):
                async with main.lifespan(SimpleNamespace(state=SimpleNamespace())):
                    self.fail("startup must not reach yield")
            services["SqliteStore"].return_value.close.assert_called_once_with()

    async def test_startup_jobs_failure_closes_both_resources(self):
        for service, method in [
            ("MediaIndexService", "rescan_configured_roots"),
            ("MetadataStore", "seed_missing_media_stats"),
            ("MetadataStore", "backfill_configured_tag_aliases"),
        ]:
            with self.subTest(method=method), self.services() as services:
                getattr(services[service].return_value, method).side_effect = RuntimeError(method)
                with self.assertRaisesRegex(RuntimeError, method):
                    async with main.lifespan(SimpleNamespace(state=SimpleNamespace())):
                        self.fail("startup must not reach yield")
                services["ThumbnailService"].return_value.close.assert_called_once_with()
                services["SqliteStore"].return_value.close.assert_called_once_with()

    async def test_normal_shutdown_closes_in_dependency_order(self):
        with self.services() as services:
            closed = []
            services["ThumbnailService"].return_value.close.side_effect = lambda: closed.append("thumbnail")
            services["SqliteStore"].return_value.close.side_effect = lambda: closed.append("database")
            async with main.lifespan(SimpleNamespace(state=SimpleNamespace())):
                self.assertEqual(closed, [])
            self.assertEqual(closed, ["thumbnail", "database"])

    async def test_thumbnail_close_failure_still_closes_database(self):
        with self.services() as services:
            services["ThumbnailService"].return_value.close.side_effect = RuntimeError("close failed")
            with self.assertRaisesRegex(RuntimeError, "close failed"):
                async with main.lifespan(SimpleNamespace(state=SimpleNamespace())):
                    pass
            services["SqliteStore"].return_value.close.assert_called_once_with()

    async def test_opt_in_importer_lifecycle(self):
        with self.services(), patch.object(main, "GeneratedLibrary") as factory:
            main.settings.comfy_output_dir = Path("output")
            main.settings.generated_library_dir = Path("generated")
            main.settings.auth_token = "test"
            main.settings.xviewer_saved_images_dir = Path("saved")
            app = SimpleNamespace(state=SimpleNamespace())
            async with main.lifespan(app):
                self.assertIs(app.state.generated_library, factory.return_value)
                factory.return_value.start.assert_called_once_with()
            factory.return_value.close.assert_called_once_with()

    async def test_missing_import_token_leaves_existing_host_running(self):
        with self.services(), patch.object(main, "GeneratedLibrary") as factory:
            main.settings.comfy_output_dir = Path("output")
            main.settings.generated_library_dir = Path("generated")
            main.settings.auth_token = None
            app = SimpleNamespace(state=SimpleNamespace())
            with self.assertLogs("server.main", level="ERROR"):
                async with main.lifespan(app):
                    self.assertIsNone(app.state.generated_library)
                    self.assertIsNotNone(app.state.metadata_store)
            factory.assert_not_called()

    async def test_generation_worker_closes_before_library(self):
        with self.services(), patch.object(main, "GeneratedLibrary") as library, \
                patch.object(main, "GenerationJobs") as jobs:
            main.settings.comfy_output_dir = Path("output")
            main.settings.generated_library_dir = Path("generated")
            main.settings.auth_token = "test"
            main.settings.xviewer_saved_images_dir = Path("saved")
            main.settings.comfy_url = "http://127.0.0.1:8188"
            main.settings.comfy_presets_path = Path("presets.json")
            order = []
            library.return_value.close.side_effect = lambda: order.append("library")
            jobs.return_value.close.side_effect = lambda: order.append("jobs")
            app = SimpleNamespace(state=SimpleNamespace())
            async with main.lifespan(app):
                jobs.return_value.start.assert_called_once_with()
                self.assertIs(app.state.generation_jobs, jobs.return_value)
            self.assertEqual(order, ["jobs", "library"])
            jobs.side_effect = ValueError("Invalid preset")
            with self.assertLogs("server.main", level="ERROR"):
                async with main.lifespan(app):
                    self.assertIsNone(app.state.generation_jobs)
                    self.assertIs(app.state.generated_library, library.return_value)


if __name__ == "__main__":
    unittest.main()
