from __future__ import annotations

import json
import re
import sqlite3
import unicodedata
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


_SUPPORTED_CATEGORIES = ("series", "character")
_JAPANESE_RE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff]")
_LATIN_RE = re.compile(r"[A-Za-z]")
_TRAILING_BRACKET_RE = re.compile(
    r"\s*[\(\[（【][^()\[\]（）【】]{1,80}[\)\]）】]\s*$",
)


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _normalize_name(value: str) -> str:
    return unicodedata.normalize("NFKC", str(value or "")).strip().casefold()


def _simplify_name(value: str) -> str:
    folded = _normalize_name(value)
    return "".join(char for char in folded if char.isalnum())


def _strip_trailing_bracket(value: str) -> str:
    current = str(value or "").strip()
    while True:
        updated = _TRAILING_BRACKET_RE.sub("", current).strip()
        if updated == current:
            return updated
        current = updated


def _base_key(value: str) -> str:
    return _simplify_name(_strip_trailing_bracket(value))


def _has_japanese(value: str) -> bool:
    return bool(_JAPANESE_RE.search(str(value or "")))


def _has_latin(value: str) -> bool:
    return bool(_LATIN_RE.search(str(value or "")))


def _sorted_unique(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        trimmed = str(value or "").strip()
        if not trimmed:
            continue
        normalized = _normalize_name(trimmed)
        if normalized in seen:
            continue
        seen.add(normalized)
        out.append(trimmed)
    out.sort(key=lambda value: (_normalize_name(value), value))
    return out


def _default_alias_config() -> dict[str, Any]:
    return {
        "__comment": (
            "Use Japanese canonical names. Add romaji, English, abbreviations, "
            "and related spellings as aliases."
        ),
        "__example_series": {
            "東方Project": ["Touhou Project", "Touhou", "東方"],
        },
        "__example_character": {
            "博麗霊夢": ["Hakurei Reimu", "Reimu Hakurei", "霊夢"],
        },
        "series": {},
        "character": {},
    }


@dataclass(frozen=True)
class TagStat:
    tag_id: str
    category: str
    name: str
    usage_count: int
    media_ids: tuple[str, ...]
    simplified_key: str
    base_key: str
    has_japanese: bool
    has_latin: bool

    @property
    def normalized_name(self) -> str:
        return _normalize_name(self.name)

    @property
    def signature_key(self) -> tuple[str, ...] | None:
        return self.media_ids if self.media_ids else None


@dataclass(frozen=True)
class CandidateGroup:
    category: str
    canonical: str
    aliases: tuple[str, ...]
    member_names: tuple[str, ...]
    reasons: tuple[str, ...]
    confidence: str
    apply: bool
    configured_canonical: bool


def load_alias_config(config_path: Path) -> dict[str, Any]:
    if not config_path.exists():
        return _default_alias_config()

    try:
        decoded = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        return _default_alias_config()

    if not isinstance(decoded, dict):
        return _default_alias_config()

    out = dict(decoded)
    for category in _SUPPORTED_CATEGORIES:
        category_map = out.get(category)
        if not isinstance(category_map, dict):
            out[category] = {}
    return out


def generate_tag_alias_candidates(
    *,
    db_path: Path,
    config_path: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    existing_doc = load_alias_config(config_path)
    existing_map = _extract_alias_map(existing_doc)
    stats_by_category = _load_tag_stats(db_path)

    merged_map = {
        category: {
            canonical: list(aliases)
            for canonical, aliases in existing_map[category].items()
        }
        for category in _SUPPORTED_CATEGORIES
    }

    configured_lookup = _build_configured_lookup(existing_map)
    applied_groups: list[CandidateGroup] = []
    review_groups: list[CandidateGroup] = []
    conflict_groups: list[dict[str, Any]] = []

    for category in _SUPPORTED_CATEGORIES:
        stats = stats_by_category[category]
        stats_by_name = {stat.normalized_name: stat for stat in stats}
        claimed_names: set[str] = set()

        anchor_results = _extend_existing_groups(
            category=category,
            existing_map=merged_map[category],
            configured_lookup=configured_lookup[category],
            stats=stats,
            stats_by_name=stats_by_name,
        )
        for group in anchor_results["applied"]:
            _merge_group_into_alias_map(merged_map[group.category], group)
            applied_groups.append(group)
            claimed_names.update(_normalize_name(name) for name in group.member_names)
        review_groups.extend(anchor_results["review"])
        conflict_groups.extend(anchor_results["conflicts"])

        high_confidence_groups = _build_high_confidence_groups(
            category=category,
            stats=stats,
            configured_lookup=configured_lookup[category],
            claimed_names=claimed_names,
        )
        for group in high_confidence_groups:
            _merge_group_into_alias_map(merged_map[group.category], group)
            applied_groups.append(group)
            claimed_names.update(_normalize_name(name) for name in group.member_names)

        review_groups.extend(
            _build_review_groups(
                category=category,
                stats=stats,
                configured_lookup=configured_lookup[category],
                claimed_names=claimed_names,
            )
        )

    merged_doc = dict(existing_doc)
    for category in _SUPPORTED_CATEGORIES:
        merged_doc[category] = _sorted_alias_map(merged_map[category])

    report = {
        "generatedAt": _now_iso(),
        "sourceDbPath": str(db_path),
        "sourceConfigPath": str(config_path),
        "stats": {
            category: {
                "dbTagCount": len(stats_by_category[category]),
                "configuredCanonicalCount": len(existing_map[category]),
                "appliedGroupCount": sum(1 for group in applied_groups if group.category == category),
                "reviewGroupCount": sum(1 for group in review_groups if group.category == category),
            }
            for category in _SUPPORTED_CATEGORIES
        },
        "applied": [
            _group_to_report_entry(group, stats_by_category[group.category])
            for group in applied_groups
        ],
        "review": [
            _group_to_report_entry(group, stats_by_category[group.category])
            for group in review_groups
        ],
        "conflicts": conflict_groups,
    }
    return merged_doc, report


def write_candidate_outputs(
    *,
    db_path: Path,
    config_path: Path,
    output_path: Path,
    report_path: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    merged_doc, report = generate_tag_alias_candidates(
        db_path=db_path,
        config_path=config_path,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(merged_doc, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return merged_doc, report


def _extract_alias_map(doc: dict[str, Any]) -> dict[str, dict[str, list[str]]]:
    out: dict[str, dict[str, list[str]]] = {category: {} for category in _SUPPORTED_CATEGORIES}
    for category in _SUPPORTED_CATEGORIES:
        raw_map = doc.get(category)
        if not isinstance(raw_map, dict):
            continue
        for canonical, raw_aliases in raw_map.items():
            canonical_name = str(canonical or "").strip()
            if not canonical_name:
                continue
            aliases = raw_aliases if isinstance(raw_aliases, list) else [raw_aliases]
            out[category][canonical_name] = _sorted_unique(
                [str(alias) for alias in aliases if str(alias).strip()],
            )
    return out


def _build_configured_lookup(
    existing_map: dict[str, dict[str, list[str]]],
) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {category: {} for category in _SUPPORTED_CATEGORIES}
    for category in _SUPPORTED_CATEGORIES:
        for canonical, aliases in existing_map[category].items():
            out[category][_normalize_name(canonical)] = canonical
            for alias in aliases:
                out[category][_normalize_name(alias)] = canonical
    return out


def _load_tag_stats(db_path: Path) -> dict[str, list[TagStat]]:
    out: dict[str, list[TagStat]] = {category: [] for category in _SUPPORTED_CATEGORIES}
    if not db_path.exists():
        return out

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            SELECT tm.tag_id, tm.category, tm.name, mtl.media_id
              FROM tag_master tm
              LEFT JOIN media_tag_links mtl ON mtl.tag_id = tm.tag_id
             WHERE tm.category IN ('series', 'character')
          ORDER BY tm.category COLLATE NOCASE, tm.name COLLATE NOCASE, mtl.media_id COLLATE NOCASE
            """
        ).fetchall()
    finally:
        conn.close()

    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        key = (str(row["category"]), str(row["tag_id"]))
        entry = grouped.setdefault(
            key,
            {
                "tag_id": str(row["tag_id"]),
                "category": str(row["category"]),
                "name": str(row["name"]),
                "media_ids": [],
            },
        )
        media_id = row["media_id"]
        if media_id is not None:
            entry["media_ids"].append(str(media_id))

    for entry in grouped.values():
        media_ids = tuple(sorted(dict.fromkeys(entry["media_ids"])))
        stat = TagStat(
            tag_id=entry["tag_id"],
            category=entry["category"],
            name=entry["name"].strip(),
            usage_count=len(media_ids),
            media_ids=media_ids,
            simplified_key=_simplify_name(entry["name"]),
            base_key=_base_key(entry["name"]),
            has_japanese=_has_japanese(entry["name"]),
            has_latin=_has_latin(entry["name"]),
        )
        if stat.name:
            out[stat.category].append(stat)

    for category in _SUPPORTED_CATEGORIES:
        out[category].sort(key=lambda stat: (_normalize_name(stat.name), stat.name))
    return out


def _extend_existing_groups(
    *,
    category: str,
    existing_map: dict[str, list[str]],
    configured_lookup: dict[str, str],
    stats: list[TagStat],
    stats_by_name: dict[str, TagStat],
) -> dict[str, list[Any]]:
    applied: list[CandidateGroup] = []
    review: list[CandidateGroup] = []
    conflicts: list[dict[str, Any]] = []
    claimed_names = set(configured_lookup.keys())
    available_stats = [
        stat for stat in stats if stat.normalized_name not in claimed_names
    ]
    candidate_matches: dict[str, list[tuple[str, list[str], bool]]] = defaultdict(list)

    for canonical, aliases in list(existing_map.items()):
        member_names = [canonical, *aliases]
        simplified_keys = {
            value
            for value in (_simplify_name(name) for name in member_names)
            if value
        }
        base_keys = {
            value
            for value in (_base_key(name) for name in member_names)
            if value
        }
        signature_keys = {
            stat.signature_key
            for name in member_names
            for stat in [stats_by_name.get(_normalize_name(name))]
            if stat is not None and stat.signature_key is not None
        }

        matched: list[tuple[TagStat, list[str], bool]] = []
        for stat in available_stats:
            reasons: list[str] = []
            if stat.simplified_key and stat.simplified_key in simplified_keys:
                reasons.append("same_simplified_key_as_configured_alias")
            elif stat.base_key and stat.base_key in base_keys and stat.base_key != stat.simplified_key:
                reasons.append("same_base_key_as_configured_alias")
            elif stat.signature_key is not None and stat.signature_key in signature_keys:
                reasons.append("same_media_signature_as_configured_alias")

            if not reasons:
                continue

            apply = "same_media_signature_as_configured_alias" not in reasons or category == "series"
            candidate_matches[stat.normalized_name].append((canonical, reasons, apply))

    for normalized_name, matches in candidate_matches.items():
        stat = stats_by_name.get(normalized_name)
        if stat is None:
            continue

        by_canonical: dict[str, dict[str, Any]] = {}
        for canonical, reasons, apply in matches:
            entry = by_canonical.setdefault(
                canonical,
                {"reasons": set(), "apply": False},
            )
            entry["reasons"].update(reasons)
            entry["apply"] = entry["apply"] or apply

        if len(by_canonical) > 1:
            conflicts.append(
                {
                    "category": category,
                    "name": stat.name,
                    "candidateCanonicals": sorted(
                        by_canonical.keys(),
                        key=lambda value: (_normalize_name(value), value),
                    ),
                }
            )
            continue

        canonical = next(iter(by_canonical.keys()))
        decision = by_canonical[canonical]
        group = CandidateGroup(
            category=category,
            canonical=canonical,
            aliases=(stat.name,),
            member_names=(canonical, stat.name),
            reasons=tuple(sorted(decision["reasons"])),
            confidence="high" if decision["apply"] else "medium",
            apply=bool(decision["apply"]),
            configured_canonical=True,
        )
        if group.apply:
            applied.append(group)
        else:
            review.append(group)

    return {
        "applied": applied,
        "review": review,
        "conflicts": conflicts,
    }


def _build_high_confidence_groups(
    *,
    category: str,
    stats: list[TagStat],
    configured_lookup: dict[str, str],
    claimed_names: set[str],
) -> list[CandidateGroup]:
    groups: list[CandidateGroup] = []
    occupied = set(configured_lookup.keys()) | set(claimed_names)

    for reason, bucket_value in (
        ("same_simplified_key", "simplified_key"),
        ("same_base_key", "base_key"),
    ):
        buckets: dict[str, list[TagStat]] = defaultdict(list)
        for stat in stats:
            if stat.normalized_name in occupied:
                continue
            key = getattr(stat, bucket_value)
            if not key:
                continue
            buckets[key].append(stat)

        for bucket in buckets.values():
            names = {_normalize_name(stat.name) for stat in bucket}
            if len(names) < 2:
                continue
            if reason == "same_base_key":
                if all(_strip_trailing_bracket(stat.name) == stat.name for stat in bucket):
                    continue
            group = _build_group_from_stats(
                category=category,
                stats=bucket,
                reasons=(reason,),
                confidence="high",
                apply=True,
                configured_canonical=False,
            )
            groups.append(group)
            occupied.update(_normalize_name(name) for name in group.member_names)

    return groups


def _build_review_groups(
    *,
    category: str,
    stats: list[TagStat],
    configured_lookup: dict[str, str],
    claimed_names: set[str],
) -> list[CandidateGroup]:
    groups: list[CandidateGroup] = []
    occupied = set(configured_lookup.keys()) | set(claimed_names)
    buckets: dict[tuple[str, ...], list[TagStat]] = defaultdict(list)

    for stat in stats:
        if stat.normalized_name in occupied:
            continue
        if stat.usage_count < 2 or stat.signature_key is None:
            continue
        buckets[stat.signature_key].append(stat)

    for bucket in buckets.values():
        names = {_normalize_name(stat.name) for stat in bucket}
        if len(names) != 2:
            continue
        if not any(stat.has_japanese for stat in bucket):
            continue
        if not any(stat.has_latin for stat in bucket):
            continue
        groups.append(
            _build_group_from_stats(
                category=category,
                stats=bucket,
                reasons=("same_media_signature_mixed_script",),
                confidence="medium",
                apply=False,
                configured_canonical=False,
            )
        )

    return groups


def _build_group_from_stats(
    *,
    category: str,
    stats: list[TagStat],
    reasons: tuple[str, ...],
    confidence: str,
    apply: bool,
    configured_canonical: bool,
) -> CandidateGroup:
    canonical = _pick_canonical_name(stats)
    alias_names = [
        stat.name
        for stat in _sort_stats(stats)
        if _normalize_name(stat.name) != _normalize_name(canonical)
    ]
    member_names = [canonical, *alias_names]
    return CandidateGroup(
        category=category,
        canonical=canonical,
        aliases=tuple(_sorted_unique(alias_names)),
        member_names=tuple(_sorted_unique(member_names)),
        reasons=tuple(reasons),
        confidence=confidence,
        apply=apply,
        configured_canonical=configured_canonical,
    )


def _pick_canonical_name(stats: list[TagStat]) -> str:
    preferred = [stat for stat in stats if stat.has_japanese] or list(stats)
    return _sort_stats(preferred)[0].name


def _sort_stats(stats: list[TagStat]) -> list[TagStat]:
    return sorted(
        stats,
        key=lambda stat: (
            0 if stat.has_japanese else 1,
            -stat.usage_count,
            -len(stat.name),
            _normalize_name(stat.name),
            stat.name,
        ),
    )


def _merge_group_into_alias_map(
    category_map: dict[str, list[str]],
    group: CandidateGroup,
) -> None:
    existing_aliases = list(category_map.get(group.canonical, []))
    category_map[group.canonical] = _sorted_unique(
        existing_aliases + list(group.aliases),
    )


def _sorted_alias_map(category_map: dict[str, list[str]]) -> dict[str, list[str]]:
    ordered: dict[str, list[str]] = {}
    for canonical in sorted(category_map.keys(), key=lambda value: (_normalize_name(value), value)):
        aliases = [alias for alias in category_map[canonical] if _normalize_name(alias) != _normalize_name(canonical)]
        ordered[canonical] = _sorted_unique(aliases)
    return ordered


def _group_to_report_entry(
    group: CandidateGroup,
    stats: list[TagStat],
) -> dict[str, Any]:
    stats_by_name = {stat.normalized_name: stat for stat in stats}
    members = []
    for name in group.member_names:
        stat = stats_by_name.get(_normalize_name(name))
        members.append(
            {
                "name": name,
                "usageCount": stat.usage_count if stat is not None else 0,
                "hasJapanese": stat.has_japanese if stat is not None else _has_japanese(name),
                "hasLatin": stat.has_latin if stat is not None else _has_latin(name),
                "mediaCount": len(stat.media_ids) if stat is not None else 0,
            }
        )
    members.sort(
        key=lambda entry: (
            0 if entry["name"] == group.canonical else 1,
            -int(entry["usageCount"]),
            _normalize_name(str(entry["name"])),
        )
    )
    return {
        "category": group.category,
        "canonical": group.canonical,
        "aliases": list(group.aliases),
        "memberNames": list(group.member_names),
        "reasons": list(group.reasons),
        "confidence": group.confidence,
        "apply": group.apply,
        "configuredCanonical": group.configured_canonical,
        "members": members,
    }
