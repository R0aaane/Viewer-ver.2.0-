import json
import os
import re

from bs4 import BeautifulSoup


HITOMI_ROOT = "https://hitomi.la"
HITOMI_MEDIA_DOMAIN = "gold-usergeneratedcontent.net"
HITOMI_GG_URL = f"https://ltn.{HITOMI_MEDIA_DOMAIN}/gg.js"
HITOMI_GALLERY_URL_RE = re.compile(
    r"^(?:https?://)?hitomi\.la/"
    r"(?:manga|doujinshi|cg|gamecg|imageset|galleries|reader)/"
    r"(?:[^/?#]+-)?(\d+)(?:\.html)?(?:[?#].*)?$",
    re.IGNORECASE,
)


def parse_hitomi_url(url: str):
    if not url:
        return None
    match = HITOMI_GALLERY_URL_RE.match(url.strip())
    if not match:
        return None
    gallery_id = match.group(1)
    return {
        "gallery_id": gallery_id,
        "normalized_url": build_hitomi_gallery_url(gallery_id),
        "reader_url": f"{HITOMI_ROOT}/reader/{gallery_id}.html",
        "galleryinfo_url": f"https://ltn.{HITOMI_MEDIA_DOMAIN}/galleries/{gallery_id}.js",
    }


def build_hitomi_gallery_url(gallery_id: str):
    return f"{HITOMI_ROOT}/galleries/{gallery_id}.html"


def extract_hitomi_gallery_info(payload: str):
    start = payload.find("{")
    end = payload.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("Unable to locate Hitomi gallery JSON payload")
    return json.loads(payload[start:end + 1])


def parse_hitomi_gg(payload: str):
    mapping = {}
    pending_keys = []

    for match in re.finditer(r"case\s+(\d+):(?:\s*o\s*=\s*(\d+))?", payload):
        key, value = match.groups()
        pending_keys.append(int(key))
        if value is None:
            continue
        value = int(value)
        for pending_key in pending_keys:
            mapping[pending_key] = value
        pending_keys.clear()

    for match in re.finditer(r"if\s+\(g\s*===?\s*(\d+)\)[\s{]*o\s*=\s*(\d+)", payload):
        mapping[int(match.group(1))] = int(match.group(2))

    default_match = re.search(r"(?:var\s|default:)\s*o\s*=\s*(\d+)", payload)
    base_match = re.search(r"b:\s*[\"'](.+?)[\"']", payload)
    if not base_match:
        raise ValueError("Unable to locate Hitomi media base path")

    default_value = int(default_match.group(1)) if default_match else 0
    return mapping, base_match.group(1).strip("/"), default_value


def _dedupe_hitomi_names(values: list[str]) -> list[str]:
    names = []
    seen = set()

    for raw in values:
        value = str(raw or "").strip()
        if not value:
            continue
        lowered = value.casefold()
        if lowered in seen:
            continue
        seen.add(lowered)
        names.append(value)

    return names


def _candidate_list(value) -> list[str]:
    if isinstance(value, (list, tuple, set)):
        return [str(entry).strip() for entry in value if str(entry).strip()]
    single = str(value or "").strip()
    return [single] if single else []


def _iter_hitomi_items(info: dict, keys):
    for key in _candidate_list(keys):
        raw_items = info.get(key)
        if raw_items is None:
            continue
        if isinstance(raw_items, (list, tuple)):
            items = raw_items
        else:
            items = [raw_items]
        for item in items:
            yield item


def _extract_hitomi_name(item, fields) -> str | None:
    field_names = _candidate_list(fields)

    if isinstance(item, dict):
        for field_name in field_names:
            value = item.get(field_name)
            trimmed = str(value or "").strip()
            if trimmed:
                return trimmed
        return None

    trimmed = str(item or "").strip()
    return trimmed or None


def collect_hitomi_names(info: dict, keys, fields):
    names = []
    for item in _iter_hitomi_items(info, keys):
        value = _extract_hitomi_name(item, fields)
        if value:
            names.append(value)
    return _dedupe_hitomi_names(names)


def _normalize_hitomi_label(raw: str) -> str:
    return re.sub(r"\s+", " ", str(raw or "")).strip().rstrip(":").casefold()


def _extract_hitomi_anchor_texts(node) -> list[str]:
    if node is None:
        return []
    values = []
    for anchor in node.find_all("a"):
        text = " ".join(anchor.stripped_strings).strip()
        if text:
            values.append(text)
    return _dedupe_hitomi_names(values)


def _extract_hitomi_row_link_values(soup: BeautifulSoup, labels) -> list[str]:
    normalized_labels = {_normalize_hitomi_label(label) for label in _candidate_list(labels)}
    for row in soup.find_all("tr"):
        cells = row.find_all(["td", "th"], recursive=False)
        if len(cells) < 2:
            continue
        label = _normalize_hitomi_label(" ".join(cells[0].stripped_strings))
        if label not in normalized_labels:
            continue
        values = []
        for cell in cells[1:]:
            values.extend(_extract_hitomi_anchor_texts(cell))
        if values:
            return _dedupe_hitomi_names(values)
    return []


def extract_hitomi_gallery_html_metadata(payload: str | None) -> dict[str, list[str]]:
    raw = str(payload or "").strip()
    if not raw:
        return {
            "artists": [],
            "groups": [],
            "series": [],
            "characters": [],
        }

    soup = BeautifulSoup(raw, "html.parser")
    artists = []
    for heading in soup.find_all("h2"):
        artists.extend(_extract_hitomi_anchor_texts(heading))
    artists = _dedupe_hitomi_names(artists)
    if not artists:
        artists = _extract_hitomi_row_link_values(soup, ("artist",))

    groups = _extract_hitomi_row_link_values(soup, ("group", "circle"))
    series = _extract_hitomi_row_link_values(soup, ("series", "parody"))
    characters = _extract_hitomi_row_link_values(soup, ("characters",))

    return {
        "artists": artists,
        "groups": groups,
        "series": series,
        "characters": characters,
    }


def pick_hitomi_directory_name(
    artists: list[str],
    groups: list[str],
    series: list[str],
    title: str,
):
    deduped_artists = _dedupe_hitomi_names(artists)
    deduped_groups = _dedupe_hitomi_names(groups)
    deduped_series = _dedupe_hitomi_names(series)
    cleaned_title = str(title or "").strip()

    if len(deduped_artists) > 1:
        if deduped_series:
            return deduped_series[0]
        if cleaned_title:
            return cleaned_title

    if deduped_artists:
        return deduped_artists[0]
    if deduped_groups:
        return deduped_groups[0]
    if deduped_series:
        return deduped_series[0]
    return cleaned_title or "gallery"


def build_hitomi_pdf_path(post_path: str, attachment_file_path: str) -> str:
    gallery_dir = os.path.dirname(str(attachment_file_path or "").strip())
    normalized_post_path = os.path.normpath(str(post_path or "").strip())
    normalized_gallery_dir = os.path.normpath(gallery_dir) if gallery_dir else ""

    if normalized_gallery_dir and normalized_gallery_dir != normalized_post_path:
        return os.path.join(
            os.path.dirname(normalized_gallery_dir),
            f"{os.path.basename(normalized_gallery_dir)}.pdf",
        )

    return os.path.join(
        os.path.dirname(normalized_post_path),
        f"{os.path.basename(normalized_post_path)}.pdf",
    )


def list_hitomi_extensions(file_info: dict, preferred: str = "auto"):
    preferred = (preferred or "auto").lower().lstrip(".")
    original_name = os.path.basename((file_info.get("name") or "").split("?")[0])
    original_ext = os.path.splitext(original_name)[1].lstrip(".").lower()
    available = []

    def add_extension(extension: str):
        extension = (extension or "").lower().lstrip(".")
        if extension and extension not in available:
            available.append(extension)

    if preferred == "original":
        add_extension(original_ext)
    elif preferred != "auto":
        if preferred not in {"avif", "jxl"} or file_info.get(f"has{preferred}"):
            add_extension(preferred)

    if file_info.get("hasavif"):
        add_extension("avif")

    add_extension("webp")

    if file_info.get("hasjxl"):
        add_extension("jxl")

    add_extension(original_ext)

    if not available:
        add_extension("webp")

    return available


def get_hitomi_host_index(image_number: int, gg_map: dict, gg_default: int):
    return 1 + gg_map.get(image_number, gg_default)


def get_hitomi_host(host_index: int, extension: str):
    if extension == "webp":
        return f"w{host_index}"
    if extension == "avif":
        return f"a{host_index}"
    return str(host_index)


def get_hitomi_directory_prefix(extension: str):
    if extension in {"webp", "avif"}:
        return ""
    return f"{extension}/"


def build_hitomi_origin_path(gg_base: str, image_number: int, image_hash: str, extension: str):
    directory_prefix = get_hitomi_directory_prefix(extension)
    return f"{directory_prefix}{gg_base}/{image_number}/{image_hash}.{extension}"


def build_hitomi_media_url(
    gg_base: str,
    image_number: int,
    image_hash: str,
    extension: str,
    host_index: int,
):
    host = get_hitomi_host(host_index, extension)
    return f"https://{host}.{HITOMI_MEDIA_DOMAIN}/{build_hitomi_origin_path(gg_base, image_number, image_hash, extension)}"


def build_hitomi_file(file_info: dict, gg_map: dict, gg_base: str, gg_default: int, preferred: str = "auto"):
    image_hash = file_info["hash"]
    extensions = list_hitomi_extensions(file_info, preferred=preferred)
    extension = extensions[0]
    image_number = int(image_hash[-1] + image_hash[-3:-1], 16)
    host_index = get_hitomi_host_index(image_number, gg_map, gg_default)

    original_name = os.path.basename((file_info.get("name") or "").split("?")[0])
    filename = os.path.splitext(original_name)[0] or image_hash
    primary_url = build_hitomi_media_url(gg_base, image_number, image_hash, extension, host_index)

    return {
        "filename": filename,
        "ext": extension,
        "url": primary_url,
        "fallback_urls": [],
        "hash": None,
    }
