from __future__ import annotations

import logging
import os
import sqlite3
from contextlib import ExitStack, asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from server.api.routes_actions import router as actions_router
from server.api.routes_health import router as health_router
from server.api.routes_generated import router as generated_router
from server.api.routes_sync import router as sync_router
from server.api.routes_generation_jobs import router as generation_jobs_router
from server.api.routes_host_update import router as host_update_router
from server.api.routes_media import router as media_router
from server.api.routes_search import router as search_router
from server.api.routes_tags import router as tags_router
from server.core.config import load_settings
from server.core.logging import configure_logging
from server.repositories.sqlite_store import SqliteStore
from server.services.media_index_service import MediaIndexService
from server.services.generated_library import GeneratedLibrary
from server.services.generation_jobs import GenerationJobs
from server.services.device_tokens import DeviceTokens
from server.services.maintenance import host_lock
from server.services.host_snapshot_settings import persist_host_settings
from server.services.private_access import PrivateAccessMiddleware
from server.services.media_stream_service import MediaStreamService
from server.services.metadata_store import MetadataStore
from server.services.tag_alias_service import TagAliasService
from server.services.thumbnail_service import ThumbnailService
from server.services.pdf_edit_service import PdfEditService
from server.services.url_download_service import UrlDownloadService
from server.web_static import mount_web_build


CLIENT_APP_VERSION_HEADER = "x-pdf-viewer-app-version"
EXPOSED_RESPONSE_HEADERS = [
    "Accept-Ranges",
    "Content-Length",
    "Content-Range",
    "ETag",
    "Last-Modified",
    "X-Thumbnail-Detail",
    "X-Thumbnail-Status",
]

settings = load_settings()
configure_logging(settings.log_level)
logger = logging.getLogger(__name__)
project_root = Path(__file__).resolve().parents[1]


def _resolve_web_build_dir() -> Path:
    configured = (os.getenv("MEDIA_SERVER_WEB_BUILD_DIR") or "").strip()
    candidates = [
        Path(configured).resolve() if configured else None,
        (project_root / "build" / "web").resolve(),
        (Path.cwd() / "build" / "web").resolve(),
    ]
    for candidate in candidates:
        if candidate is not None and (candidate / "index.html").is_file():
            return candidate
    return (Path(configured).resolve() if configured else candidates[1])


web_build_dir = _resolve_web_build_dir()


@asynccontextmanager
async def lifespan(app: FastAPI):
    with ExitStack() as resources:
        resources.enter_context(host_lock(settings.data_dir))
        sqlite_store = SqliteStore(settings.sqlite_path)
        resources.callback(sqlite_store.close)
        sqlite_store.init_schema()

        tag_alias_service = TagAliasService.load_default(
            project_root / "assets" / "config" / "tag_aliases.json"
        )
        metadata_store = MetadataStore(sqlite_store, tag_alias_service=tag_alias_service)
        index_service = MediaIndexService(sqlite_store)
        stream_service = MediaStreamService(metadata_store, settings)
        thumbnail_service = ThumbnailService(metadata_store, settings.thumbs_dir)
        resources.callback(thumbnail_service.close)
        url_download_service = UrlDownloadService()

        app.state.settings = settings
        app.state.device_tokens = DeviceTokens(settings.data_dir / "device_tokens.sqlite")
        app.state.sqlite_store = sqlite_store
        app.state.metadata_store = metadata_store
        app.state.index_service = index_service
        app.state.stream_service = stream_service
        app.state.thumbnail_service = thumbnail_service
        app.state.pdf_edit_service = PdfEditService(metadata_store, index_service, thumbnail_service, settings)
        app.state.url_download_service = url_download_service
        app.state.url_download_statuses = {}
        app.state.client_app_versions = set()

        if settings.startup_rescan and settings.media_roots:
            index_service.rescan_configured_roots(settings.media_roots)

        seeded_stats = metadata_store.seed_missing_media_stats()
        if seeded_stats:
            logger.info("Seeded media stats for %s PDF(s)", seeded_stats)

        backfill_result = metadata_store.backfill_configured_tag_aliases()
        if backfill_result["removedAliasCount"] or backfill_result["migratedLinkCount"]:
            logger.info(
                "Tag alias backfill completed removedAliases=%s migratedLinks=%s",
                backfill_result["removedAliasCount"],
                backfill_result["migratedLinkCount"],
            )

        app.state.generated_library = None
        if settings.comfy_output_dir or settings.generated_library_dir:
            try:
                from server.services.auth_service import authentication_configured
                if not (settings.comfy_output_dir and settings.generated_library_dir and authentication_configured(app.state)):
                    raise ValueError("Set both generated-library paths and a bearer token")
                library = GeneratedLibrary(settings.comfy_output_dir, settings.generated_library_dir,
                                           [*settings.media_roots, web_build_dir, settings.thumbs_dir,
                                            settings.sqlite_path, settings.xviewer_saved_images_dir])
                library.start()
                resources.callback(library.close)
                app.state.generated_library = library
            except (ValueError, OSError, sqlite3.Error):
                logger.exception("Generated library disabled; existing media services remain available")
        app.state.generation_jobs = None
        if settings.comfy_url or settings.comfy_presets_path:
            try:
                if not (app.state.generated_library and settings.comfy_url and settings.comfy_presets_path):
                    raise ValueError("Enable the generated library and configure ComfyUI URL and presets")
                jobs = GenerationJobs(app.state.generated_library, settings.comfy_url, settings.comfy_presets_path,
                                      getattr(settings, "generation_timeout_seconds", 21600))
                jobs.start()
                resources.callback(jobs.close)
                app.state.generation_jobs = jobs
            except (ValueError, OSError, sqlite3.Error, KeyError, TypeError):
                logger.exception("Remote generation disabled; check host preset configuration")
        try:
            persist_host_settings(settings)
        except OSError:
            logger.exception("Could not persist maintenance settings")
        yield


app = FastAPI(
    title=settings.service_name,
    version=settings.version,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin for origin in settings.cors_allow_origins if origin != "*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=EXPOSED_RESPONSE_HEADERS,
)
app.add_middleware(PrivateAccessMiddleware, allowed_networks=settings.allowed_networks,
                   allowed_origins=settings.cors_allow_origins)


@app.exception_handler(sqlite3.OperationalError)
async def database_unavailable(request, error):
    message = str(error).lower()
    if any(reason in message for reason in ("locked", "busy", "full")):
        return JSONResponse({"detail": "保存先を一時的に利用できません。空き容量と接続状態を確認して再試行してください"},
                            status_code=503, headers={"Retry-After": "2"})
    logger.error("SQLite operation failed", exc_info=(type(error), error, error.__traceback__))
    return JSONResponse({"detail": "データベースを確認してください"}, status_code=500)


@app.middleware("http")
async def record_client_app_version(request, call_next):
    version = (request.headers.get(CLIENT_APP_VERSION_HEADER) or "").strip()
    if version:
        client_versions = getattr(request.app.state, "client_app_versions", set())
        client_versions.add(version[:80])
        request.app.state.client_app_versions = client_versions
    return await call_next(request)


app.include_router(health_router)
app.include_router(host_update_router)
app.include_router(tags_router)
app.include_router(search_router)
app.include_router(actions_router)
app.include_router(media_router)
app.include_router(generated_router)
app.include_router(sync_router)
app.include_router(generation_jobs_router)

mount_web_build(app, web_build_dir, logger=logger)
