from __future__ import annotations


def ensure_pillow_plugins() -> None:
    try:
        import pillow_avif  # noqa: F401
    except Exception:
        pass
