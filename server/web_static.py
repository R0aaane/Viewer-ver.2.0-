from __future__ import annotations

import logging
from collections.abc import Iterable
from pathlib import Path, PurePosixPath

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import PlainTextResponse, Response


DEFAULT_API_PREFIXES: tuple[str, ...] = (
    "/health",
    "/search",
    "/untagged",
    "/folders",
    "/items",
    "/media",
    "/rescan",
    "/organize",
    "/upload",
    "/download-url",
    "/rename",
    "/delete",
    "/tags",
)

NO_CACHE_WEB_FILES: frozenset[str] = frozenset(
    {
        "index.html",
        "flutter_bootstrap.js",
        "flutter.js",
        "main.dart.js",
        "flutter_service_worker.js",
        "version.json",
        "manifest.json",
        "AssetManifest.json",
        "FontManifest.json",
    }
)

NO_CACHE_HEADER_VALUE = "no-cache, no-store, must-revalidate"


class SpaStaticFiles(StaticFiles):
    def __init__(
        self,
        *,
        directory: str,
        api_prefixes: Iterable[str] = DEFAULT_API_PREFIXES,
        fallback_document: str = "index.html",
    ) -> None:
        super().__init__(directory=directory, html=True)
        self._api_prefixes = tuple(
            sorted(
                {
                    prefix if prefix.startswith("/") else f"/{prefix}"
                    for prefix in api_prefixes
                },
                key=len,
                reverse=True,
            )
        )
        self._fallback_document = fallback_document

    def _path_name(self, raw_path: str) -> str:
        return PurePosixPath(raw_path.lstrip("/")).name

    def _is_api_path(self, raw_path: str) -> bool:
        normalized = raw_path if raw_path.startswith("/") else f"/{raw_path}"
        for prefix in self._api_prefixes:
            if normalized == prefix or normalized.startswith(f"{prefix}/"):
                return True
        return False

    def _should_fallback_to_index(self, raw_path: str) -> bool:
        name = self._path_name(raw_path)
        return "." not in name

    def _apply_cache_headers(
        self,
        response: Response,
        *,
        raw_path: str,
        served_path: str,
    ) -> Response:
        served_name = self._path_name(served_path)
        if raw_path in {"", "/"} or served_name in NO_CACHE_WEB_FILES:
            response.headers["Cache-Control"] = NO_CACHE_HEADER_VALUE
            response.headers["Pragma"] = "no-cache"
            response.headers["Expires"] = "0"
        return response

    async def get_response(self, path: str, scope) -> Response:
        raw_path = scope.get("path", path)
        if self._is_api_path(raw_path):
            return PlainTextResponse("Not Found", status_code=404)

        try:
            response = await super().get_response(path, scope)
            return self._apply_cache_headers(
                response,
                raw_path=raw_path,
                served_path=path or self._fallback_document,
            )
        except StarletteHTTPException as error:
            if error.status_code != 404:
                raise

        if not self._should_fallback_to_index(raw_path):
            return PlainTextResponse("Not Found", status_code=404)

        try:
            response = await super().get_response(self._fallback_document, scope)
            return self._apply_cache_headers(
                response,
                raw_path=raw_path,
                served_path=self._fallback_document,
            )
        except StarletteHTTPException as error:
            if error.status_code == 404:
                return PlainTextResponse("Web build not found", status_code=404)
            raise


def mount_web_build(
    app: FastAPI,
    build_dir: Path,
    *,
    api_prefixes: Iterable[str] = DEFAULT_API_PREFIXES,
    logger: logging.Logger | None = None,
) -> bool:
    resolved_dir = build_dir.resolve()
    index_path = resolved_dir / "index.html"
    active_logger = logger or logging.getLogger(__name__)

    if not resolved_dir.is_dir() or not index_path.is_file():
        active_logger.info("Web build not found at %s; API-only mode", resolved_dir)
        return False

    app.mount(
        "/",
        SpaStaticFiles(
            directory=str(resolved_dir),
            api_prefixes=api_prefixes,
        ),
        name="web",
    )
    active_logger.info("Serving Flutter web build from %s", resolved_dir)
    return True
