from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from server.api.routes_actions import router as actions_router
from server.api.routes_health import router as health_router
from server.api.routes_media import router as media_router
from server.api.routes_search import router as search_router
from server.api.routes_tags import router as tags_router
from server.core.config import load_settings
from server.core.logging import configure_logging
from server.repositories.sqlite_store import SqliteStore
from server.services.media_index_service import MediaIndexService
from server.services.media_stream_service import MediaStreamService
from server.services.metadata_store import MetadataStore
from server.services.thumbnail_service import ThumbnailService
from server.services.url_download_service import UrlDownloadService
from server.web_static import mount_web_build


settings = load_settings()
configure_logging(settings.log_level)
logger = logging.getLogger(__name__)
project_root = Path(__file__).resolve().parents[1]
web_build_dir = Path(
    os.getenv("MEDIA_SERVER_WEB_BUILD_DIR") or str(project_root / "build" / "web")
).resolve()


@asynccontextmanager
async def lifespan(app: FastAPI):
    sqlite_store = SqliteStore(settings.sqlite_path)
    sqlite_store.init_schema()

    metadata_store = MetadataStore(sqlite_store)
    index_service = MediaIndexService(sqlite_store)
    stream_service = MediaStreamService(metadata_store, settings)
    thumbnail_service = ThumbnailService(metadata_store, settings.thumbs_dir)
    url_download_service = UrlDownloadService()

    app.state.settings = settings
    app.state.sqlite_store = sqlite_store
    app.state.metadata_store = metadata_store
    app.state.index_service = index_service
    app.state.stream_service = stream_service
    app.state.thumbnail_service = thumbnail_service
    app.state.url_download_service = url_download_service

    if settings.startup_rescan and settings.media_roots:
        index_service.rescan_configured_roots(settings.media_roots)

    try:
        yield
    finally:
        sqlite_store.close()


app = FastAPI(
    title=settings.service_name,
    version=settings.version,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allow_origins or ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(tags_router)
app.include_router(search_router)
app.include_router(actions_router)
app.include_router(media_router)

mount_web_build(app, web_build_dir, logger=logger)
