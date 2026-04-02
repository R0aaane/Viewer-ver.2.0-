import re

_IMPORT_SITE_TAGS = {
    "hitomi": "hitomi",
    "kemono": "kemono",
}

_IMPORT_SERVICE_SEGMENTS = {
    "hitomi",
    "kemono",
    "coomer",
    "patreon",
    "fanbox",
    "fantia",
    "gumroad",
    "subscribestar",
    "subscribestarad",
    "dlsite",
    "onlyfans",
    "fansly",
    "discord",
    "afdian",
    "boosty",
    "candfans",
    "pixiv",
}

_GENERIC_IMPORT_SEGMENTS = {
    "download",
    "downloads",
    "library",
    "images",
    "image",
    "files",
    "file",
    "posts",
    "post",
    "gallery",
    "galleries",
    "books",
    "book",
    "archives",
    "archive",
    "pdf",
    "pdfs",
}

_BRACKETED_DIGITS_RE = re.compile(r"\[\s*\d+\s*\]")


def build_inferred_import_tags(
    *,
    relative_path: str | None,
    source_urls: list[str],
    hitomi_metadata: dict[str, object] | None = None,
) -> list[dict[str, str]]:
    tags: list[dict[str, str]] = []
    media_type_tag_names: set[str] = set()
    path_segments = _relative_directory_parts(relative_path)

    lowered_segments = [segment.casefold() for segment in path_segments]
    lowered_urls = [url.casefold() for url in source_urls]
    for needle, tag_name in _IMPORT_SITE_TAGS.items():
        if any(needle in segment for segment in lowered_segments) or any(
            needle in url for url in lowered_urls
        ):
            media_type_tag_names.add(tag_name)

    artist_tag = _clean_artist_tag_candidate(
        _pick_first_tag_value(hitomi_metadata, "artists")
    ) or _infer_artist_tag_from_parts(path_segments)
    if artist_tag is not None:
        tags.append({"category": "artist", "name": artist_tag})

    is_hitomi_context = "hitomi" in media_type_tag_names
    series_tag = _infer_series_tag_from_parts(
        is_hitomi_context=is_hitomi_context,
        hitomi_metadata=hitomi_metadata,
        artist_tag=artist_tag,
    )
    if series_tag is not None:
        tags.append({"category": "series", "name": series_tag})

    for tag_name in sorted(media_type_tag_names):
        tags.append({"category": "mediaType", "name": tag_name})
    return tags


def _relative_directory_parts(relative_path: str | None) -> list[str]:
    raw = (relative_path or "").strip()
    if not raw:
        return []
    parts = [part.strip() for part in re.split(r"[\\/]+", raw) if part.strip()]
    if len(parts) <= 1:
        return []
    return parts[:-1]


def _infer_artist_tag_from_parts(parts: list[str]) -> str | None:
    if not parts:
        return None

    service_indexes = [
        index for index, segment in enumerate(parts) if _is_service_segment(segment)
    ]
    start_index = service_indexes[-1] + 1 if service_indexes else 0

    for index in range(start_index, len(parts)):
        candidate = _clean_artist_tag_candidate(parts[index])
        if candidate is not None:
            return candidate

    for segment in parts:
        candidate = _clean_artist_tag_candidate(segment)
        if candidate is not None:
            return candidate
    return None


def _clean_artist_tag_candidate(segment: str | None) -> str | None:
    if segment is None:
        return None

    cleaned = _BRACKETED_DIGITS_RE.sub(" ", str(segment))
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = cleaned.strip("-_[](){}")
    if not cleaned:
        return None

    lowered = cleaned.casefold()
    if lowered in _IMPORT_SERVICE_SEGMENTS or lowered in _GENERIC_IMPORT_SEGMENTS:
        return None
    if re.fullmatch(r"\d+", cleaned):
        return None
    return cleaned


def _infer_series_tag_from_parts(
    *,
    is_hitomi_context: bool,
    hitomi_metadata: dict[str, object] | None,
    artist_tag: str | None,
) -> str | None:
    if not is_hitomi_context:
        return None

    return _clean_series_tag_candidate(
        _pick_first_tag_value(hitomi_metadata, "series"),
        artist_tag=artist_tag,
    )


def _clean_series_tag_candidate(
    segment: str | None,
    *,
    artist_tag: str | None,
) -> str | None:
    if segment is None:
        return None

    cleaned = _clean_artist_tag_candidate(segment)
    if cleaned is None:
        return None

    if artist_tag and cleaned.casefold() == artist_tag.strip().casefold():
        return None
    return cleaned


def _is_service_segment(segment: str) -> bool:
    lowered = segment.strip().casefold()
    if not lowered:
        return False
    if lowered in _IMPORT_SERVICE_SEGMENTS:
        return True
    return any(token in lowered for token in _IMPORT_SITE_TAGS)


def _pick_first_tag_value(
    metadata: dict[str, object] | None,
    key: str,
) -> str | None:
    if not metadata:
        return None
    raw = metadata.get(key)
    if not isinstance(raw, list):
        return None
    for entry in raw:
        value = str(entry or "").strip()
        if value:
            return value
    return None


def filter_hitomi_pdf_auto_tags(
    tags: list[dict[str, str]],
) -> list[dict[str, str]]:
    filtered: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    has_hitomi_media_type = False

    for tag in tags:
        category = str(tag.get("category") or "").strip()
        name = str(tag.get("name") or "").strip()
        if not category or not name:
            continue

        lowered_name = name.casefold()
        is_artist = category == "artist"
        is_series = category == "series"
        is_hitomi_media_type = category == "mediaType" and lowered_name == "hitomi"
        if not is_artist and not is_series and not is_hitomi_media_type:
            continue

        if is_hitomi_media_type:
            has_hitomi_media_type = True

        key = (category, lowered_name)
        if key in seen:
            continue
        seen.add(key)
        filtered.append({"category": category, "name": name})

    if not has_hitomi_media_type:
        return []
    return filtered
