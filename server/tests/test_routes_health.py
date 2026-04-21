from types import SimpleNamespace
import unittest

from server.api.routes_health import health


def _request(
    version: str,
    client_versions: set[str],
    update_version: str | None = None,
    update_url: str | None = None,
):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                settings=SimpleNamespace(
                    service_name="metadata-media-server",
                    version=version,
                    update_version=update_version,
                    update_url=update_url,
                ),
                client_app_versions=client_versions,
            )
        )
    )


class HealthRoutesTest(unittest.TestCase):
    def test_health_reports_latest_known_app_version(self) -> None:
        response = health(_request("1.0.0+1", {"1.0.0+3", "1.0.0+2"}))

        self.assertEqual(response.version, "1.0.0+1")
        self.assertEqual(response.latestKnownVersion, "1.0.0+3")
        self.assertEqual(response.clientVersions, ["1.0.0+2", "1.0.0+3"])

    def test_health_reports_update_url(self) -> None:
        response = health(
            _request(
                "1.0.0+1",
                set(),
                update_version="1.0.1+2",
                update_url="https://example.test/pdf_viewer.apk",
            )
        )

        self.assertEqual(response.latestKnownVersion, "1.0.1+2")
        self.assertEqual(response.updateVersion, "1.0.1+2")
        self.assertEqual(response.updateUrl, "https://example.test/pdf_viewer.apk")


if __name__ == '__main__':
    unittest.main()
