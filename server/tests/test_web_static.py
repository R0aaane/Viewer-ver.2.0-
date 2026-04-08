from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.web_static import NO_CACHE_HEADER_VALUE, mount_web_build


def _write_build(tmp_path):
    (tmp_path / "index.html").write_text("<html><body>web app</body></html>", encoding="utf-8")
    (tmp_path / "main.dart.js").write_text("console.log('ok');", encoding="utf-8")


def test_mount_web_build_serves_index_and_assets(tmp_path):
    _write_build(tmp_path)
    app = FastAPI()

    mounted = mount_web_build(app, tmp_path)

    assert mounted is True
    client = TestClient(app)
    index_response = client.get("/")
    assert index_response.status_code == 200
    assert "web app" in index_response.text

    asset_response = client.get("/main.dart.js")
    assert asset_response.status_code == 200
    assert "console.log" in asset_response.text


def test_mount_web_build_marks_entry_files_as_no_cache(tmp_path):
    _write_build(tmp_path)
    app = FastAPI()
    mount_web_build(app, tmp_path)

    client = TestClient(app)

    index_response = client.get("/")
    assert index_response.headers["cache-control"] == NO_CACHE_HEADER_VALUE
    assert index_response.headers["pragma"] == "no-cache"
    assert index_response.headers["expires"] == "0"

    main_response = client.get("/main.dart.js")
    assert main_response.headers["cache-control"] == NO_CACHE_HEADER_VALUE


def test_mount_web_build_falls_back_for_spa_routes(tmp_path):
    _write_build(tmp_path)
    app = FastAPI()
    mount_web_build(app, tmp_path)

    client = TestClient(app)
    response = client.get("/viewer/item/123")

    assert response.status_code == 200
    assert "web app" in response.text
    assert response.headers["cache-control"] == NO_CACHE_HEADER_VALUE


def test_mount_web_build_keeps_api_like_paths_as_404(tmp_path):
    _write_build(tmp_path)
    app = FastAPI()
    mount_web_build(app, tmp_path)

    client = TestClient(app)
    response = client.get("/media/unknown/path")

    assert response.status_code == 404
    assert "web app" not in response.text


def test_mount_web_build_returns_false_when_build_is_missing(tmp_path):
    app = FastAPI()

    mounted = mount_web_build(app, tmp_path)

    assert mounted is False
