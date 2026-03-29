import json
import os
import re


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


def collect_hitomi_names(info: dict, key: str, field: str):
    names = []
    for item in info.get(key) or []:
        value = item.get(field)
        if value:
            names.append(value)
    return names


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

    # Match Hitomi's reader flow: prefer AVIF when available, otherwise WEBP.
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
