import os
from pathlib import Path
import tempfile
import unittest

from server.core.config import _project_version


class ConfigTest(unittest.TestCase):
    def test_project_version_overrides_stale_environment_version(self) -> None:
        previous = os.environ.get("MEDIA_SERVER_VERSION")
        self.addCleanup(self._restore_version, previous)
        os.environ["MEDIA_SERVER_VERSION"] = "1.0.155+165"

        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            (project_root / "pubspec.yaml").write_text(
                "name: pdf_viewer\nversion: 1.0.156+166\n",
                encoding="utf-8",
            )

            self.assertEqual(_project_version(project_root), "1.0.156+166")

    def _restore_version(self, value: str | None) -> None:
        if value is None:
            os.environ.pop("MEDIA_SERVER_VERSION", None)
        else:
            os.environ["MEDIA_SERVER_VERSION"] = value


if __name__ == "__main__":
    unittest.main()
