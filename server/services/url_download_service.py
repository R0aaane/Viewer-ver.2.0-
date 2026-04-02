from __future__ import annotations

import asyncio
import inspect
import json
import os
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable


_UI_EVENT_PREFIX = "__KEMONO_DL_UI__"

UrlDownloadEventHandler = Callable[[dict[str, object]], Awaitable[None] | None]


@dataclass(slots=True)
class UrlDownloadResult:
    imported_count: int = 0
    skipped_count: int = 0
    failed_count: int = 0
    total_count: int = 0
    completed_count: int = 0
    status: str = "idle"
    current_file: str | None = None
    log_lines: list[str] = field(default_factory=list)
    hitomi_metadata_by_relative_path: dict[str, dict[str, object]] = field(default_factory=dict)

@dataclass(slots=True)
class UrlDownloadOptions:
    cookie_file_path: str | None = None
    cookie_mode: str = 'auto'
    url_list_file_path: str | None = None
    sites: list[str] = field(default_factory=list)
    favorite_posts: bool = False
    favorite_user_services: list[str] = field(default_factory=list)
    media_type: str = "all"
    parallel_downloads: int = 6
    include_inline_images: bool = False
    include_post_content: bool = False
    include_comments: bool = False
    save_json: bool = False
    overwrite_existing_files: bool = False
    verbose: bool = False
    convert_hitomi_to_pdf: bool = True

    def collect_source_urls(self, source_url: str) -> list[str]:
        urls: list[str] = []
        seen: set[str] = set()
        for chunk in source_url.replace(",", "\n").splitlines():
            trimmed = chunk.strip()
            if not trimmed or trimmed in seen:
                continue
            seen.add(trimmed)
            urls.append(trimmed)
        return urls

    @property
    def normalized_sites(self) -> list[str]:
        sites: list[str] = []
        seen: set[str] = set()
        for site in self.sites:
            normalized = site.strip().lower()
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            sites.append(normalized)
        return sites

    @property
    def normalized_favorite_user_services(self) -> list[str]:
        services: list[str] = []
        seen: set[str] = set()
        for service in self.favorite_user_services:
            normalized = service.strip().lower()
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            services.append(normalized)
        return services

    @property
    def has_favorite_sources(self) -> bool:
        return self.favorite_posts or bool(self.normalized_favorite_user_services)

    def has_any_source(self, source_url: str) -> bool:
        return bool(
            self.collect_source_urls(source_url)
            or (self.url_list_file_path or '').strip()
            or self.has_favorite_sources
        )

    @property
    def effective_parallel_downloads(self) -> int:
        return max(1, int(self.parallel_downloads or 1))


class UrlDownloadError(RuntimeError):
    pass


class UrlDownloadService:
    def __init__(
        self,
        *,
        workdir: str | Path | None = None,
        module_name: str = "server.kemono_download_task",
    ) -> None:
        self._workdir = str(Path(workdir or Path(__file__).resolve().parents[2]))
        self._module_name = module_name

    async def download_url(
        self,
        *,
        source_url: str,
        destination_folder: str,
        options: UrlDownloadOptions | None = None,
        on_event: UrlDownloadEventHandler | None = None,
    ) -> UrlDownloadResult:
        effective_options = options or UrlDownloadOptions()
        if not effective_options.has_any_source(source_url):
            raise UrlDownloadError("Provide a URL, URL list file, or favorites condition")
        if effective_options.has_favorite_sources:
            cookie_file_path = (effective_options.cookie_file_path or "").strip()
            if effective_options.cookie_mode == "none" or (
                effective_options.cookie_mode == "custom" and not cookie_file_path
            ):
                raise UrlDownloadError("Favorites import requires a cookie")
            if not effective_options.normalized_sites:
                raise UrlDownloadError("Favorites import requires at least one target site")

        result = UrlDownloadResult(status="starting")
        log_lines: deque[str] = deque(maxlen=80)
        event_seen = False
        process_args = [
            sys.executable,
            "-X",
            "utf8",
            "-m",
            self._module_name,
            "--dest",
            destination_folder,
            *self._build_task_args(source_url, effective_options),
        ]
        process = await asyncio.create_subprocess_exec(
            *process_args,
            cwd=self._workdir,
            env={**os.environ, "PYTHONUTF8": "1"},
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        async def read_stdout() -> None:
            nonlocal event_seen
            assert process.stdout is not None
            while True:
                raw_line = await process.stdout.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", errors="replace").rstrip()
                if not line:
                    continue
                if line.startswith(_UI_EVENT_PREFIX):
                    event_seen = True
                    try:
                        event = json.loads(line[len(_UI_EVENT_PREFIX) :])
                    except json.JSONDecodeError:
                        log_lines.append(f"[stdout] {line}")
                        continue
                    _apply_event(result, event, destination_folder=destination_folder)
                    if on_event is not None:
                        maybe_awaitable = on_event(event)
                        if inspect.isawaitable(maybe_awaitable):
                            await maybe_awaitable
                    continue
                log_lines.append(f"[stdout] {line}")

        async def read_stderr() -> None:
            assert process.stderr is not None
            while True:
                raw_line = await process.stderr.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", errors="replace").rstrip()
                if line:
                    log_lines.append(f"[stderr] {line}")

        await asyncio.gather(read_stdout(), read_stderr())
        return_code = await process.wait()

        result.log_lines = list(log_lines)
        if return_code != 0:
            raise UrlDownloadError(_tail_message(result.log_lines, return_code))
        if not event_seen:
            raise UrlDownloadError("Downloader progress events were not received")
        return result

    def _build_task_args(self, source_url: str, options: UrlDownloadOptions) -> list[str]:
        args: list[str] = []
        for url in options.collect_source_urls(source_url):
            args.extend(["--url", url])

        cookie_file_path = (options.cookie_file_path or "").strip()
        args.extend(["--cookie-mode", options.cookie_mode])
        if cookie_file_path:
            args.extend(["--cookies", cookie_file_path])

        url_list_file_path = (options.url_list_file_path or "").strip()
        if url_list_file_path:
            args.extend(["--from-file", url_list_file_path])

        sites = options.normalized_sites
        if sites:
            args.extend(["--sites", ",".join(sites)])
        if options.favorite_posts:
            args.append("--fav-posts")

        favorite_user_services = options.normalized_favorite_user_services
        if favorite_user_services:
            args.extend(["--fav-users", ",".join(favorite_user_services)])

        args.extend(["--media-type", options.media_type])
        args.extend(["--parallel-downloads", str(options.effective_parallel_downloads)])

        if options.include_inline_images:
            args.append("--inline")
        if options.include_post_content:
            args.append("--content")
        if options.include_comments:
            args.append("--comments")
        if options.save_json:
            args.append("--json")
        if options.overwrite_existing_files:
            args.append("--overwrite")
        if options.verbose:
            args.append('--verbose')
        if options.convert_hitomi_to_pdf:
            args.append('--hitomi-pdf')

        return args


def _apply_event(
    result: UrlDownloadResult,
    event: dict[str, object],
    *,
    destination_folder: str,
) -> None:
    event_type = str(event.get("type") or "").strip().lower()
    if event_type == "hitomi_metadata":
        relative_key = _relative_key_from_path(
            event.get("pdf_path"),
            destination_folder=destination_folder,
        )
        if relative_key is not None:
            result.hitomi_metadata_by_relative_path[relative_key] = {
                "artists": _string_list(event.get("artists")),
                "groups": _string_list(event.get("groups")),
                "series": _string_list(event.get("series")),
                "characters": _string_list(event.get("characters")),
                "tags": _string_list(event.get("tags")),
                "title": _string_or_none(event.get("title")),
                "english_title": _string_or_none(event.get("english_title")),
                "japanese_title": _string_or_none(event.get("japanese_title")),
                "media_type": _string_or_none(event.get("media_type")),
                "language": _string_or_none(event.get("language")),
                "source_url": _string_or_none(event.get("source_url")),
                "reader_url": _string_or_none(event.get("reader_url")),
            }
        return

    result.total_count = _as_int(event.get("total"), default=result.total_count)
    result.completed_count = _as_int(
        event.get("completed"),
        default=result.completed_count,
    )
    result.imported_count = _as_int(event.get("success"), default=result.imported_count)
    result.failed_count = _as_int(event.get("failed"), default=result.failed_count)
    result.skipped_count = _as_int(event.get("skipped"), default=result.skipped_count)
    status = event.get("status")
    if isinstance(status, str) and status.strip():
        result.status = status
    current_file = event.get("current_file")
    if isinstance(current_file, str) and current_file.strip():
        result.current_file = current_file


def _relative_key_from_path(value: object, *, destination_folder: str) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        normalized_path = os.path.normpath(value)
        normalized_root = os.path.normpath(destination_folder)
        if normalized_path == normalized_root:
            return None
        relative_path = os.path.relpath(normalized_path, normalized_root)
    except ValueError:
        return None
    if relative_path.startswith(".."):
        return None
    return relative_path.replace("\\", "/").casefold()


def _string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    items: list[str] = []
    for entry in value:
        text = str(entry or "").strip()
        if text:
            items.append(text)
    return items


def _string_or_none(value: object) -> str | None:
    text = str(value or "").strip()
    return text or None


def _as_int(value: object, *, default: int) -> int:
    if value is None:
        return default
    if isinstance(value, int):
        return value
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return default


def _tail_message(log_lines: list[str], return_code: int) -> str:
    if log_lines:
        return log_lines[-1]
    return f"驛｢謨鳴驛｢・ｧ繝ｻ・ｦ驛｢譎｢・ｽ・ｳ驛｢譎｢・ｽ・ｭ驛｢譎｢・ｽ・ｼ驛｢謨鳴驛｢譎｢・ｽ・ｼ驍ｵ・ｺ隶吝ｮ医・髯晢ｽｶ繝ｻ・ｸ鬩搾ｽｨ郢ｧ繝ｻ・ｽ・ｺ郢晢ｽｻ繝ｻ・ｰ驍ｵ・ｺ繝ｻ・ｾ驍ｵ・ｺ陷会ｽｱ隨ｳ繝ｻ(exit={return_code})"
