import os, uuid, hashlib, json
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from redis import Redis

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
RESULTS_PATH = Path(os.getenv("RESULTS_PATH", "/data/results"))
MAX_SIZE = 50 * 1024 * 1024

RESULTS_PATH.mkdir(parents=True, exist_ok=True)

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)

app = FastAPI(title="Malware Analysis API", version="1.0.0")


class SubmissionResponse(BaseModel):
  job_id: str
  status: str
  file_hash: str
  submitted_at: str


class ResultResponse(BaseModel):
  job_id: str
  status_static: str
  status_dynamic: str
  static_result: Optional[dict]
  dynamic_result: Optional[dict]


@app.get("/health")
def health():
  try:
    redis_client.ping()
    r_ok = True
  except Exception:
    r_ok = False
  return {"status": "ok" if r_ok else "degraded", "redis": r_ok}


@app.post("/api/submit", response_model=SubmissionResponse)
async def submit(file: UploadFile = File(...)):
  data = await file.read()
  if len(data) > MAX_SIZE:
    raise HTTPException(413, "File too large")
  h = hashlib.sha256(data).hexdigest()
  job_id = str(uuid.uuid4())

  path = RESULTS_PATH / f"{h}_{file.filename}"
  with open(path, "wb") as f:
    f.write(data)

  meta = {
    "job_id": job_id,
    "file_hash": h,
    "file_name": file.filename,
    "file_path": str(path),
    "submitted_at": datetime.utcnow().isoformat(),
    "status_static": "queued",
    "status_dynamic": "queued",
  }
  redis_client.set(f"job:{job_id}", json.dumps(meta), ex=7 * 24 * 3600)
  redis_client.lpush("analysis_queue_static", json.dumps(meta))
  redis_client.lpush("analysis_queue_dynamic", json.dumps(meta))

  return SubmissionResponse(
    job_id=job_id,
    status="queued",
    file_hash=h,
    submitted_at=meta["submitted_at"],
  )


@app.get("/api/result/{job_id}", response_model=ResultResponse)
def result(job_id: str):
  job_raw = redis_client.get(f"job:{job_id}")
  if not job_raw:
    raise HTTPException(404, "job not found")
  meta = json.loads(job_raw)

  static_raw = redis_client.get(f"result_static:{job_id}")
  dyn_raw = redis_client.get(f"result_dynamic:{job_id}")

  return ResultResponse(
    job_id=job_id,
    status_static=meta.get("status_static", "unknown"),
    status_dynamic=meta.get("status_dynamic", "unknown"),
    static_result=json.loads(static_raw) if static_raw else None,
    dynamic_result=json.loads(dyn_raw) if dyn_raw else None,
  )

@app.get("/api/jobs")
def list_jobs():
    jobs = []

    for key in redis_client.scan_iter("job:*"):
        raw = redis_client.get(key)
        if not raw:
            continue

        meta = json.loads(raw)
        jobs.append({
            "job_id": meta.get("job_id"),
            "file_name": meta.get("file_name"),
            "file_hash": meta.get("file_hash"),
            "submitted_at": meta.get("submitted_at"),
            "status_static": meta.get("status_static"),
            "status_dynamic": meta.get("status_dynamic"),
        })

    jobs.sort(key=lambda x: x["submitted_at"], reverse=True)

    return {
        "count": len(jobs),
        "jobs": jobs
    }

