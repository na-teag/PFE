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
import subprocess



app = FastAPI(title="Sandbox Controller", version="1.0.0")

SANDBOX_JOBS: Dict[str, dict] = {}
API_URL = "http://192.168.122.2:8000"
ANALYSIS_SCRIPT = Path("/analysis/run_analysis.sh")
ANALYSIS_LOG_DIR = Path("/analysis/logs")

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
    try:
        env = os.environ.copy()
        env["SANDBOX_JOB_ID"] = sandbox_job_id

        subprocess.Popen(
    [str(ANALYSIS_SCRIPT), str(sample_path)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    env=env,
    )

    except Exception as e:
        raise HTTPException(502, f"Failed to start analysis script: {e}")

    return sandbox_job_id





def get_cuckoo_result(analysis_id: str) -> dict:
    job_dir = ANALYSIS_LOG_DIR / analysis_id

    if not job_dir.exists():
        return {"state": "pending", "raw": {}}

    report = job_dir / "report.json"
    error = job_dir / "error.log"

    if error.exists():
        return {
            "state": "fatal_error",
            "raw": {"error": error.read_text()}
        }

    if not report.exists():
        return {"state": "running", "raw": {}}

    return {
        "state": "finished",
        "raw": json.loads(report.read_text())
    }




@app.post("/sandbox/run", response_model=RunResponse)
def run(
    job_id: str = Form(...),
    os_sandbox: str = Form(...),
    timeout: int = Form(120),
    sample: UploadFile | None = File(None),
):
    sandbox_job_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    sample_path: Path | None = None

    # CHECK OS
    if os_sandbox != "linux":
        raise HTTPException(400, f"Unsupported os: {os_sandbox}")

    if not sample:
        raise HTTPException(400, "sample file required")

    # STORE SAMPLE (TEMP)
    try:
        tmp_dir = Path("/tmp/sandbox")
        tmp_dir.mkdir(parents=True, exist_ok=True)

        filename = PurePath(sample.filename).name
        sample_path = tmp_dir / f"{sandbox_job_id}_{filename}"

        with sample_path.open("wb") as f:
            shutil.copyfileobj(sample.file, f)

        # Jamais exécutable sur l’hôte
        sample_path.chmod(0o600)

    except Exception as e:
        raise HTTPException(500, f"Failed to store sample: {e}")

    # LAUNCH ANALYSIS
    try:
        env = os.environ.copy()
        env["SANDBOX_JOB_ID"] = sandbox_job_id
        env["SANDBOX_TIMEOUT"] = str(timeout)

        subprocess.Popen(
            [
                str(ANALYSIS_SCRIPT),
                str(sample_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,  # évite de tuer le job si l’API restart
        )

    except Exception as e:
        raise HTTPException(502, f"Failed to start analysis script: {e}")

    finally:
        # on supprime le sample local : il a déjà été copié par le script
        try:
            if sample_path and sample_path.exists():
                sample_path.unlink()
        except Exception:
            pass

    # REGISTER JOB
    SANDBOX_JOBS[sandbox_job_id] = {
        "sandbox_job_id": sandbox_job_id,
        "job_id": job_id,
        "os": os_sandbox,
        "timeout": timeout,
        "status": "running",
        "started_at": now,
        "finished_at": None,
        "analysis": None,
        "engine": "linux-ebpf",
        "backend_id": sandbox_job_id,
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