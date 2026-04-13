from __future__ import annotations

import argparse
from pathlib import Path

from server.services.tag_alias_candidate_generator import write_candidate_outputs


def _parse_args() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description=(
            "Generate suggested series / character tag alias config from the "
            "current metadata DB. High-confidence suggestions are merged into "
            "the output config, while lower-confidence guesses go to the report."
        )
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=project_root / "data" / "metadata.db",
        help="Path to metadata SQLite DB",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=project_root / "assets" / "config" / "tag_aliases.json",
        help="Path to the current alias config JSON",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=project_root / "assets" / "config" / "tag_aliases.generated.json",
        help="Path for the merged candidate config JSON",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=project_root / "data" / "tag_alias_candidates.report.json",
        help="Path for the detailed review report JSON",
    )
    return parser.parse_args()


def main() -> int:
    options = _parse_args()
    merged_doc, report = write_candidate_outputs(
        db_path=options.db.resolve(),
        config_path=options.config.resolve(),
        output_path=options.output.resolve(),
        report_path=options.report.resolve(),
    )
    applied_count = len(report.get("applied") or [])
    review_count = len(report.get("review") or [])
    conflict_count = len(report.get("conflicts") or [])
    print(f"DB: {options.db.resolve()}")
    print(f"Config: {options.config.resolve()}")
    print(f"Output: {options.output.resolve()}")
    print(f"Report: {options.report.resolve()}")
    print(
        "Generated alias candidates "
        f"(applied={applied_count}, review={review_count}, conflicts={conflict_count})"
    )
    print(
        "Configured canonical counts: "
        f"series={len((merged_doc.get('series') or {}))}, "
        f"character={len((merged_doc.get('character') or {}))}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
