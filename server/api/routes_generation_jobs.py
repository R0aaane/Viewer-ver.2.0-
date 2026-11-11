from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field

from server.services.auth_service import require_bearer_token, authentication_configured
from server.services.generation_jobs import JobConflict

router = APIRouter(prefix="/generated", tags=["generation jobs"])


def jobs_for(request: Request, _=Depends(require_bearer_token)):
    jobs = getattr(request.app.state, "generation_jobs", None)
    if not authentication_configured(request.app.state) or jobs is None:
        raise HTTPException(503, "ホスト側でComfyUIの接続先とプリセットを設定してください")
    return jobs


class GenerationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    preset: str = Field(min_length=1, max_length=128)
    parameters: dict[str, Any] = Field(default_factory=dict, max_length=64)


@router.get("/presets")
def presets(jobs=Depends(jobs_for)):
    return {"items": jobs.presets.public()}


@router.post("/jobs")
def submit(body: GenerationRequest,
           idempotency_key: Annotated[str, Header(min_length=16, max_length=128)],
           jobs=Depends(jobs_for)):
    try:
        return jobs.create(idempotency_key, body.preset, body.parameters)
    except JobConflict as exc:
        raise HTTPException(409, str(exc)) from exc
    except (ValueError, TypeError) as exc:
        raise HTTPException(422, str(exc)) from exc


@router.get("/jobs")
def list_jobs(before: float | None = Query(None, gt=0), jobs=Depends(jobs_for)):
    return {"items": jobs.list(before)}


@router.get("/jobs/{job_id}")
def get_job(job_id: str, jobs=Depends(jobs_for)):
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Job not found")
    return job


@router.post("/jobs/{job_id}/cancel")
def cancel_job(job_id: str, jobs=Depends(jobs_for)):
    try:
        job = jobs.cancel(job_id)
    except JobConflict as exc:
        raise HTTPException(409, str(exc)) from exc
    if job is None:
        raise HTTPException(404, "Job not found")
    return job
