"""Authenticated, manually requested Image to Prompt endpoints."""
from typing import Literal
from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, Query
from pydantic import BaseModel, Field
from PIL import Image
from server.services.auth_service import require_bearer_token
from server.services.image_prompt_service import CATEGORIES, document_key, prompt_for

router = APIRouter(prefix='/image-prompt', tags=['image prompt'], dependencies=[Depends(require_bearer_token)])
Category = Literal['appearance', 'clothing', 'expression', 'pose', 'composition', 'background', 'style', 'character', 'other', 'rating']


def service_for(request: Request):
    service = getattr(request.app.state, 'image_prompt', None)
    if service is None: raise HTTPException(503, '画像解析サービスが起動していません')
    return service


class Tag(BaseModel):
    text: str = Field(min_length=1, max_length=160)
    category: Category
    enabled: bool = True
    sources: list[Literal['qwen3-vl', 'wd14', 'manual']] = Field(default_factory=lambda: ['manual'], max_length=3)
    confidence: float | None = Field(default=None, ge=0, le=1)


class Edit(BaseModel):
    source: str = Field(min_length=1, max_length=2048)
    page: int = Field(ge=1, le=100000)
    expectedVersion: int = Field(ge=0)
    tags: list[Tag] = Field(max_length=300)
    disabledCategories: list[Category] = Field(default_factory=list, max_length=len(CATEGORIES))
    jobId: str = Field(min_length=1, max_length=128)


@router.get('/configuration')
def configuration(service=Depends(service_for)):
    return service.configuration()


@router.post('/jobs', status_code=202)
async def analyze(source: str = Form(..., min_length=1, max_length=2048), page: int = Form(..., ge=1, le=100000),
                  image: UploadFile = File(...), service=Depends(service_for)):
    try:
        payload = await image.read(12 * 1024 * 1024 + 1)
        if len(payload) > 12 * 1024 * 1024: raise HTTPException(413, '画像が大きすぎます')
        try: return service.submit(source, page, payload)
        except BlockingIOError as exc: raise HTTPException(429, str(exc)) from exc
        except (ValueError, OSError, Image.DecompressionBombError) as exc: raise HTTPException(422, '解析対象画像を読み取れません') from exc
    finally:
        await image.close()


@router.get('/jobs/{identifier}')
def job(identifier: str, service=Depends(service_for)):
    result = service.get_job(identifier)
    if result is None: raise HTTPException(404, '解析ジョブがありません')
    return result


@router.get('/document')
def document(source: str = Query(..., min_length=1, max_length=2048), page: int = Query(..., ge=1, le=100000), service=Depends(service_for)):
    return service.document(document_key(source, page))


@router.put('/document')
def save(edit: Edit, service=Depends(service_for)):
    job = service.get_job(edit.jobId)
    key = document_key(edit.source, edit.page)
    if job is None or job['key'] != key or job['state'] != 'completed':
        raise HTTPException(422, '画像に対応する解析結果がありません')
    data = dict(job['result'])
    data.update(tags=[tag.model_dump() for tag in edit.tags], disabledCategories=edit.disabledCategories, jobId=edit.jobId)
    data['prompt'] = prompt_for(data['tags'], data['disabledCategories'])
    try: version = service.save(key, edit.expectedVersion, data)
    except ValueError as exc: raise HTTPException(409, str(exc)) from exc
    return {'version': version, 'document': data}
