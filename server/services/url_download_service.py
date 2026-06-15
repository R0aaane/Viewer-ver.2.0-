from __future__ import annotations

import asyncio
import hashlib
import html
import inspect
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Awaitable, Callable


_UI_EVENT_PREFIX = "__KEMONO_DL_UI__"
_LAUNCHER_IDLE_TIMEOUT_SECONDS = 600
_CONTENT_DISPOSITION_HEADER = "Content-Disposition"
_STANDALONE_USER_AGENT = "pdf_viewer/standalone"
_MEDIA_ACCEPT_HEADER = "application/pdf,image/*,*/*;q=0.8"
_DDD_SMART_HOST = "ddd-smart.net"
_DDD_SMART_CDN_HOST = "cdn.ddd-smart.net"
_HITOMI_NOZOMI_HOSTS = (
    "ltn.gold-usergeneratedcontent.net",
    "ltn.hitomi.la",
)
_HITOMI_INDEX_HOST = "ltn.gold-usergeneratedcontent.net"
_HITOMI_GALLERIES_INDEX_DIR = "galleriesindex"
_HITOMI_INDEX_NODE_SIZE = 464
_HITOMI_BTREE_ORDER = 16
_SUPPORTED_HITOMI_SEARCH_NAMESPACES = {
    "artist",
    "group",
    "series",
    "character",
    "tag",
    "type",
    "language",
    "male",
    "female",
}
_HITOMI_BARE_TYPE_ALIASES = {
    "manga": "manga",
    "comic": "manga",
    "comics": "manga",
    "doujinshi": "doujinshi",
    "doujin": "doujinshi",
    "cg": "cg",
    "gamecg": "gamecg",
    "game": "gamecg",
    "imageset": "imageset",
    "image": "imageset",
    "images": "imageset",
}
_HITOMI_BARE_SEARCH_AREAS = (
    "artist",
    "group",
    "series",
    "character",
    "tag",
)
_LAUNCHER_SUPPORTED_HITOMI_SEGMENTS = {
    "manga",
    "doujinshi",
    "cg",
    "gamecg",
    "imageset",
    "group",
    "galleries",
    "reader",
}
_SUPPORTED_MEDIA_EXTENSIONS = {
    ".pdf",
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".webp",
    ".bmp",
    ".avif",
}

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
    hitomi_metadata_by_relative_path: dict[str, dict[str, object]] = field(
        default_factory=dict
    )


@dataclass(slots=True)
class UrlDownloadOptions:
    cookie_file_path: str | None = None
    cookie_mode: str = "auto"
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
    prefer_hitomi_original: bool = False

    def collect_source_urls(self, source_url: str) -> list[str]:
        urls: list[str] = []
        seen: set[str] = set()
        matched_urls = re.findall(
            r"https?://[^\s,]+",
            source_url or "",
            flags=re.IGNORECASE,
        )
        segments = matched_urls or re.split(r"[\s,]+", source_url or "")
        for chunk in segments:
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
            or (self.url_list_file_path or "").strip()
            or self.has_favorite_sources
        )

    @property
    def effective_parallel_downloads(self) -> int:
        return max(1, int(self.parallel_downloads or 1))


@dataclass(slots=True)
class _PreparedUrlImportSources:
    launcher_urls: list[str] = field(default_factory=list)
    direct_urls: list[str] = field(default_factory=list)
    metadata_by_direct_url: dict[str, dict[str, object]] = field(
        default_factory=dict
    )

    @property
    def has_launcher_urls(self) -> bool:
        return bool(self.launcher_urls)

    @property
    def is_empty(self) -> bool:
        return not self.launcher_urls and not self.direct_urls


@dataclass(slots=True)
class _ResolvedDirectUrl:
    url: str
    metadata: dict[str, object] | None = None


@dataclass(slots=True)
class _HitomiSearchState:
    area: str = "all"
    tag: str = "index"
    language: str = "all"
    order_by: str = "date"
    order_by_key: str | None = None
    order_by_direction: str = "desc"

    def normalized(self) -> "_HitomiSearchState":
        return replace(
            self,
            order_by_key=self.order_by_key
            if self.order_by_key is not None
            else ("year" if self.order_by == "popular" else "added"),
        )


@dataclass(slots=True)
class _HitomiParsedSearchQuery:
    state: _HitomiSearchState
    positive_terms: list[str] = field(default_factory=list)
    negative_terms: list[str] = field(default_factory=list)
    or_terms: list[list[str]] = field(default_factory=list)


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
            raise UrlDownloadError(
                "Provide a URL, URL list file, or favorites condition"
            )
        if effective_options.has_favorite_sources:
            cookie_file_path = (effective_options.cookie_file_path or "").strip()
            if effective_options.cookie_mode == "none" or (
                effective_options.cookie_mode == "custom" and not cookie_file_path
            ):
                raise UrlDownloadError("Favorites import requires a cookie")
            if not effective_options.normalized_sites:
                raise UrlDownloadError(
                    "Favorites import requires at least one target site"
                )

        prepared = await self._prepare_import_sources(source_url, effective_options)
        if prepared.is_empty and not effective_options.has_favorite_sources:
            raise UrlDownloadError("No downloadable URLs were found")

        launcher_options = self._copy_options_without_url_list_file(effective_options)
        direct_options = self._copy_options_for_direct_download(effective_options)
        results: list[UrlDownloadResult] = []

        if effective_options.has_favorite_sources or prepared.has_launcher_urls:
            launcher_results = await self._run_launcher_batches(
                launcher_urls=prepared.launcher_urls,
                destination_folder=destination_folder,
                options=launcher_options,
                has_favorite_sources=effective_options.has_favorite_sources,
                on_event=on_event,
            )
            results.extend(launcher_results)

        if prepared.direct_urls:
            direct_result = await self._run_direct_url_download_urls(
                urls=prepared.direct_urls,
                destination_folder=destination_folder,
                options=direct_options,
                metadata_by_url=prepared.metadata_by_direct_url,
                on_event=on_event,
            )
            results.append(direct_result)

        return self._merge_download_results(results)

    async def _run_launcher_batches(
        self,
        *,
        launcher_urls: list[str],
        destination_folder: str,
        options: UrlDownloadOptions,
        has_favorite_sources: bool,
        on_event: UrlDownloadEventHandler | None = None,
    ) -> list[UrlDownloadResult]:
        if has_favorite_sources or len(launcher_urls) <= 1:
            return [
                await self._run_with_launcher(
                    source_url="\n".join(launcher_urls),
                    destination_folder=destination_folder,
                    options=options,
                    on_event=on_event,
                )
            ]

        batch_size = min(max(1, options.effective_parallel_downloads), 8)
        batches = [
            launcher_urls[index : index + batch_size]
            for index in range(0, len(launcher_urls), batch_size)
        ]
        results: list[UrlDownloadResult] = []
        for index, batch in enumerate(batches):
            if on_event is not None:
                event = {
                    "type": "progress",
                    "total": len(batches),
                    "completed": index,
                    "success": sum(result.imported_count for result in results),
                    "failed": sum(result.failed_count for result in results),
                    "skipped": sum(result.skipped_count for result in results),
                    "status": f"URL batch {index + 1}/{len(batches)}",
                }
                maybe_awaitable = on_event(event)
                if inspect.isawaitable(maybe_awaitable):
                    await maybe_awaitable
            results.append(
                await self._run_with_launcher(
                    source_url="\n".join(batch),
                    destination_folder=destination_folder,
                    options=options,
                    on_event=on_event,
                )
            )
        return results

    async def _run_with_launcher(
        self,
        *,
        source_url: str,
        destination_folder: str,
        options: UrlDownloadOptions,
        on_event: UrlDownloadEventHandler | None = None,
    ) -> UrlDownloadResult:
        result = UrlDownloadResult(status="starting")
        log_lines: deque[str] = deque(maxlen=80)
        event_seen = False
        last_output_at = asyncio.get_running_loop().time()
        process_args = [
            sys.executable,
            "-X",
            "utf8",
            "-m",
            self._module_name,
            "--dest",
            destination_folder,
            *self._build_task_args(source_url, options),
        ]
        process = await asyncio.create_subprocess_exec(
            *process_args,
            cwd=self._workdir,
            env={
                **os.environ,
                "PYTHONUTF8": "1",
                "KEMONO_DL_REQUEST_TIMEOUT": os.environ.get(
                    "KEMONO_DL_REQUEST_TIMEOUT",
                    "60",
                ),
                "KEMONO_DL_CONNECT_TIMEOUT": os.environ.get(
                    "KEMONO_DL_CONNECT_TIMEOUT",
                    "8",
                ),
                "KEMONO_DL_FILE_RETRY": os.environ.get(
                    "KEMONO_DL_FILE_RETRY",
                    "1",
                ),
                "KEMONO_DL_DATA_FAILURE_LIMIT": os.environ.get(
                    "KEMONO_DL_DATA_FAILURE_LIMIT",
                    "6",
                ),
                "KEMONO_DL_STARTUP_TIMEOUT": os.environ.get(
                    "KEMONO_DL_STARTUP_TIMEOUT",
                    "15",
                ),
            },
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        async def read_stdout() -> None:
            nonlocal event_seen, last_output_at
            assert process.stdout is not None
            while True:
                raw_line = await process.stdout.readline()
                if not raw_line:
                    break
                last_output_at = asyncio.get_running_loop().time()
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
                    _apply_event(
                        result,
                        event,
                        destination_folder=destination_folder,
                    )
                    if on_event is not None:
                        maybe_awaitable = on_event(event)
                        if inspect.isawaitable(maybe_awaitable):
                            await maybe_awaitable
                    continue
                log_lines.append(f"[stdout] {line}")

        async def read_stderr() -> None:
            nonlocal last_output_at
            assert process.stderr is not None
            while True:
                raw_line = await process.stderr.readline()
                if not raw_line:
                    break
                last_output_at = asyncio.get_running_loop().time()
                line = raw_line.decode("utf-8", errors="replace").rstrip()
                if line:
                    log_lines.append(f"[stderr] {line}")

        async def monitor_idle_timeout() -> None:
            while True:
                return_code = process.returncode
                if return_code is not None:
                    return
                idle_seconds = asyncio.get_running_loop().time() - last_output_at
                if idle_seconds >= _LAUNCHER_IDLE_TIMEOUT_SECONDS:
                    log_lines.append(
                        "[error] downloader produced no output for "
                        f"{_LAUNCHER_IDLE_TIMEOUT_SECONDS} seconds"
                    )
                    process.kill()
                    return
                await asyncio.sleep(5)

        await asyncio.gather(read_stdout(), read_stderr(), monitor_idle_timeout())
        return_code = await process.wait()

        result.log_lines = list(log_lines)
        timed_out = any("downloader produced no output" in line for line in log_lines)
        if timed_out:
            raise UrlDownloadError(
                "Downloader stopped after producing no output for "
                f"{_LAUNCHER_IDLE_TIMEOUT_SECONDS} seconds. "
                f"{_tail_message(result.log_lines, return_code)}"
            )
        if return_code != 0:
            raise UrlDownloadError(_tail_message(result.log_lines, return_code))
        if not event_seen:
            raise UrlDownloadError("Downloader progress events were not received")
        return result

    async def search_hitomi_galleries(
        self,
        *,
        query: str,
        limit: int = 50,
    ) -> list[dict[str, object]]:
        trimmed = (query or "").strip()
        if not trimmed:
            return []
        safe_limit = max(1, min(int(limit or 50), 100))
        return await asyncio.to_thread(
            self._search_hitomi_galleries_sync,
            trimmed,
            safe_limit,
        )

    def _search_hitomi_galleries_sync(
        self,
        query: str,
        limit: int,
    ) -> list[dict[str, object]]:
        gallery_ids = self._resolve_hitomi_search_gallery_ids(query)[:limit]
        return [
            self._fetch_hitomi_search_result(gallery_id)
            for gallery_id in gallery_ids
        ]

    def _fetch_hitomi_search_result(self, gallery_id: int) -> dict[str, object]:
        gallery_url = f"https://hitomi.la/galleries/{gallery_id}.html"
        url = f"https://{_HITOMI_INDEX_HOST}/galleries/{gallery_id}.js"
        try:
            payload = self._download_html(url)
            info = self._decode_hitomi_gallery_info(payload)
            if info is not None:
                return self._hitomi_search_result_from_info(
                    gallery_id=gallery_id,
                    gallery_url=gallery_url,
                    info=info,
                )
        except Exception:
            pass
        return {
            "galleryId": gallery_id,
            "title": f"Gallery {gallery_id}",
            "galleryUrl": gallery_url,
        }

    def _decode_hitomi_gallery_info(self, payload: str) -> dict[str, object] | None:
        marker = re.search(r"galleryinfo\s*=", payload)
        if marker is None:
            return None
        brace_start = payload.find("{", marker.end())
        if brace_start < 0:
            return None
        depth = 0
        in_string = False
        escaped = False
        for index in range(brace_start, len(payload)):
            char = payload[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue
            if char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    decoded = json.loads(payload[brace_start : index + 1])
                    return decoded if isinstance(decoded, dict) else None
        return None

    def _hitomi_search_result_from_info(
        self,
        *,
        gallery_id: int,
        gallery_url: str,
        info: dict[str, object],
    ) -> dict[str, object]:
        thumbnail_urls: list[str] = []
        files = info.get("files")
        if isinstance(files, list) and files and isinstance(files[0], dict):
            thumbnail_urls = self._build_hitomi_thumbnail_urls(files[0])
        series = self._hitomi_field_names(info.get("series"))
        if not series:
            series = self._hitomi_field_names(info.get("parodys"))
        return {
            "galleryId": gallery_id,
            "title": (
                self._trimmed(info.get("japanese_title"))
                or self._trimmed(info.get("title"))
                or self._trimmed(info.get("english_title"))
                or f"Gallery {gallery_id}"
            ),
            "type": self._trimmed(info.get("type")),
            "language": (
                self._trimmed(info.get("language_localname"))
                or self._first_hitomi_field_name(info.get("languages"))
                or self._trimmed(info.get("language"))
            ),
            "date": self._trimmed(info.get("date")),
            "artists": self._hitomi_field_names(info.get("artists")),
            "groups": self._hitomi_field_names(info.get("groups")),
            "series": series,
            "characters": self._hitomi_field_names(info.get("characters")),
            "tags": self._hitomi_field_names(info.get("tags")),
            "galleryUrl": gallery_url,
            "thumbnailUrl": thumbnail_urls[0] if thumbnail_urls else None,
            "thumbnailUrls": thumbnail_urls,
        }

    def _build_hitomi_thumbnail_urls(self, file_info: dict[object, object]) -> list[str]:
        file_hash = self._trimmed(file_info.get("hash"))
        if file_hash is None or len(file_hash) < 3:
            return []
        name = self._trimmed(file_info.get("name")) or "image.jpg"
        original_ext = name.rsplit(".", 1)[-1].lower() if "." in name else "jpg"
        left = file_hash[-1:]
        right = file_hash[-3:-1]
        thumb_path = f"{left}/{right}/{file_hash}"
        urls: list[str] = []
        for subdomain in ("atn", "btn", "ctn"):
            urls.append(
                f"https://{subdomain}.gold-usergeneratedcontent.net/webpsmalltn/{thumb_path}.webp"
            )
        if self._trimmed(file_info.get("hasavif")) == "1":
            for subdomain in ("atn", "btn", "ctn"):
                urls.append(
                    f"https://{subdomain}.gold-usergeneratedcontent.net/avifsmalltn/{thumb_path}.avif"
                )
        for subdomain in ("atn", "btn", "ctn"):
            urls.append(
                f"https://{subdomain}.gold-usergeneratedcontent.net/smalltn/{thumb_path}.{original_ext}"
            )
        return urls

    def _first_hitomi_field_name(self, value: object) -> str | None:
        values = self._hitomi_field_names(value)
        return values[0] if values else None

    def _hitomi_field_names(self, value: object) -> list[str]:
        out: list[str] = []
        seen: set[str] = set()

        def add(raw: object) -> None:
            text = self._trimmed(raw)
            key = text.lower() if text is not None else ""
            if text is not None and key not in seen:
                seen.add(key)
                out.append(text)

        if isinstance(value, list):
            for entry in value:
                if isinstance(entry, dict):
                    add(
                        entry.get("name")
                        or entry.get("artist")
                        or entry.get("group")
                        or entry.get("parody")
                        or entry.get("character")
                        or entry.get("tag")
                        or entry.get("language_localname")
                    )
                else:
                    add(entry)
        elif isinstance(value, dict):
            add(
                value.get("name")
                or value.get("artist")
                or value.get("group")
                or value.get("parody")
                or value.get("character")
                or value.get("tag")
                or value.get("language_localname")
            )
        else:
            add(value)
        return out

    def _trimmed(self, value: object) -> str | None:
        text = "" if value is None else str(value).strip()
        return text or None

    async def _prepare_import_sources(
        self,
        source_url: str,
        options: UrlDownloadOptions,
    ) -> _PreparedUrlImportSources:
        launcher_urls: list[str] = []
        direct_urls: list[str] = []
        metadata_by_direct_url: dict[str, dict[str, object]] = {}
        launcher_seen: set[str] = set()
        direct_seen: set[str] = set()

        for raw_url in await self._collect_input_urls(source_url, options):
            expanded_launcher_urls = await self._resolve_expanded_launcher_urls(
                raw_url
            )
            if expanded_launcher_urls is not None:
                for launcher_url in expanded_launcher_urls:
                    if launcher_url not in launcher_seen:
                        launcher_seen.add(launcher_url)
                        launcher_urls.append(launcher_url)
                continue

            resolved_direct_url = await asyncio.to_thread(
                self._resolve_special_direct_url,
                raw_url,
            )
            if resolved_direct_url is not None:
                if resolved_direct_url.url not in direct_seen:
                    direct_seen.add(resolved_direct_url.url)
                    direct_urls.append(resolved_direct_url.url)
                if resolved_direct_url.metadata is not None:
                    metadata_by_direct_url[resolved_direct_url.url] = (
                        resolved_direct_url.metadata
                    )
                continue

            if raw_url not in direct_seen:
                direct_seen.add(raw_url)
                direct_urls.append(raw_url)

        return _PreparedUrlImportSources(
            launcher_urls=launcher_urls,
            direct_urls=direct_urls,
            metadata_by_direct_url=metadata_by_direct_url,
        )

    async def _resolve_expanded_launcher_urls(
        self,
        raw_url: str,
    ) -> list[str] | None:
        if self._supports_launcher_url(raw_url):
            return [raw_url.strip()]

        parsed = urllib.parse.urlparse(raw_url.strip())
        if parsed.scheme not in {"http", "https"}:
            return None
        if parsed.netloc.lower() != "hitomi.la" or not self._is_hitomi_search_url(
            parsed
        ):
            return None

        return await asyncio.to_thread(
            self._resolve_hitomi_search_launcher_urls,
            parsed,
        )

    def _is_hitomi_search_url(
        self,
        parsed: urllib.parse.ParseResult,
    ) -> bool:
        path = parsed.path.lower()
        return path == "/search.html" or path.endswith("/search.html")

    def _resolve_hitomi_search_launcher_urls(
        self,
        parsed: urllib.parse.ParseResult,
    ) -> list[str]:
        query_text = urllib.parse.unquote(parsed.query or "").strip()
        if not query_text:
            return []

        gallery_ids = self._resolve_hitomi_search_gallery_ids(query_text)
        if not gallery_ids:
            gallery_ids = self._resolve_hitomi_search_gallery_ids_from_html(parsed)
        return [f"https://hitomi.la/galleries/{gallery_id}.html" for gallery_id in gallery_ids]

    def _resolve_hitomi_search_gallery_ids(self, query_text: str) -> list[int]:
        parsed = self._parse_hitomi_search_query(query_text)
        state = parsed.state.normalized()
        remaining_positive_terms = list(parsed.positive_terms)

        if not remaining_positive_terms:
            results = self._download_hitomi_nozomi_gallery_ids(state)
        else:
            first_term = remaining_positive_terms.pop(0)
            results = self._resolve_hitomi_gallery_ids_for_term(first_term, state)

        for terms in parsed.or_terms:
            if not terms:
                continue
            matched_ids: set[int] = set()
            for term in terms:
                matched_ids.update(self._resolve_hitomi_gallery_ids_for_term(term, state))
            results = [gallery_id for gallery_id in results if gallery_id in matched_ids]

        for term in remaining_positive_terms:
            matched_ids = set(self._resolve_hitomi_gallery_ids_for_term(term, state))
            results = [gallery_id for gallery_id in results if gallery_id in matched_ids]

        for term in parsed.negative_terms:
            matched_ids = set(self._resolve_hitomi_gallery_ids_for_term(term, state))
            results = [gallery_id for gallery_id in results if gallery_id not in matched_ids]

        if state.order_by_direction in {"asc", "ascending"}:
            results.reverse()
        return results

    def _parse_hitomi_search_query(
        self,
        query_text: str,
    ) -> _HitomiParsedSearchQuery:
        state = _HitomiSearchState()
        terms = [
            self._normalize_hitomi_search_term(term)
            for term in re.split(r"\s+", query_text.lower().strip())
            if term.strip()
        ]
        positive_terms: list[str] = []
        negative_terms: list[str] = []
        or_terms: list[list[str]] = [[]]

        for index, term in enumerate(terms):
            next_state = self._next_hitomi_search_state_for_ordering_term(term, state)
            if next_state is not None:
                state = next_state
                continue
            if term == "or":
                continue

            or_previous = index > 0 and terms[index - 1] == "or"
            or_next = index + 1 < len(terms) and terms[index + 1] == "or"
            if or_previous or or_next:
                or_terms[-1].append(term)
                if not or_next:
                    or_terms.append([])
                continue

            if term.startswith("-"):
                negative_term = term[1:].strip()
                if negative_term:
                    negative_terms.append(negative_term)
                continue
            positive_terms.append(term)

        positive_terms.sort(
            key=lambda term: 0 if self._is_hitomi_namespaced_term(term) else 1
        )
        return _HitomiParsedSearchQuery(
            state=state,
            positive_terms=positive_terms,
            negative_terms=negative_terms,
            or_terms=[terms for terms in or_terms if terms],
        )

    def _normalize_hitomi_search_term(self, term: str) -> str:
        normalized = term.replace("_", " ").strip()
        return f"type:{_HITOMI_BARE_TYPE_ALIASES[normalized]}" if normalized in _HITOMI_BARE_TYPE_ALIASES else normalized

    def _next_hitomi_search_state_for_ordering_term(
        self,
        term: str,
        current: _HitomiSearchState,
    ) -> _HitomiSearchState | None:
        separator_index = term.find(":")
        if separator_index <= 0:
            return None
        left_side = term[:separator_index]
        right_side = term[separator_index + 1 :]
        if not re.match(r"^(?:sort|order)(?:by)?(?:key|direction)?$", left_side):
            return None

        if left_side in {"orderbykey", "sortbykey", "orderkey", "sortkey"}:
            return replace(
                current,
                order_by_key=re.sub(r"[^0-9a-z]", "", right_side),
            )
        if left_side in {"orderby", "sortby"}:
            if right_side in {"popular", "popularity"}:
                return replace(current, order_by="popular")
            if right_side == "date":
                return replace(current, order_by="date")
            if right_side == "datepublished":
                return replace(current, order_by="date", order_by_key="published")
            if right_side in {"random", "rand"}:
                return replace(current, order_by_direction="random")
            return None
        if left_side in {"orderbydirection", "sortbydirection"}:
            return replace(
                current,
                order_by_direction=re.sub(r"[^0-9a-z]", "", right_side),
            )
        return None

    def _is_hitomi_namespaced_term(self, term: str) -> bool:
        separator_index = term.find(":")
        if separator_index <= 0:
            return False
        return term[:separator_index] in _SUPPORTED_HITOMI_SEARCH_NAMESPACES

    def _assert_supported_hitomi_search_terms(self, terms: list[str]) -> None:
        for term in terms:
            if self._is_hitomi_namespaced_term(term):
                continue
            raise UrlDownloadError(
                f"Hitomi search term is not supported: {term}"
            )

    def _resolve_hitomi_gallery_ids_for_term(
        self,
        term: str,
        state: _HitomiSearchState,
    ) -> list[int]:
        if not self._is_hitomi_namespaced_term(term):
            return self._resolve_hitomi_gallery_ids_for_bare_term(term, state)

        separator_index = term.find(":")
        left_side = term[:separator_index]
        right_side = term[separator_index + 1 :]

        if left_side in {"female", "male"}:
            return self._download_hitomi_nozomi_gallery_ids(
                replace(state, area="tag", tag=term).normalized()
            )
        if left_side == "language":
            return self._download_hitomi_nozomi_gallery_ids(
                replace(state, language=right_side).normalized()
            )
        return self._download_hitomi_nozomi_gallery_ids(
            replace(state, area=left_side, tag=right_side).normalized()
        )

    def _resolve_hitomi_gallery_ids_for_bare_term(
        self,
        term: str,
        state: _HitomiSearchState,
    ) -> list[int]:
        indexed_ids = self._download_hitomi_gallery_ids_from_index(term)
        if indexed_ids:
            return indexed_ids

        results: list[int] = []
        seen: set[int] = set()
        for area in _HITOMI_BARE_SEARCH_AREAS:
            try:
                ids = self._download_hitomi_nozomi_gallery_ids(
                    replace(state, area=area, tag=term).normalized()
                )
            except UrlDownloadError:
                continue
            for gallery_id in ids:
                if gallery_id not in seen:
                    seen.add(gallery_id)
                    results.append(gallery_id)
        return results

    def _download_hitomi_gallery_ids_from_index(self, term: str) -> list[int]:
        version = self._download_hitomi_index_version(_HITOMI_GALLERIES_INDEX_DIR)
        data_range = self._hitomi_btree_search(
            field="galleries",
            key=hashlib.sha256(term.encode("utf-8")).digest()[:4],
            version=version,
        )
        if data_range is None:
            return []

        offset, length = data_range
        if length <= 0 or length > 100000000:
            return []

        payload = self._download_hitomi_index_range(
            self._hitomi_galleries_index_url(version, suffix="data"),
            offset,
            offset + length - 1,
        )
        if len(payload) < 4:
            return []
        count = int.from_bytes(payload[0:4], "big", signed=True)
        expected_length = count * 4 + 4
        if count <= 0 or count > 10000000 or len(payload) != expected_length:
            return []
        return [
            int.from_bytes(payload[pos : pos + 4], "big", signed=True)
            for pos in range(4, len(payload), 4)
        ]

    def _download_hitomi_index_version(self, name: str) -> str:
        url = f"https://{_HITOMI_INDEX_HOST}/{name}/version"
        request = urllib.request.Request(
            url,
            headers={"User-Agent": _STANDALONE_USER_AGENT},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            status_code = getattr(response, "status", response.getcode())
            if status_code < 200 or status_code >= 300:
                raise UrlDownloadError(f"HTTP {status_code} while resolving {url}")
            return response.read().decode("utf-8", errors="ignore").strip()

    def _hitomi_btree_search(
        self,
        *,
        field: str,
        key: bytes,
        version: str,
        address: int = 0,
    ) -> tuple[int, int] | None:
        node = self._download_hitomi_btree_node(field, version, address)
        if not node["keys"]:
            return None

        found = False
        index = 0
        for index, node_key in enumerate(node["keys"]):
            compare = (key > node_key) - (key < node_key)
            if compare <= 0:
                found = compare == 0
                break
        else:
            index = len(node["keys"])

        if found:
            return node["datas"][index]
        if not any(node["subnode_addresses"]):
            return None

        subnode_address = node["subnode_addresses"][index]
        if subnode_address == 0:
            return None
        return self._hitomi_btree_search(
            field=field,
            key=key,
            version=version,
            address=subnode_address,
        )

    def _download_hitomi_btree_node(
        self,
        field: str,
        version: str,
        address: int,
    ) -> dict[str, object]:
        if field != "galleries":
            raise UrlDownloadError(f"Unsupported Hitomi index field: {field}")
        payload = self._download_hitomi_index_range(
            self._hitomi_galleries_index_url(version, suffix="index"),
            address,
            address + _HITOMI_INDEX_NODE_SIZE - 1,
        )
        return self._decode_hitomi_btree_node(payload)

    def _decode_hitomi_btree_node(self, payload: bytes) -> dict[str, object]:
        pos = 0

        def read_int32() -> int:
            nonlocal pos
            value = int.from_bytes(payload[pos : pos + 4], "big", signed=True)
            pos += 4
            return value

        def read_uint64() -> int:
            nonlocal pos
            value = int.from_bytes(payload[pos : pos + 8], "big", signed=False)
            pos += 8
            return value

        keys: list[bytes] = []
        for _ in range(read_int32()):
            key_size = read_int32()
            if key_size <= 0 or key_size > 32:
                return {"keys": [], "datas": [], "subnode_addresses": []}
            keys.append(payload[pos : pos + key_size])
            pos += key_size

        datas: list[tuple[int, int]] = []
        for _ in range(read_int32()):
            offset = read_uint64()
            length = read_int32()
            datas.append((offset, length))

        subnode_addresses = [read_uint64() for _ in range(_HITOMI_BTREE_ORDER + 1)]
        return {
            "keys": keys,
            "datas": datas,
            "subnode_addresses": subnode_addresses,
        }

    def _hitomi_galleries_index_url(self, version: str, *, suffix: str) -> str:
        return (
            f"https://{_HITOMI_INDEX_HOST}/{_HITOMI_GALLERIES_INDEX_DIR}/"
            f"galleries.{version}.{suffix}"
        )

    def _download_hitomi_index_range(self, url: str, start: int, end: int) -> bytes:
        request = urllib.request.Request(
            url,
            headers={
                "Range": f"bytes={start}-{end}",
                "User-Agent": _STANDALONE_USER_AGENT,
            },
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            status_code = getattr(response, "status", response.getcode())
            if status_code not in {200, 206}:
                raise UrlDownloadError(f"HTTP {status_code} while resolving {url}")
            return response.read()

    def _download_hitomi_nozomi_gallery_ids(
        self,
        state: _HitomiSearchState,
    ) -> list[int]:
        last_error: Exception | None = None
        for host in _HITOMI_NOZOMI_HOSTS:
            url = self._build_hitomi_nozomi_url(state, host=host)
            request = urllib.request.Request(
                url,
                headers={"User-Agent": _STANDALONE_USER_AGENT},
            )
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    status_code = getattr(response, "status", response.getcode())
                    if status_code < 200 or status_code >= 300:
                        raise UrlDownloadError(f"HTTP {status_code} while resolving {url}")
                    payload = response.read()
                return [
                    int.from_bytes(payload[offset : offset + 4], "big", signed=True)
                    for offset in range(0, len(payload) - len(payload) % 4, 4)
                ]
            except Exception as error:
                last_error = error
        raise UrlDownloadError(
            f"Hitomi search URL resolving failed: {last_error or 'nozomi unavailable'}"
        )

    def _resolve_hitomi_search_gallery_ids_from_html(
        self,
        parsed: urllib.parse.ParseResult,
    ) -> list[int]:
        url = urllib.parse.urlunparse(
            (
                "https",
                "hitomi.la",
                parsed.path or "/search.html",
                "",
                parsed.query,
                "",
            )
        )
        request = urllib.request.Request(
            url,
            headers={"User-Agent": _STANDALONE_USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status_code = getattr(response, "status", response.getcode())
                if status_code < 200 or status_code >= 300:
                    return []
                html_text = response.read().decode("utf-8", errors="ignore")
        except Exception:
            return []

        results: list[int] = []
        seen: set[int] = set()
        for match in re.finditer(
            r"""href=["'](?:https?://hitomi\.la)?/(?:galleries|reader)/(\d+)(?:\.html)?["']""",
            html_text,
            flags=re.IGNORECASE,
        ):
            gallery_id = int(match.group(1))
            if gallery_id not in seen:
                seen.add(gallery_id)
                results.append(gallery_id)
        return results

    def _build_hitomi_nozomi_url(
        self,
        state: _HitomiSearchState,
        *,
        host: str,
    ) -> str:
        normalized = state.normalized()
        segments = ["n"]
        if normalized.order_by != "date" or normalized.order_by_key == "published":
            if normalized.area == "all":
                segments.extend(
                    [
                        normalized.order_by,
                        f"{normalized.order_by_key}-{normalized.language}.nozomi",
                    ]
                )
            else:
                segments.extend(
                    [
                        normalized.area,
                        normalized.order_by,
                        str(normalized.order_by_key),
                        f"{normalized.tag}-{normalized.language}.nozomi",
                    ]
                )
        elif normalized.area == "all":
            segments.append(f"{normalized.tag}-{normalized.language}.nozomi")
        else:
            segments.extend(
                [
                    normalized.area,
                    f"{normalized.tag}-{normalized.language}.nozomi",
                ]
            )
        encoded_segments = [urllib.parse.quote(segment, safe=".:-_") for segment in segments]
        return f"https://{host}/{'/'.join(encoded_segments)}"

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
            args.append("--verbose")
        if options.convert_hitomi_to_pdf:
            args.append("--hitomi-pdf")
        if options.prefer_hitomi_original:
            args.append("--hitomi-original")

        return args

    async def _collect_input_urls(
        self,
        source_url: str,
        options: UrlDownloadOptions,
    ) -> list[str]:
        urls: list[str] = []
        seen: set[str] = set()

        def add_url(raw: str) -> None:
            trimmed = raw.strip()
            if not trimmed or trimmed in seen:
                return
            seen.add(trimmed)
            urls.append(trimmed)

        for url in options.collect_source_urls(source_url):
            add_url(url)

        url_list_file_path = (options.url_list_file_path or "").strip()
        if url_list_file_path:
            path = Path(url_list_file_path)
            if not path.is_file():
                raise UrlDownloadError(
                    f"URL list file was not found: {url_list_file_path}"
                )
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                add_url(line)

        return urls

    def _supports_launcher_url(self, raw_url: str) -> bool:
        parsed = urllib.parse.urlparse(raw_url.strip())
        if parsed.scheme not in {"http", "https"}:
            return False

        host = parsed.netloc.lower()
        if re.match(r"^(?:kemono|coomer)\.(?:party|su|cr|st)$", host):
            segments = [segment for segment in parsed.path.split("/") if segment]
            return (
                len(segments) >= 3
                and segments[1].lower() == "user"
                and bool(segments[0].strip())
                and bool(segments[2].strip())
            )

        if host == "hitomi.la":
            segments = [segment for segment in parsed.path.split("/") if segment]
            return bool(segments) and (
                segments[0].lower() in _LAUNCHER_SUPPORTED_HITOMI_SEGMENTS
            )

        return False

    def _copy_options_without_url_list_file(
        self,
        options: UrlDownloadOptions,
    ) -> UrlDownloadOptions:
        return replace(options, url_list_file_path=None)

    def _copy_options_for_direct_download(
        self,
        options: UrlDownloadOptions,
    ) -> UrlDownloadOptions:
        return replace(
            options,
            url_list_file_path=None,
            favorite_posts=False,
            favorite_user_services=[],
        )

    async def _run_direct_url_download_urls(
        self,
        *,
        urls: list[str],
        destination_folder: str,
        options: UrlDownloadOptions,
        metadata_by_url: dict[str, dict[str, object]] | None = None,
        on_event: UrlDownloadEventHandler | None = None,
    ) -> UrlDownloadResult:
        return await asyncio.to_thread(
            self._run_direct_url_download_urls_sync,
            urls,
            destination_folder,
            options,
            metadata_by_url or {},
            on_event,
        )

    def _run_direct_url_download_urls_sync(
        self,
        urls: list[str],
        destination_folder: str,
        options: UrlDownloadOptions,
        metadata_by_url: dict[str, dict[str, object]],
        on_event: UrlDownloadEventHandler | None,
    ) -> UrlDownloadResult:
        if options.has_favorite_sources:
            raise UrlDownloadError("Direct download does not support favorites import")
        if not urls:
            raise UrlDownloadError("No downloadable URLs were found")

        os.makedirs(destination_folder, exist_ok=True)
        log_lines: list[str] = []
        imported_count = 0
        skipped_count = 0
        failed_count = 0
        hitomi_metadata_by_relative_path: dict[str, dict[str, object]] = {}

        def append_log(line: str) -> None:
            log_lines.append(line)
            while len(log_lines) > 80:
                log_lines.pop(0)

        for raw_url in urls:
            parsed = urllib.parse.urlparse(raw_url)
            if parsed.scheme not in {"http", "https"}:
                failed_count += 1
                append_log(f"[skip] unsupported url: {raw_url}")
                continue

            request = urllib.request.Request(
                raw_url,
                headers={
                    "User-Agent": _STANDALONE_USER_AGENT,
                    "Accept": _MEDIA_ACCEPT_HEADER,
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    status_code = getattr(response, "status", response.getcode())
                    if status_code < 200 or status_code >= 300:
                        failed_count += 1
                        append_log(f"[error] http {status_code}: {raw_url}")
                        continue

                    import_metadata = metadata_by_url.get(raw_url)
                    try:
                        file_name = self._build_download_file_name(
                            raw_url,
                            response,
                            sequence=imported_count + skipped_count + failed_count + 1,
                            metadata=import_metadata,
                        )
                    except UrlDownloadError as error:
                        failed_count += 1
                        append_log(f"[error] {error}: {raw_url}")
                        continue

                    relative_key = _normalize_relative_key(file_name)
                    if relative_key is not None and import_metadata is not None:
                        hitomi_metadata_by_relative_path[relative_key] = import_metadata

                    target_path = os.path.join(destination_folder, file_name)
                    if (
                        os.path.exists(target_path)
                        and not options.overwrite_existing_files
                    ):
                        skipped_count += 1
                        append_log(f"[skip] exists: {file_name}")
                        continue

                    try:
                        with open(target_path, "wb") as handle:
                            shutil.copyfileobj(response, handle)
                        self._validate_saved_media_file(target_path)
                        imported_count += 1
                        append_log(f"[ok] {raw_url} -> {file_name}")
                    except Exception as error:
                        failed_count += 1
                        append_log(f"[error] write failed: {file_name} ({error})")
                        try:
                            os.remove(target_path)
                        except OSError:
                            pass
            except urllib.error.URLError as error:
                failed_count += 1
                append_log(f"[error] request failed: {raw_url} ({error})")
            except Exception as error:
                failed_count += 1
                append_log(f"[error] open failed: {raw_url} ({error})")

        return UrlDownloadResult(
            imported_count=imported_count,
            skipped_count=skipped_count,
            failed_count=failed_count,
            total_count=len(urls),
            completed_count=imported_count + skipped_count + failed_count,
            status="completed",
            log_lines=log_lines,
            hitomi_metadata_by_relative_path=hitomi_metadata_by_relative_path,
        )

    def _validate_saved_media_file(self, path: str) -> None:
        if os.path.splitext(path)[1].lower() != ".pdf":
            return
        if not self._has_pdf_header(path):
            raise UrlDownloadError("PDFとして読み込めない内容です")

    def _has_pdf_header(self, path: str) -> bool:
        try:
            size = os.path.getsize(path)
            if size < 5:
                return False
            with open(path, "rb") as handle:
                header = handle.read(1024)
            return b"%PDF-" in header
        except OSError:
            return False

    def _resolve_special_direct_url(self, raw_url: str) -> _ResolvedDirectUrl | None:
        parsed = urllib.parse.urlparse(raw_url.strip())
        if parsed.scheme not in {"http", "https"}:
            return None

        host = parsed.netloc.lower()
        path = parsed.path.lower()
        file_name = path.rsplit("/", 1)[-1]
        if host == _DDD_SMART_CDN_HOST and path.endswith(".pdf"):
            return _ResolvedDirectUrl(url=raw_url.strip())
        if host != _DDD_SMART_HOST:
            return None
        if file_name == "show-m.php":
            return self._resolve_ddd_smart_pdf_url_from_show_page(raw_url.strip())
        if file_name.startswith("dl-"):
            resolved_url = self._resolve_ddd_smart_pdf_url_from_download_page(
                raw_url.strip()
            )
            return _ResolvedDirectUrl(url=resolved_url)
        return None

    def _resolve_ddd_smart_pdf_url_from_show_page(
        self,
        show_page_url: str,
    ) -> _ResolvedDirectUrl:
        html_text = self._download_html(show_page_url)
        dl_href = self._extract_anchor_href_by_label(
            html_text,
            "DLページ",
        ) or self._extract_first_ddd_smart_download_page_href(html_text)
        if dl_href is None:
            raise UrlDownloadError(
                f"ddd-smart DL page link was not found: {show_page_url}"
            )
        download_page_url = urllib.parse.urljoin(show_page_url, dl_href)
        resolved_url = self._resolve_ddd_smart_pdf_url_from_download_page(
            download_page_url
        )
        return _ResolvedDirectUrl(
            url=resolved_url,
            metadata=self._extract_ddd_smart_metadata_from_show_page(
                html_text,
                show_page_url,
            ),
        )

    def _resolve_ddd_smart_pdf_url_from_download_page(
        self,
        download_page_url: str,
    ) -> str:
        html_text = self._download_html(download_page_url)
        pdf_href = self._extract_anchor_href_by_label(
            html_text,
            "PDFダウンロード",
        ) or self._extract_first_pdf_href(html_text)
        if pdf_href is None:
            raise UrlDownloadError(
                f"ddd-smart PDF link was not found: {download_page_url}"
            )
        return urllib.parse.urljoin(download_page_url, pdf_href)

    def _download_html(self, url: str) -> str:
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": _STANDALONE_USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status_code = getattr(response, "status", response.getcode())
                if status_code < 200 or status_code >= 300:
                    raise UrlDownloadError(f"HTTP {status_code} while resolving {url}")
                return response.read().decode("utf-8", errors="replace")
        except UrlDownloadError:
            raise
        except Exception as error:
            raise UrlDownloadError(
                f"ddd-smart URL resolving failed: {url} ({error})"
            ) from error

    def _extract_anchor_href_by_label(self, html_text: str, label: str) -> str | None:
        anchor_pattern = re.compile(
            r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
            flags=re.IGNORECASE | re.DOTALL,
        )
        for match in anchor_pattern.finditer(html_text):
            href = (match.group(1) or match.group(2) or match.group(3) or "").strip()
            if not href:
                continue
            anchor_text = self._normalize_html_text(match.group(4) or "")
            if label in anchor_text:
                return html.unescape(href)
        return None

    def _extract_first_pdf_href(self, html_text: str) -> str | None:
        pdf_href_pattern = re.compile(
            r"""href\s*=\s*(?:"([^"]+\.pdf[^"]*)"|'([^']+\.pdf[^']*)'|([^\s>]+\.pdf[^\s>]*))""",
            flags=re.IGNORECASE | re.DOTALL,
        )
        match = pdf_href_pattern.search(html_text)
        href = (
            (match.group(1) or match.group(2) or match.group(3) or "").strip()
            if match
            else ""
        )
        if not href:
            return None
        return html.unescape(href)

    def _extract_ddd_smart_metadata_from_show_page(
        self,
        html_text: str,
        show_page_url: str,
    ) -> dict[str, object]:
        scoped_html = self._extract_ddd_smart_metadata_scope(html_text)
        title = self._extract_ddd_smart_title(scoped_html)
        circles = self._extract_ddd_smart_keywords_from_section(
            scoped_html,
            section_labels=["サークル"],
            expected_type="3",
        )
        return {
            "artists": circles,
            "groups": circles,
            "series": self._extract_ddd_smart_keywords_from_section(
                scoped_html,
                section_labels=["原作"],
                expected_type="1",
            ),
            "characters": self._extract_ddd_smart_keywords_from_section(
                scoped_html,
                section_labels=["キャラクター"],
                expected_type="2",
            ),
            "tags": self._extract_ddd_smart_keywords_from_section(
                scoped_html,
                section_labels=["タグ"],
                expected_type="4",
            ),
            "title": title,
            "japanese_title": title,
            "media_type": "ddd-smart",
            "source_url": show_page_url,
            "reader_url": show_page_url,
        }

    def _extract_ddd_smart_metadata_scope(self, html_text: str) -> str:
        for marker in ("DLページ", "一覧読み", "PDFダウンロード"):
            index = html_text.find(marker)
            if index < 0:
                continue
            start = max(0, index - 20000)
            end = min(len(html_text), index + 20000)
            return html_text[start:end]
        return html_text

    def _extract_ddd_smart_title(self, html_text: str) -> str | None:
        patterns = [
            re.compile(r"<h1\b[^>]*>(.*?)</h1>", flags=re.IGNORECASE | re.DOTALL),
            re.compile(
                r"""<h2\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</h2>""",
                flags=re.IGNORECASE | re.DOTALL,
            ),
            re.compile(
                r"""<div\b[^>]*class\s*=\s*(?:"[^"]*\bcard-panel\b[^"]*"|'[^']*\bcard-panel\b[^']*')[^>]*>(.*?)</div>""",
                flags=re.IGNORECASE | re.DOTALL,
            ),
            re.compile(r"<title>(.*?)</title>", flags=re.IGNORECASE | re.DOTALL),
        ]
        for pattern in patterns:
            for match in pattern.finditer(html_text):
                text = self._normalize_html_text(match.group(1) or "")
                if self._looks_like_ddd_smart_title(text):
                    return text
        return None

    def _looks_like_ddd_smart_title(self, text: str) -> bool:
        normalized = text.strip()
        if len(normalized) < 4:
            return False
        blocked_exact = {
            "原作",
            "キャラ",
            "キャラクター",
            "サークル",
            "タグ",
            "更新日",
            "発行日",
            "オススメ度",
            "一覧読み",
            "DLページ",
            "PDFダウンロード",
        }
        if normalized in blocked_exact:
            return False
        return (
            "同人すまーと" not in normalized
            and "ddd-smart" not in normalized
            and "から探す" not in normalized
            and "一覧" not in normalized
            and "ランキング" not in normalized
        )

    def _extract_ddd_smart_keywords_from_section(
        self,
        html_text: str,
        *,
        section_labels: list[str],
        expected_type: str,
    ) -> list[str]:
        section_html = self._extract_ddd_smart_section_html(
            html_text,
            section_labels=section_labels,
        )
        if section_html is None:
            return []
        return self._extract_ddd_smart_keywords_by_type(
            section_html,
            expected_type=expected_type,
        )

    def _extract_ddd_smart_section_html(
        self,
        html_text: str,
        *,
        section_labels: list[str],
    ) -> str | None:
        start = -1
        for label in section_labels:
            index = html_text.find(label)
            if index >= 0 and (start < 0 or index < start):
                start = index
        if start < 0:
            return None

        end = len(html_text)
        for label in (
            "原作",
            "キャラ",
            "キャラクター",
            "サークル",
            "タグ",
            "更新日",
            "発行日",
            "オススメ度",
            "一覧読み",
            "DLページ",
        ):
            if label in section_labels:
                continue
            index = html_text.find(label, start + 1)
            if index >= 0 and index < end:
                end = index

        end = min(end, start + 4000, len(html_text))
        if end <= start:
            return None
        return html_text[start:end]

    def _extract_ddd_smart_keywords_by_type(
        self,
        html_text: str,
        *,
        expected_type: str,
    ) -> list[str]:
        out: list[str] = []
        seen: set[str] = set()
        anchor_pattern = re.compile(
            r"""<a\b[^>]*href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>""",
            flags=re.IGNORECASE | re.DOTALL,
        )
        for match in anchor_pattern.finditer(html_text):
            href = html.unescape(
                (match.group(1) or match.group(2) or match.group(3) or "").strip()
            )
            keyword = self._extract_ddd_smart_keyword_from_href(
                href,
                expected_type=expected_type,
            )
            if keyword is None:
                continue
            lowered = keyword.casefold()
            if lowered in seen:
                continue
            seen.add(lowered)
            out.append(keyword)
        return out

    def _extract_ddd_smart_keyword_from_href(
        self,
        href: str,
        *,
        expected_type: str,
    ) -> str | None:
        if not href:
            return None
        parsed = urllib.parse.urlparse(href)
        if not parsed.path:
            return None
        query = urllib.parse.parse_qs(parsed.query)
        tag_type = (query.get("type") or [""])[0].strip()
        keyword = (query.get("keyword") or [""])[0].strip()
        if tag_type != expected_type or not keyword:
            return None
        return keyword

    def _extract_first_ddd_smart_download_page_href(self, html_text: str) -> str | None:
        dl_href_pattern = re.compile(
            r"""href\s*=\s*(?:"([^"]*/dl-[^"]+)"|'([^']*/dl-[^']+)'|([^\s>]*/dl-[^\s>]+))""",
            flags=re.IGNORECASE | re.DOTALL,
        )
        match = dl_href_pattern.search(html_text)
        href = (
            (match.group(1) or match.group(2) or match.group(3) or "").strip()
            if match
            else ""
        )
        if not href:
            return None
        return html.unescape(href)

    def _normalize_html_text(self, raw_html: str) -> str:
        without_tags = re.sub(r"<[^>]+>", " ", raw_html)
        decoded = html.unescape(without_tags)
        return re.sub(r"\s+", " ", decoded).strip()

    def _build_download_file_name(
        self,
        raw_url: str,
        response: object,
        *,
        sequence: int,
        metadata: dict[str, object] | None = None,
    ) -> str:
        headers = getattr(response, "headers", None)
        disposition = headers.get(_CONTENT_DISPOSITION_HEADER) if headers else None
        from_disposition = self._decode_content_disposition_file_name(disposition)
        from_url = ""
        parsed = urllib.parse.urlparse(raw_url)
        if parsed.path:
            from_url = urllib.parse.unquote(parsed.path.rsplit("/", 1)[-1])
        preferred = (from_disposition or from_url).strip()
        content_type = headers.get_content_type() if headers else None
        inferred_extension = self._extension_from_content_type(content_type)

        file_name = self._sanitize_file_name(preferred)
        preferred_extension = os.path.splitext(file_name or preferred)[1].lower()
        title_fallback_extension = preferred_extension or inferred_extension
        if self._should_replace_generic_download_file_name(file_name):
            file_name = (
                self._build_title_based_file_name(
                    metadata,
                    preferred_extension=title_fallback_extension,
                )
                or file_name
            )
        if file_name is None:
            file_name = (
                self._build_title_based_file_name(
                    metadata,
                    preferred_extension=inferred_extension,
                )
                or f"download_{sequence}{inferred_extension or ''}"
            )

        current_extension = os.path.splitext(file_name)[1].lower()
        if not current_extension and inferred_extension is not None:
            file_name = f"{file_name}{inferred_extension}"
        elif (
            not self._is_supported_media_file_name(file_name)
            and inferred_extension is not None
            and inferred_extension in _SUPPORTED_MEDIA_EXTENSIONS
        ):
            base_name = os.path.splitext(file_name)[0]
            file_name = f"{base_name}{inferred_extension}"

        if not self._is_supported_media_file_name(file_name):
            raise UrlDownloadError("Unsupported media URL")
        return file_name

    def _should_replace_generic_download_file_name(self, file_name: str | None) -> bool:
        if not file_name:
            return False
        base_name = os.path.splitext(os.path.basename(file_name))[0].strip().lower()
        return base_name == "all"

    def _build_title_based_file_name(
        self,
        metadata: dict[str, object] | None,
        *,
        preferred_extension: str | None,
    ) -> str | None:
        if not metadata:
            return None
        title = (
            _string_or_none(metadata.get("japanese_title"))
            or _string_or_none(metadata.get("title"))
            or _string_or_none(metadata.get("english_title"))
        )
        sanitized_title = self._sanitize_file_name(title or "")
        if sanitized_title is None:
            return None
        if os.path.splitext(sanitized_title)[1]:
            return sanitized_title
        extension = (preferred_extension or "").strip().lower()
        if not extension:
            return sanitized_title
        return f"{sanitized_title}{extension}"

    def _sanitize_file_name(self, raw: str) -> str | None:
        value = raw.strip()
        if not value:
            return None
        value = value.replace("\\", "/").split("/")[-1]
        value = re.sub(r'[<>:"/\\|?*\x00-\x1F]+', "_", value)
        value = re.sub(r"[\r\n]+", " ", value).strip()
        while value.endswith(".") or value.endswith(" "):
            value = value[:-1].rstrip()
        if not value or value in {".", ".."}:
            return None
        return value

    def _decode_content_disposition_file_name(self, raw_header: str | None) -> str | None:
        header = (raw_header or "").strip()
        if not header:
            return None

        utf8_match = re.search(
            r"""filename\*\s*=\s*(?:UTF-8'')?([^;]+)""",
            header,
            flags=re.IGNORECASE,
        )
        if utf8_match is not None:
            return urllib.parse.unquote(utf8_match.group(1).strip().replace('"', ""))

        plain_match = re.search(
            r'''filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;]+)''',
            header,
            flags=re.IGNORECASE,
        )
        if plain_match is not None:
            return (plain_match.group(1) or plain_match.group(2) or "").strip().replace(
                '"',
                "",
            )
        return None

    def _extension_from_content_type(self, content_type: str | None) -> str | None:
        mime_type = (content_type or "").split(";", 1)[0].strip().lower()
        if mime_type == "application/pdf":
            return ".pdf"
        if mime_type in {"image/jpeg", "image/jpg"}:
            return ".jpg"
        if mime_type == "image/png":
            return ".png"
        if mime_type == "image/gif":
            return ".gif"
        if mime_type == "image/webp":
            return ".webp"
        if mime_type in {"image/bmp", "image/x-ms-bmp"}:
            return ".bmp"
        if mime_type == "image/avif":
            return ".avif"
        return None

    def _is_supported_media_file_name(self, file_name: str) -> bool:
        return os.path.splitext(file_name)[1].lower() in _SUPPORTED_MEDIA_EXTENSIONS

    def _merge_download_results(
        self,
        results: list[UrlDownloadResult],
    ) -> UrlDownloadResult:
        if not results:
            return UrlDownloadResult()
        if len(results) == 1:
            return results[0]

        merged = UrlDownloadResult(status="completed")
        for result in results:
            merged.imported_count += result.imported_count
            merged.skipped_count += result.skipped_count
            merged.failed_count += result.failed_count
            merged.total_count += result.total_count
            merged.completed_count += result.completed_count
            merged.log_lines.extend(result.log_lines)
            while len(merged.log_lines) > 80:
                merged.log_lines.pop(0)
            merged.hitomi_metadata_by_relative_path.update(
                result.hitomi_metadata_by_relative_path
            )
            if result.current_file:
                merged.current_file = result.current_file
        return merged


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


def _normalize_relative_key(relative_path: str | None) -> str | None:
    raw = (relative_path or "").strip()
    if not raw:
        return None
    return raw.replace("\\", "/").casefold()


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
    return f"Downloader exited with code {return_code}"
