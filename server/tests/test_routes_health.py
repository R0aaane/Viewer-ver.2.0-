import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from server.api.routes_health import health


def _request(
    version: str,
    client_versions: set[str],
    *,
    update_version: str | None = None,
    update_url: str | None = None,
    data_dir: Path,
):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                settings=SimpleNamespace(
                    service_name="metadata-media-server",
                    version=version,
                    data_dir=data_dir,
                    update_version=update_version,
                    update_url=update_url,
                ),
                client_app_versions=client_versions,
            )
        )
    )


def _write_uploaded_update(data_dir: Path, version: str, file_name: str) -> None:
    updates_dir = data_dir / "app_updates"
    updates_dir.mkdir(parents=True, exist_ok=True)
    (updates_dir / file_name).write_bytes(b"update")
    (updates_dir / "latest.json").write_text(
        json.dumps(
            {
                "version": version,
                "fileName": file_name,
                "originalFileName": "pdf_viewer.apk",
                "sizeBytes": 6,
                "uploadedAt": "2026-04-22T00:00:00+00:00",
            }
        ),
        encoding="utf-8",
    )


class HealthRoutesTest(unittest.TestCase):
    def test_health_reports_latest_known_app_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            response = health(
                _request(
                    "1.0.0+1",
                    {"1.0.0+3", "1.0.0+2"},
                    data_dir=Path(temp_dir),
                )
            )

        self.assertEqual(response.version, "1.0.0+1")
        self.assertEqual(response.latestKnownVersion, "1.0.0+3")
        self.assertEqual(response.clientVersions, ["1.0.0+2", "1.0.0+3"])

    def test_health_reports_update_url(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            response = health(
                _request(
                    "1.0.0+1",
                    set(),
                    update_version="1.0.1+2",
                    update_url="https://example.test/pdf_viewer.apk",
                    data_dir=Path(temp_dir),
                )
            )

        self.assertEqual(response.latestKnownVersion, "1.0.1+2")
        self.assertEqual(response.updateVersion, "1.0.1+2")
        self.assertEqual(response.updateUrl, "https://example.test/pdf_viewer.apk")

    def test_health_reports_uploaded_update_url(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            data_dir = Path(temp_dir)
            _write_uploaded_update(data_dir, "1.0.2+3", "pdf_viewer_1.0.2.apk")

            response = health(
                _request(
                    "1.0.0+1",
                    set(),
                    update_version="1.0.1+2",
                    update_url="https://example.test/pdf_viewer.apk",
                    data_dir=data_dir,
                )
            )

        self.assertEqual(response.latestKnownVersion, "1.0.2+3")
        self.assertEqual(response.updateVersion, "1.0.2+3")
        self.assertEqual(response.updateUrl, "/app-updates/pdf_viewer_1.0.2.apk")


if __name__ == '__main__':
    unittest.main()
