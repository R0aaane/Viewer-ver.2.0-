"""Transactional, additive change journals for the two existing catalogs."""
import uuid


def initialize(db, generated=False):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS sync_meta (id INTEGER PRIMARY KEY CHECK(id=1), epoch TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS entity_versions (media_id TEXT PRIMARY KEY, version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_changes (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, media_id TEXT NOT NULL,
            version INTEGER NOT NULL, kind TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sync_changes_media ON sync_changes(media_id);
    """)
    db.execute("INSERT OR IGNORE INTO sync_meta VALUES(1,?)", (str(uuid.uuid4()),))
    db.commit()
    if generated:
        rules = [
            ("images", "digest", "insert", "NEW.state='ready'", "'import'"),
            ("images", "digest", "update", "NEW.state='ready' AND OLD.state<>'ready'", "'import'"),
            ("generation_info", "digest", "update", "NEW.normalized IS NOT OLD.normalized", "'metadata'"),
            ("manual_tags", "digest", "insert", "1", "'tags'"),
            ("manual_tags", "digest", "delete", "1", "'tags'"),
            ("generated_favorites", "digest", "insert", "1", "'favorite'"),
            ("generated_favorites", "digest", "delete", "1", "'favorite'"),
            ("generated_overrides", "digest", "insert", "1", "CASE WHEN NEW.deleted=1 THEN 'delete' ELSE 'rename' END"),
            ("generated_overrides", "digest", "update", "NEW.deleted<>OLD.deleted OR NEW.name IS NOT OLD.name",
             "CASE WHEN NEW.deleted<>OLD.deleted THEN CASE WHEN NEW.deleted=1 THEN 'delete' ELSE 'restore' END ELSE 'rename' END"),
        ]
        table, key, condition = "images", "digest", "state='ready'"
    else:
        different = " OR ".join(f"NEW.{c} IS NOT OLD.{c}" for c in (
            "display_name", "full_path", "etag", "size_bytes", "modified_epoch_ms", "is_deleted"))
        rules = [("media_records", "media_id", "insert", "1", "'import'"),
                 ("media_records", "media_id", "update", different,
                  "CASE WHEN NEW.is_deleted<>OLD.is_deleted THEN CASE WHEN NEW.is_deleted=1 THEN 'delete' ELSE 'restore' END "
                  "WHEN NEW.display_name IS NOT OLD.display_name OR NEW.full_path IS NOT OLD.full_path THEN 'rename' ELSE 'metadata' END"),
                 ("media_records", "media_id", "delete", "1", "'delete'")]
        for related, kind in (("media_tag_links", "tags"), ("media_favorites", "favorite")):
            for operation in ("insert", "delete"):
                rules.append((related, "media_id", operation, "1", f"'{kind}'"))
        table, key, condition = "media_records", "media_id", "1"
    for target, column, operation, when, kind in rules:
        row = "OLD" if operation == "delete" else "NEW"
        db.executescript(f"""
            CREATE TRIGGER IF NOT EXISTS sync_{target}_{operation} AFTER {operation.upper()} ON {target}
            WHEN {when} BEGIN
                INSERT INTO entity_versions VALUES ({row}.{column},1)
                    ON CONFLICT(media_id) DO UPDATE SET version=version+1;
                INSERT INTO sync_changes(media_id,version,kind)
                    SELECT {row}.{column},version,{kind} FROM entity_versions WHERE media_id={row}.{column};
            END;
        """)
    if not generated:
        db.executescript("""
            CREATE TRIGGER IF NOT EXISTS sync_tag_master_update AFTER UPDATE ON tag_master
            WHEN NEW.name IS NOT OLD.name OR NEW.category IS NOT OLD.category BEGIN
                INSERT INTO entity_versions SELECT media_id,1 FROM media_tag_links WHERE tag_id=NEW.tag_id
                    ON CONFLICT(media_id) DO UPDATE SET version=version+1;
                INSERT INTO sync_changes(media_id,version,kind)
                    SELECT l.media_id,v.version,'tags' FROM media_tag_links l JOIN entity_versions v ON v.media_id=l.media_id
                    WHERE l.tag_id=NEW.tag_id;
            END;
        """)
    with db:
        db.execute(f"INSERT OR IGNORE INTO entity_versions SELECT {key},1 FROM {table} WHERE {condition}")
        db.execute(f"""INSERT INTO sync_changes(media_id,version,kind)
            SELECT t.{key},v.version,'snapshot' FROM {table} t JOIN entity_versions v ON v.media_id=t.{key}
            WHERE {condition} AND NOT EXISTS (SELECT 1 FROM sync_changes c WHERE c.media_id=t.{key})""")


def version(db, media_id):
    row = db.execute("SELECT version FROM entity_versions WHERE media_id=?", (media_id,)).fetchone()
    return row[0] if row else 0


def changes(db, after, epoch, limit):
    if not db.in_transaction:
        db.execute("BEGIN")
    current = db.execute("SELECT epoch FROM sync_meta WHERE id=1").fetchone()[0]
    head = db.execute("SELECT COALESCE(MAX(seq),0) FROM sync_changes").fetchone()[0]
    if (epoch is not None and epoch != current) or after > head:
        return {"epoch": current, "cursor": 0, "items": [], "hasMore": False, "resetRequired": True}
    rows = db.execute("SELECT seq,media_id AS mediaId,version,kind FROM sync_changes WHERE seq>? ORDER BY seq LIMIT ?",
                      (after, limit + 1)).fetchall()
    items = [dict(row) for row in rows[:limit]]
    return {"epoch": current, "cursor": items[-1]["seq"] if items else after,
            "items": items, "hasMore": len(rows) > limit, "resetRequired": False}
