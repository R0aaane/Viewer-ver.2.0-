from contextlib import closing

from fastapi import APIRouter, Depends, Query, Request

from server.services.auth_service import require_bearer_token
from server.services import change_log
import sqlite3

router = APIRouter(prefix="/sync", tags=["sync"], dependencies=[Depends(require_bearer_token)])


@router.get("/changes")
def changes(request: Request, after: int = Query(0, ge=0), epoch: str | None = None,
            limit: int = Query(100, ge=1, le=250)):
    with closing(sqlite3.connect(request.app.state.settings.sqlite_path)) as db:
        db.row_factory = sqlite3.Row
        return change_log.changes(db, after, epoch, limit)
