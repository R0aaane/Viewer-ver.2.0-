import json
import os
from contextlib import nullcontext
from pathlib import Path

from server.services.generation_metadata import read_generation
from server.services import change_log


def initialize(db):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS generation_info (
            digest TEXT PRIMARY KEY, name TEXT NOT NULL, file_time_ms INTEGER NOT NULL,
            workflow TEXT, prompt TEXT, normalized TEXT NOT NULL, date_source TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS generation_date ON generation_info(file_time_ms, digest);
        CREATE INDEX IF NOT EXISTS generation_newest ON generation_info(file_time_ms DESC, digest);
        CREATE INDEX IF NOT EXISTS generation_name ON generation_info(name COLLATE NOCASE, digest, file_time_ms);
        CREATE TABLE IF NOT EXISTS manual_tags (
            digest TEXT NOT NULL, category TEXT NOT NULL, name TEXT NOT NULL,
            PRIMARY KEY(digest, category, name)
        );
        CREATE INDEX IF NOT EXISTS generated_tag_lookup ON manual_tags(category, name, digest);
        CREATE TABLE IF NOT EXISTS generated_favorites (digest TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS tag_revisions (digest TEXT PRIMARY KEY, version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS generated_overrides (
            digest TEXT PRIMARY KEY, name TEXT, deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1))
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS prompt_search USING fts5(text);
        CREATE INDEX IF NOT EXISTS generated_sources_digest ON sources(digest);
    """)
    change_log.initialize(db, generated=True)


def analyze(db, digest, original, *, commit=True):
    raw, info = read_generation(original)
    source = db.execute("SELECT path,signature FROM sources WHERE digest=? ORDER BY observed_ns LIMIT 1",
                        (digest,)).fetchone()
    name = Path(source["path"]).name if source else original.name
    if source:
        windows = os.name == "nt"
        stamp = int(source["signature"].split(":")[4 if windows else 3])
        date_source = "sourceCreated" if windows else "sourceModified"
    else:
        stamp = original.stat().st_mtime_ns
        date_source = "libraryModified"
    text = "\n".join(s[k] for s in info["samplers"] for k in ("positive", "negative"))
    # Update only derived data. The rowid is also the stable FTS key.
    with db if commit else nullcontext():
        db.execute("""INSERT INTO generation_info VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(digest) DO UPDATE SET workflow=excluded.workflow,
            prompt=excluded.prompt, normalized=excluded.normalized""",
                   (digest, name, stamp // 1_000_000, raw["workflow"], raw["prompt"],
                    json.dumps(info, ensure_ascii=True), date_source))
        rowid = db.execute("SELECT rowid FROM generation_info WHERE digest=?", (digest,)).fetchone()[0]
        db.execute("DELETE FROM prompt_search WHERE rowid=?", (rowid,))
        db.execute("INSERT INTO prompt_search(rowid,text) VALUES (?,?)", (rowid, text))


def search(db, query):
    conditions = ["i.state='ready'", "COALESCE(o.deleted,0)=?"]
    args = [int(getattr(query, "deleted", False))]
    if query.prompt.strip():
        terms = ['"' + t.replace('"', '""') + '"' for t in query.prompt.split()]
        conditions.append("g.rowid IN (SELECT rowid FROM prompt_search WHERE prompt_search MATCH ?)")
        args.append(" AND ".join(terms))
    for tags, mode in ((query.all_tags, "all"), (query.any_tags, "any"), (query.no_tags, "none")):
        if not tags:
            continue
        clauses = []
        for tag in tags:
            clauses.append("EXISTS (SELECT 1 FROM manual_tags t WHERE t.digest=g.digest AND t.category=? AND t.name=?)")
            args.extend([tag.category, tag.name])
        group = (" AND " if mode == "all" else " OR ").join(clauses)
        conditions.append(("NOT " if mode == "none" else "") + "(" + group + ")")
    if query.favorite:
        conditions.append("EXISTS (SELECT 1 FROM generated_favorites f WHERE f.digest=g.digest)")
    for bound, op in ((query.from_ms, ">="), (query.before_ms, "<")):
        if bound is not None:
            conditions.append("g.file_time_ms " + op + " ?")
            args.append(bound)
    order = {"newest": "g.file_time_ms DESC", "oldest": "g.file_time_ms", "name": "COALESCE(o.name,g.name) COLLATE NOCASE"}[query.sort]
    # Select the page before joining revision tables. Keep generation_info as
    # the outer loop so date indexes can serve LIMIT without sorting all images.
    page_order = {"newest": "p.fileTimeMs DESC", "oldest": "p.fileTimeMs",
                  "name": "COALESCE(o.name,g.name) COLLATE NOCASE"}[query.sort]
    catalog = "generation_info g INDEXED BY generation_name" if query.sort == "name" else "generation_info g"
    rows = db.execute("""WITH page AS MATERIALIZED (
        SELECT g.digest AS mediaId,g.file_time_ms AS fileTimeMs
        FROM """ + catalog + """ CROSS JOIN images i ON i.digest=g.digest
        LEFT JOIN generated_overrides o ON o.digest=g.digest WHERE """ + " AND ".join(conditions)
        + " ORDER BY " + order + """, g.digest LIMIT ? OFFSET ?)
        SELECT p.mediaId,COALESCE(o.name,g.name) AS name,p.fileTimeMs,COALESCE(o.deleted,0) AS deleted,
        (f.digest IS NOT NULL) AS favorite,COALESCE(e.version,0) AS version,COALESCE(v.version,0) AS tagVersion,
        (SELECT epoch FROM sync_meta WHERE id=1) AS epoch FROM page p
        JOIN generation_info g ON g.digest=p.mediaId
        LEFT JOIN generated_overrides o ON o.digest=p.mediaId
        LEFT JOIN generated_favorites f ON f.digest=p.mediaId
        LEFT JOIN tag_revisions v ON v.digest=p.mediaId
        LEFT JOIN entity_versions e ON e.media_id=p.mediaId
        ORDER BY """ + page_order + ", p.mediaId", (*args, query.limit + 1, query.offset)).fetchall()
    return {"items": [dict(r) for r in rows[:query.limit]], "hasMore": len(rows) > query.limit}


def detail(db, digest):
    if not db.in_transaction:
        db.execute("BEGIN")
    row = db.execute("""SELECT g.*, COALESCE((SELECT version FROM tag_revisions WHERE digest=g.digest),0) AS tagVersion,
        EXISTS(SELECT 1 FROM generated_favorites WHERE digest=g.digest) AS favorite
        FROM generation_info g JOIN images i ON i.digest=g.digest WHERE i.state='ready' AND g.digest=?""",
                     (digest,)).fetchone()
    if not row:
        return None
    tags = db.execute("SELECT category,name FROM manual_tags WHERE digest=? ORDER BY category,name", (digest,))
    override = db.execute("SELECT name,deleted FROM generated_overrides WHERE digest=?", (digest,)).fetchone()
    return {"mediaId": digest, "version": change_log.version(db, digest),
            "epoch": db.execute("SELECT epoch FROM sync_meta WHERE id=1").fetchone()[0],
            "deleted": bool(override and override["deleted"]),
            "tagVersion": row["tagVersion"], "name": (override["name"] if override and override["name"] else row["name"]), "fileTimeMs": row["file_time_ms"],
            "dateSource": row["date_source"], "favorite": bool(row["favorite"]), "tags": [dict(t) for t in tags],
            "workflow": row["workflow"], "prompt": row["prompt"], "generation": json.loads(row["normalized"])}
