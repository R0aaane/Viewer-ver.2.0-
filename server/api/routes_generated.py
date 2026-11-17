import asyncio
import re
import json
import tempfile
from pathlib import Path
from contextlib import closing
from typing import Annotated, Literal
from pydantic import BaseModel, Field, StringConstraints, SecretStr
from server.services import generated_catalog, change_log

from fastapi import APIRouter, Depends, HTTPException, Query, Request, WebSocket, WebSocketDisconnect, UploadFile, File, Form
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from server.services.auth_service import require_bearer_token, authenticate_connection, authentication_configured

router = APIRouter(prefix="/generated", tags=["generated"])


def library_for(request: Request, _=Depends(require_bearer_token)):
    library = request.app.state.generated_library
    configured = authentication_configured(request.app.state) or getattr(request.app.state.settings, 'tailnet_without_token', False)
    if not configured or library is None:
        raise HTTPException(503, "Generated library is disabled")
    expected_epoch = request.headers.get("x-sync-epoch")
    if expected_epoch and request.method not in ("GET", "HEAD"):
        with closing(library.connect()) as db:
            if db.execute("SELECT epoch FROM sync_meta WHERE id=1").fetchone()[0] != expected_epoch:
                raise HTTPException(409, "Library was restored; reload before editing")
    return library


class ManualTag(BaseModel):
    category: Literal["free", "artist", "generation", "character", "series"]
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)]


class GalleryQuery(BaseModel):
    deleted: bool = False
    prompt: str = Field("", max_length=512)
    all_tags: list[ManualTag] = Field(default_factory=list, max_length=16)
    any_tags: list[ManualTag] = Field(default_factory=list, max_length=16)
    no_tags: list[ManualTag] = Field(default_factory=list, max_length=16)
    favorite: bool = False
    from_ms: int | None = None
    before_ms: int | None = None
    sort: Literal["newest", "oldest", "name"] = "newest"
    offset: int = Field(0, ge=0, le=2147483647)
    limit: int = Field(48, ge=1, le=100)


class TagEdit(BaseModel):
    expected_versions: dict[str, Annotated[int, Field(ge=0)]] | None = Field(default=None, max_length=100)
    media_ids: list[Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]] = Field(min_length=1, max_length=100)
    tag: ManualTag
    operation: Literal["add", "remove"]


class RelayTarget(BaseModel):
    base_url: str = Field(min_length=1, max_length=2048)
    token: SecretStr


def relay_for(request: Request, _=Depends(require_bearer_token)):
    relay = getattr(request.app.state, 'generated_relay', None)
    if relay is None or request.client.host not in ('127.0.0.1','::1'):
        raise HTTPException(503, 'Local image relay is disabled')
    return relay


@router.post('/relay')
def configure_relay(target: RelayTarget, relay=Depends(relay_for)):
    try: relay.configure(target.base_url, target.token.get_secret_value())
    except ValueError as exc: raise HTTPException(422, str(exc)) from exc
    return relay.status()


@router.get('/relay')
def relay_status(relay=Depends(relay_for)):
    return relay.status()


@router.post("/upload")
async def upload_generated(file: UploadFile = File(...), tags: str = Form("[]", max_length=65536), library=Depends(library_for)):
    # Keep uploads isolated from the document import/organization pipeline.
    try:
        try:
            raw_tags = json.loads(tags)
            if not isinstance(raw_tags, list) or len(raw_tags) > 100:
                raise ValueError("Invalid tags")
            validated_tags = [ManualTag.model_validate(tag) for tag in raw_tags]
        except (ValueError, TypeError) as exc:
            raise HTTPException(422, "Invalid tags") from exc
        with tempfile.TemporaryDirectory(prefix="generated-upload-") as temp:
            path = Path(temp) / "image"
            size = 0
            with path.open("wb") as output:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > 64 * 1024 * 1024:
                        raise HTTPException(413, "Image exceeds 64 MiB")
                    output.write(chunk)
            try:
                digest = await run_in_threadpool(library.import_download, path)
            except ValueError as exc:
                raise HTTPException(422, "Invalid image") from exc
            if digest is None:
                raise HTTPException(503, "Generated library is busy; retry later")
            with closing(library.connect()) as db, db:
                # Union manual tags on repeat transfer; never remove host edits.
                changed = 0
                for tag in validated_tags:
                    changed += db.execute("INSERT OR IGNORE INTO manual_tags VALUES(?,?,?)",
                                          (digest, tag.category, tag.name)).rowcount
                if changed:
                    db.execute("INSERT INTO tag_revisions VALUES(?,1) ON CONFLICT(digest) DO UPDATE SET version=version+1", (digest,))
            return {"mediaId": digest}
    finally:
        await file.close()


@router.post("/search")
def search_gallery(query: GalleryQuery, library=Depends(library_for)):
    with closing(library.connect()) as db:
        return generated_catalog.search(db, query)


@router.get("/media/{media_id}/details")
def details(media_id: str, library=Depends(library_for)):
    with closing(library.connect()) as db:
        result = generated_catalog.detail(db, media_id)
    if result is None:
        raise HTTPException(404, "Image unavailable")
    return result


@router.post("/media/{media_id}/reanalyze")
def reanalyze(media_id: str, library=Depends(library_for)):
    path = library.media_path(media_id, False)
    if path is None or not path.is_file():
        raise HTTPException(404, "Image unavailable")
    with closing(library.connect()) as db:
        generated_catalog.analyze(db, media_id, path)
        return generated_catalog.detail(db, media_id)


@router.put("/media/{media_id}/favorite")
def favorite(media_id: str, value: bool, expected_version: int | None = Query(None, ge=0), library=Depends(library_for)):
    if library.media_path(media_id, False) is None:
        raise HTTPException(404, "Image unavailable")
    with closing(library.connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        if isinstance(expected_version, int) and change_log.version(db, media_id) != expected_version:
            raise HTTPException(409, "Image changed; reload before editing")
        if value:
            db.execute("INSERT OR IGNORE INTO generated_favorites VALUES (?)", (media_id,))
        else:
            db.execute("DELETE FROM generated_favorites WHERE digest=?", (media_id,))
        current_version = change_log.version(db, media_id)
    return {"favorite": value, "version": current_version}


class ImageEdit(BaseModel):
    expected_version: int = Field(ge=0)
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=255)] | None = None
    deleted: bool | None = None


@router.delete("/media/{media_id}")
def purge_image(media_id: str, request: Request, expected_version: int = Query(..., ge=0), library=Depends(library_for)):
    if not re.fullmatch(r"[0-9a-f]{64}", media_id):
        raise HTTPException(404, "Image unavailable")
    try:
        library.purge(media_id, expected_version, request.headers.get("x-sync-epoch"))
    except FileNotFoundError:
        raise HTTPException(404, "Image unavailable")
    except ValueError as exc:
        raise HTTPException(409, str(exc)) from exc
    except BlockingIOError:
        raise HTTPException(503, "Generated library is busy; retry later")
    return {"deleted": True}


@router.get("/tags")
def list_tags(library=Depends(library_for)):
    with closing(library.connect()) as db:
        return {"items": [dict(row) for row in db.execute("""SELECT t.category,t.name,COUNT(*) AS count
            FROM manual_tags t JOIN images i ON i.digest=t.digest AND i.state='ready'
            LEFT JOIN generated_overrides o ON o.digest=t.digest WHERE COALESCE(o.deleted,0)=0
            GROUP BY t.category,t.name ORDER BY t.category,t.name LIMIT 500""")]}


@router.patch("/media/{media_id}")
def edit_image(media_id: str, edit: ImageEdit, library=Depends(library_for)):
    if edit.name is not None and (any(c in edit.name for c in '/\\\x00') or edit.name in (".", "..")):
        raise HTTPException(422, "Use a display name without path separators")
    with closing(library.connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        if not db.execute("SELECT 1 FROM images WHERE digest=? AND state='ready'", (media_id,)).fetchone():
            raise HTTPException(404, "Image unavailable")
        if change_log.version(db, media_id) != edit.expected_version:
            raise HTTPException(409, "Image changed; reload before editing")
        old = db.execute("SELECT name,deleted FROM generated_overrides WHERE digest=?", (media_id,)).fetchone()
        name = edit.name if edit.name is not None else (old["name"] if old else None)
        deleted = int(edit.deleted) if edit.deleted is not None else (old["deleted"] if old else 0)
        db.execute("""INSERT INTO generated_overrides VALUES(?,?,?) ON CONFLICT(digest)
            DO UPDATE SET name=excluded.name,deleted=excluded.deleted""", (media_id, name, deleted))
        return {"version": change_log.version(db, media_id)}


@router.get("/changes")
def changes(after: int = Query(0, ge=0), epoch: str | None = None,
            limit: int = Query(100, ge=1, le=250), library=Depends(library_for)):
    with closing(library.connect()) as db:
        return change_log.changes(db, after, epoch, limit)


@router.post("/tags")
def edit_tags(edit: TagEdit, library=Depends(library_for)):
    ids = set(edit.media_ids)
    if edit.expected_versions is not None and set(edit.expected_versions) != ids:
        raise HTTPException(422, "Supply one tag version per image")
    with closing(library.connect()) as db, db:
        db.execute("BEGIN IMMEDIATE")
        for digest in ids:
            if not db.execute("SELECT 1 FROM images WHERE digest=? AND state='ready'", (digest,)).fetchone():
                raise HTTPException(404, "Image unavailable")
            args = (digest, edit.tag.category, edit.tag.name)
            if edit.expected_versions is not None:
                row = db.execute("SELECT version FROM tag_revisions WHERE digest=?", (digest,)).fetchone()
                if edit.expected_versions[digest] != (row[0] if row else 0):
                    raise HTTPException(409, "Tags changed; reload before editing")
            if edit.operation == "add":
                change = db.execute("INSERT OR IGNORE INTO manual_tags VALUES (?,?,?)", args)
            else:
                change = db.execute("DELETE FROM manual_tags WHERE digest=? AND category=? AND name=?", args)
            if change.rowcount:
                db.execute("""INSERT INTO tag_revisions VALUES (?,1)
                    ON CONFLICT(digest) DO UPDATE SET version=version+1""", (digest,))
    return {"updated": len(set(edit.media_ids))}


@router.get("/events")
def events(after: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=250),
           library=Depends(library_for)):
    return {"items": library.events(after, limit)}


@router.websocket("/events/ws")
async def subscribe(socket: WebSocket, after: int = Query(0, ge=0)):
    state = socket.app.state
    authorization = socket.headers.get("authorization")
    if not authenticate_connection(socket, authorization) or state.generated_library is None:
        await socket.close(code=1008)
        return
    await socket.accept()
    try:
        while True:
            if not await run_in_threadpool(authenticate_connection, socket, authorization):
                await socket.close(code=1008)
                return
            rows = await run_in_threadpool(state.generated_library.events, after, 100)
            if rows:
                await socket.send_json({"items": rows})
                after = rows[-1]["seq"]
                continue
            try:
                await asyncio.wait_for(socket.receive_text(), timeout=2)
            except asyncio.TimeoutError:
                pass
    except WebSocketDisconnect:
        return


def _file(library, media_id, thumbnail):
    if not re.fullmatch("[0-9a-f]{64}", media_id):
        raise HTTPException(404, "Unknown media ID")
    path = library.media_path(media_id, thumbnail)
    if path is None or not path.is_file():
        raise HTTPException(404, "Image unavailable")
    return FileResponse(path)


@router.get("/media/{media_id}")
def original(media_id: str, library=Depends(library_for)):
    return _file(library, media_id, False)


@router.get("/media/{media_id}/thumbnail")
def thumbnail(media_id: str, library=Depends(library_for)):
    return _file(library, media_id, True)
