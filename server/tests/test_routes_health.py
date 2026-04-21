from types import SimpleNamespace
import unittest

from server.api.routes_health import health


def _request(version: str, client_versions: set[str]):
    return SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(
                settings=SimpleNamespace(
                    service_name="metadata-media-server",
                    version=version,
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


if __name__ == '__main__':
    unittest.main()
