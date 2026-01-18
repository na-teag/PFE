import os
import json
import requests
from pathlib import Path, PurePath
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from typing import Dict, Optional, List
from datetime import datetime
import uuid
import shutil

app = FastAPI(title="Sandbox Controller", version="1.0.0")

SANDBOX_JOBS: Dict[str, dict] = {}
API_URL = "http://192.168.122.2:8000"

# TODO réécrire le fichier pour le faire tourner sur l'hôte avec la sandbox linux

class RunRequest(BaseModel):
    job_id: str                     # job global (API principale)
    sample_data: str
    os: str = "linux"               # windows ou linux
    timeout: int = 120              # seconds


class RunResponse(BaseModel):
    sandbox_job_id: str
    job_id: str
    status: str
    started_at: str


class StatusResponse(BaseModel):
    sandbox_job_id: str
    job_id: str
    status: str                     # queued | running | completed | failed
    started_at: str
    finished_at: Optional[str] = None


class SandboxAnalysis(BaseModel):
    process_tree: List[dict]
    file_system_changes: List[dict]
    network_iocs: List[dict]
    registry_changes: List[dict]
    summary: dict


class ResultResponse(BaseModel):
    sandbox_job_id: str
    job_id: str
    status: str
    analysis: SandboxAnalysis



def submit_to_cuckoo(sample_path: Path, sandbox_job_id: str) -> str:
    """Submit a file to Cuckoo3 and return the analysis id."""
    try:
        pass
        # TODO scp and start
    except Exception as e:
        import traceback
        print("Error in submit_to_cuckoo:", repr(e))
        traceback.print_exc()
        # propagate as 502 so client sees there is a Cuckoo problem
        raise HTTPException(status_code=502, detail=f"Cuckoo error: {e}")

    return sandbox_job_id





def get_cuckoo_result(analysis_id: str) -> dict:
    """Fetch analysis details from Cuckoo3."""
    try:
        data = {}
    except Exception as e:
        import traceback
        print("Error in get_cuckoo_result:", repr(e))
        traceback.print_exc()
        raise HTTPException(status_code=502, detail=f"Cuckoo result error: {e}")

    state = data.get("state", "pending")

    return {
        "state": state,
        "raw": data,
    }




@app.post("/sandbox/run", response_model=RunResponse)
def run(
        job_id: str = Form(...),
        os_sandbox: str = Form(...),
        timeout: int = Form(120),
        sample: UploadFile | None = File(None)
):
    sandbox_job_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    sample_path: Path | None = None

    if os_sandbox == "linux":
        if not sample:
            raise HTTPException(400, f"sample file required")
        tmp_dir = Path("/tmp/sandbox")
        tmp_dir.mkdir(exist_ok=True)
        filename = PurePath(sample.filename).name
        tmp_file = tmp_dir / filename
        with tmp_file.open("wb") as f:
            shutil.copyfileobj(sample.file, f)
        # IMPORTANT : no exec on host
        tmp_file.chmod(0o600)
        sample_path = tmp_file
        # TODO penser à supprimer le fichier après le scp

        # TODO terminer d'adapter la fonction
        try:
            cuckoo_id = submit_to_cuckoo(sample_path, sandbox_job_id)
        except Exception as e:
            raise HTTPException(502, f"Cuckoo error: {e}")
        engine = "cuckoo3"
        backend_id = cuckoo_id
    elif os_sandbox == "windows":
        raise HTTPException(501, "Wrong controller for Windows sandbox")
    else:
        raise HTTPException(400, f"Unsupported os: {os_sandbox}")

    SANDBOX_JOBS[sandbox_job_id] = {
        "sandbox_job_id": sandbox_job_id,
        "job_id": job_id,
        "sample_path": sample_path,
        "os": os_sandbox,
        "timeout": timeout,
        "status": "running",
        "started_at": now,
        "finished_at": None,
        "analysis": None,
        "engine": engine,
        "backend_id": backend_id,
    }


    return RunResponse(
        sandbox_job_id=sandbox_job_id,
        job_id=job_id,
        status="running",
        started_at=now,
    )


@app.get("/sandbox/status/{sandbox_job_id}", response_model=StatusResponse)
def status(sandbox_job_id: str):
    job = SANDBOX_JOBS.get(sandbox_job_id)
    if not job:
        raise HTTPException(404, "sandbox job not found")

    return StatusResponse(
        sandbox_job_id=job["sandbox_job_id"],
        job_id=job["job_id"],
        status=job["status"],
        started_at=job["started_at"],
        finished_at=job["finished_at"],
    )


@app.get("/sandbox/result/{sandbox_job_id}", response_model=ResultResponse)
def result(sandbox_job_id: str):
    job = SANDBOX_JOBS.get(sandbox_job_id)
    if not job:
        raise HTTPException(404, "sandbox job not found")
    
    if job["engine"] == "cuckoo3":
        try:
            data = get_cuckoo_result(job["backend_id"])
            state = data.get("state", "pending")
            status_map = {
                "pending": "queued",
                "running": "running",
                "finished": "completed",
                "fatal_error": "failed"
            }
            status = status_map.get(state, "running")
        except Exception as e:
            raise HTTPException(502, f"Failed to get Cuckoo result: {e}")
    else:
        raise HTTPException(500, f"Unknown engine: {job['engine']}")


    job["status"] = status
    if status == "completed" and not job["finished_at"]:
        job["finished_at"] = datetime.utcnow().isoformat()

    analysis = SandboxAnalysis(
        process_tree=[],
        file_system_changes=[],
        network_iocs=[],
        registry_changes=[],
        summary={"engine": job["engine"], "state": state, "raw": data["raw"]},

    )
    job["analysis"] = analysis

    return ResultResponse(
        sandbox_job_id=job["sandbox_job_id"],
        job_id=job["job_id"],
        status=job["status"],
        analysis=job["analysis"],
    )


@app.get("/health")
def health():
    return {
        "service": "sandbox-controller",
        "status": "ok",
        "sandbox_jobs": len(SANDBOX_JOBS)
    }