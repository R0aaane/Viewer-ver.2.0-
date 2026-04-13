from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from pathlib import Path


logger = logging.getLogger(__name__)


def _normalize_name(name: str) -> str:
    return name.strip().casefold()


def _lookup_key(category: str, name: str) -> str:
    return f"{category}\0{_normalize_name(name)}"


@dataclass(frozen=True)
class _TagAliasGroup:
    category: str
    canonical: str
    aliases: list[str]
    all_names: list[str]

    @classmethod
    def create(
        cls,
        *,
        category: str,
        canonical: str,
        aliases: list[str],
    ) -> "_TagAliasGroup | None":
        normalized_canonical = canonical.strip()
        if not normalized_canonical:
            return None

        out: list[str] = []
        seen: set[str] = set()

        def add_value(value: str) -> None:
            trimmed = value.strip()
            if not trimmed:
                return
            normalized = _normalize_name(trimmed)
            if normalized in seen:
                return
            seen.add(normalized)
            out.append(trimmed)

        add_value(normalized_canonical)
        for alias in aliases:
            add_value(alias)

        if not out:
            return None

        return cls(
            category=category,
            canonical=normalized_canonical,
            aliases=[value for value in out if value != normalized_canonical],
            all_names=out,
        )

    def matches_partial(self, raw_query: str) -> bool:
        normalized_query = _normalize_name(raw_query)
        if not normalized_query:
            return True
        return any(normalized_query in _normalize_name(value) for value in self.all_names)


class TagAliasService:
    _supported_categories = ("series", "character")

    def __init__(
        self,
        *,
        groups_by_category: dict[str, list[_TagAliasGroup]] | None = None,
        groups_by_lookup_key: dict[str, _TagAliasGroup] | None = None,
    ) -> None:
        self._groups_by_category = groups_by_category or {}
        self._groups_by_lookup_key = groups_by_lookup_key or {}

    @classmethod
    def load_default(cls, config_path: Path) -> "TagAliasService":
        try:
            raw_json = config_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            logger.warning("[tag-alias] config missing: %s", config_path)
            return cls()
        except Exception:
            logger.exception("[tag-alias] failed to read config: %s", config_path)
            return cls()

        try:
            return cls.from_json_text(raw_json)
        except Exception:
            logger.exception("[tag-alias] failed to parse config: %s", config_path)
            return cls()

    @classmethod
    def from_json_text(cls, raw_json: str) -> "TagAliasService":
        decoded = json.loads(raw_json)
        if not isinstance(decoded, dict):
            return cls()

        groups_by_category: dict[str, list[_TagAliasGroup]] = {}
        groups_by_lookup_key: dict[str, _TagAliasGroup] = {}

        for category in cls._supported_categories:
            category_map = decoded.get(category)
            if not isinstance(category_map, dict):
                continue

            groups: list[_TagAliasGroup] = []
            for canonical, raw_aliases in category_map.items():
                aliases: list[str]
                if isinstance(raw_aliases, list):
                    aliases = [str(value) for value in raw_aliases]
                elif isinstance(raw_aliases, str):
                    aliases = [raw_aliases]
                else:
                    aliases = []

                group = _TagAliasGroup.create(
                    category=category,
                    canonical=str(canonical),
                    aliases=aliases,
                )
                if group is None:
                    continue

                groups.append(group)
                for candidate in group.all_names:
                    groups_by_lookup_key[_lookup_key(category, candidate)] = group

            if groups:
                groups_by_category[category] = groups

        return cls(
            groups_by_category=groups_by_category,
            groups_by_lookup_key=groups_by_lookup_key,
        )

    @property
    def is_configured(self) -> bool:
        return bool(self._groups_by_lookup_key)

    def supports_category(self, category: str) -> bool:
        normalized_category = str(category or "").strip()
        return bool(self._groups_by_category.get(normalized_category))

    def canonicalize_name(self, category: str, raw_name: str) -> str:
        trimmed = str(raw_name or "").strip()
        if not trimmed:
            return ""
        group = self._groups_by_lookup_key.get(_lookup_key(category, trimmed))
        return group.canonical if group is not None else trimmed

    def equivalent_names(
        self,
        category: str,
        raw_name: str,
        *,
        partial: bool = False,
    ) -> list[str]:
        trimmed = str(raw_name or "").strip()
        if not trimmed:
            return []

        normalized_category = str(category or "").strip()
        groups = self._groups_by_category.get(normalized_category) or []
        out: list[str] = []
        seen: set[str] = set()

        def add_candidate(value: str) -> None:
            normalized = value.strip()
            if not normalized:
                return
            lookup = _normalize_name(normalized)
            if lookup in seen:
                return
            seen.add(lookup)
            out.append(normalized)

        if not groups:
            add_candidate(trimmed)
            return out

        if partial:
            for group in groups:
                if not group.matches_partial(trimmed):
                    continue
                for candidate in group.all_names:
                    add_candidate(candidate)
            add_candidate(trimmed)
            return out

        group = self._groups_by_lookup_key.get(_lookup_key(normalized_category, trimmed))
        if group is not None:
            for candidate in group.all_names:
                add_candidate(candidate)
            return out

        add_candidate(trimmed)
        return out

    def equivalent_names_across_categories(
        self,
        raw_name: str,
        *,
        partial: bool = False,
    ) -> list[str]:
        trimmed = str(raw_name or "").strip()
        if not trimmed:
            return []

        out: list[str] = []
        seen: set[str] = set()

        def add_candidate(value: str) -> None:
            normalized = value.strip()
            if not normalized:
                return
            lookup = _normalize_name(normalized)
            if lookup in seen:
                return
            seen.add(lookup)
            out.append(normalized)

        for category in self._supported_categories:
            for candidate in self.equivalent_names(category, trimmed, partial=partial):
                add_candidate(candidate)

        if not out:
            add_candidate(trimmed)
        return out

    def matches_contains(self, category: str, candidate_name: str, contains: str) -> bool:
        normalized_contains = _normalize_name(contains)
        if not normalized_contains:
            return True

        group = self._groups_by_lookup_key.get(_lookup_key(category, candidate_name))
        if group is None:
            return normalized_contains in _normalize_name(candidate_name)

        return any(normalized_contains in _normalize_name(value) for value in group.all_names)
