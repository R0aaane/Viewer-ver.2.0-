from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageOps

from server.services.pillow_plugins import ensure_pillow_plugins
from server.vendor.kemono_dl.hitomi import strip_hitomi_download_prefix


ensure_pillow_plugins()

_UI_EVENT_PREFIX = "__KEMONO_DL_UI__"
_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".avif"}


def _emit_event(event_type: str, **data: object) -> None:
    payload = {"type": event_type, **data}
    print(f"{_UI_EVENT_PREFIX}{json.dumps(payload, ensure_ascii=False)}", flush=True)


def _split_csv(raw: str | None) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for chunk in (raw or "").split(","):
        trimmed = chunk.strip()
        if not trimmed:
            continue
        lowered = trimmed.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        values.append(trimmed)
    return values


def _load_urls_from_file(path_value: str | None) -> list[str]:
    path = (path_value or "").strip()
    if not path:
        return []

    file_path = Path(path)
    if not file_path.is_file():
        return []

    urls: list[str] = []
    seen: set[str] = set()
    for line in file_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        cleaned = line.strip()
        if not cleaned or cleaned.startswith("#"):
            continue
        lowered = cleaned.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        urls.append(cleaned)
    return urls


def _project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _project_cookie_dir() -> Path:
    return _project_root() / "data" / "url_import_cookies"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Thin wrapper around the vendored kemono downloader",
    )
    parser.add_argument(
        "--url",
        dest="urls",
        action="append",
        default=[],
        help="Source URL to download. Pass multiple times for batch download.",
    )
    parser.add_argument(
        "--dest",
        required=True,
        help="Destination root folder where downloaded creator folders will be created",
    )
    parser.add_argument("--cookies", help="Cookie file path for favorites and authenticated access")
    parser.add_argument(
        "--cookie-mode",
        default="auto",
        choices=("auto", "none", "project_kemono", "project_coomer", "project_combined", "custom"),
        help="How to resolve the cookie file",
    )
    parser.add_argument("--from-file", help="Text file containing one URL per line")
    parser.add_argument("--sites", help="Favorite target sites, for example kemono,coomer")
    parser.add_argument("--fav-posts", action="store_true", help="Download favorite posts")
    parser.add_argument("--fav-users", help="Download favorite users for the selected services")
    parser.add_argument(
        "--media-type",
        default="all",
        choices=("images", "videos", "images_videos", "all"),
        help="What media to download",
    )
    parser.add_argument(
        "--parallel-downloads",
        type=int,
        default=6,
        help="Maximum concurrent file downloads",
    )
    parser.add_argument("--inline", action="store_true", help="Download inline images")
    parser.add_argument("--content", action="store_true", help="Save post content")
    parser.add_argument("--comments", action="store_true", help="Save comments")
    parser.add_argument("--json", action="store_true", help="Save post json")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing files")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument(
        "--replace-tld",
        action="store_true",
        help="Rewrite kemono/coomer domains to the mirror domains supported by kemono-dl",
    )
    parser.add_argument(
        "--hitomi-pdf",
        action="store_true",
        help="Convert downloaded Hitomi galleries into PDF files",
    )
    return parser.parse_args()


def _infer_cookie_profile(urls: list[str], sites: list[str]) -> str | None:
    detected: list[str] = []

    def add_site(site: str) -> None:
        if site not in detected:
            detected.append(site)

    for site in sites:
        lowered = site.strip().lower()
        if lowered in {"kemono", "coomer"}:
            add_site(lowered)

    for url in urls:
        lowered = url.lower()
        if "kemono." in lowered:
            add_site("kemono")
        elif "coomer." in lowered:
            add_site("coomer")

    has_kemono = "kemono" in detected
    has_coomer = "coomer" in detected
    if has_kemono and has_coomer:
        return "combined"
    if has_kemono:
        return "kemono"
    if has_coomer:
        return "coomer"
    return None


def _resolve_cookie_path(
    options: argparse.Namespace,
    urls: list[str],
    sites: list[str],
    file_urls: list[str],
) -> tuple[str | None, str | None]:
    mode = options.cookie_mode
    if mode == "none":
        return None, None
    if mode == "custom":
        cookie_file = (options.cookies or "").strip() or None
        return cookie_file, None

    explicit_profile = {
        "project_kemono": "kemono",
        "project_coomer": "coomer",
        "project_combined": "combined",
    }.get(mode)
    profile = explicit_profile or _infer_cookie_profile(urls + file_urls, sites)
    if not profile:
        cookie_file = (options.cookies or "").strip() or None
        return cookie_file, None

    cookie_path = _project_cookie_dir() / f"{profile}.txt"
    if cookie_path.exists():
        return str(cookie_path), profile

    fallback = (options.cookies or "").strip() or None
    return fallback, profile


def _iter_hitomi_gallery_dirs(destination: Path) -> list[Path]:
    hitomi_root = destination / "hitomi"
    if not hitomi_root.is_dir():
        return []

    galleries: list[Path] = []
    for directory in hitomi_root.rglob("*"):
        if not directory.is_dir():
            continue
        image_files = [
            child for child in directory.iterdir()
            if child.is_file() and child.suffix.lower() in _IMAGE_EXTENSIONS
        ]
        if image_files:
            galleries.append(directory)
    galleries.sort()
    return galleries


def _should_refresh_pdf(pdf_path: Path, image_paths: list[Path]) -> bool:
    if not pdf_path.exists():
        return True
    pdf_mtime = pdf_path.stat().st_mtime
    newest_image_mtime = max(path.stat().st_mtime for path in image_paths)
    return newest_image_mtime > pdf_mtime


def _convert_gallery_to_pdf(gallery_dir: Path) -> bool:
    image_paths = sorted(
        [
            child for child in gallery_dir.iterdir()
            if child.is_file() and child.suffix.lower() in _IMAGE_EXTENSIONS
        ]
    )
    if not image_paths:
        return False

    legacy_pdf_path = gallery_dir.parent / f"{gallery_dir.name}.pdf"
    cleaned_name = strip_hitomi_download_prefix(gallery_dir.name) or gallery_dir.name
    pdf_path = gallery_dir.parent / f"{cleaned_name}.pdf"
    if not _should_refresh_pdf(pdf_path, image_paths):
        if legacy_pdf_path != pdf_path and legacy_pdf_path.exists():
            legacy_pdf_path.unlink()
        return False

    images: list[Image.Image] = []
    try:
        for image_path in image_paths:
            with Image.open(image_path) as opened:
                prepared = ImageOps.exif_transpose(opened)
                if prepared.mode not in {"RGB", "L"}:
                    prepared = prepared.convert("RGB")
                elif prepared.mode == "L":
                    prepared = prepared.convert("RGB")
                else:
                    prepared = prepared.copy()
                images.append(prepared)

        if not images:
            return False

        first, rest = images[0], images[1:]
        first.save(pdf_path, "PDF", resolution=100.0, save_all=True, append_images=rest)
        if legacy_pdf_path != pdf_path and legacy_pdf_path.exists():
            legacy_pdf_path.unlink()
        return True
    finally:
        for image in images:
            try:
                image.close()
            except Exception:
                pass


def _convert_hitomi_galleries_to_pdf(destination: Path) -> int:
    converted = 0
    for gallery_dir in _iter_hitomi_gallery_dirs(destination):
        if _convert_gallery_to_pdf(gallery_dir):
            converted += 1
    return converted


def main() -> None:
    options = _parse_args()
    destination = Path(options.dest).resolve()
    destination.mkdir(parents=True, exist_ok=True)

    urls = [url.strip() for url in options.urls if url and url.strip()]
    sites = _split_csv(options.sites)
    favorite_user_services = _split_csv(options.fav_users)
    has_favorites = options.fav_posts or bool(favorite_user_services)
    has_url_list_file = bool((options.from_file or "").strip())
    file_urls = _load_urls_from_file(options.from_file)
    cookie_path, cookie_profile = _resolve_cookie_path(options, urls, sites, file_urls)

    if not urls and not has_url_list_file and not has_favorites:
        _emit_event("task_error", message="URL、URL 一覧ファイル、またはお気に入り条件を入力してください")
        raise SystemExit(2)
    if has_favorites and not cookie_path:
        _emit_event("task_error", message="お気に入り取得には Cookie が必要です")
        raise SystemExit(2)
    if has_favorites and not sites:
        _emit_event("task_error", message="お気に入り取得には対象サイトを選択してください")
        raise SystemExit(2)

    dirname_pattern = str(destination / "{service}" / "{username} [{user_id}]")
    kemono_argv = [
        sys.argv[0],
        "--dirname-pattern",
        dirname_pattern,
        "--media-type",
        options.media_type,
        "--parallel-downloads",
        str(max(1, options.parallel_downloads)),
    ]
    if urls:
        kemono_argv.extend(["--links", ",".join(urls)])
    if cookie_path:
        kemono_argv.extend(["--cookies", cookie_path])
    if (options.from_file or "").strip():
        kemono_argv.extend(["--from-file", options.from_file.strip()])
    if sites:
        kemono_argv.extend(["--sites", ",".join(sites)])
    if options.fav_posts:
        kemono_argv.append("--fav-posts")
    if favorite_user_services:
        kemono_argv.extend(["--fav-users", ",".join(favorite_user_services)])
    if options.inline:
        kemono_argv.append("--inline")
    if options.content:
        kemono_argv.append("--content")
    if options.comments:
        kemono_argv.append("--comments")
    if options.json:
        kemono_argv.append("--json")
    if options.overwrite:
        kemono_argv.append("--overwrite")
    if options.verbose:
        kemono_argv.append("--verbose")
    if options.replace_tld:
        kemono_argv.append("--replace-tld")

    _emit_event(
        "task_start",
        urlCount=len(urls),
        hasUrlListFile=has_url_list_file,
        favoritePosts=options.fav_posts,
        favoriteUserServices=favorite_user_services,
        cookieMode=options.cookie_mode,
        cookieProfile=cookie_profile,
        convertHitomiToPdf=options.hitomi_pdf,
        destination=str(destination),
    )

    previous_argv = sys.argv[:]
    sys.argv = kemono_argv
    try:
        from server.vendor.kemono_dl.main import main as vendor_main

        vendor_main()
        if options.hitomi_pdf:
            converted = _convert_hitomi_galleries_to_pdf(destination)
            if converted:
                print(f"[hitomi-pdf] converted {converted} gallery folders", flush=True)
    except SystemExit as exc:  # pragma: no cover - mirrors CLI behavior
        code = exc.code if isinstance(exc.code, int) else (0 if exc.code in (None, False) else 1)
        if code != 0:
            _emit_event("task_error", message=f"kemono-dl exited with code {code}")
        raise
    except Exception as exc:
        _emit_event("task_error", message=str(exc))
        raise
    finally:
        sys.argv = previous_argv


if __name__ == "__main__":
    main()
