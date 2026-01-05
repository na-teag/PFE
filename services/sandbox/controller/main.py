from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Dict, Optional, List
from datetime import datetime
import uuid

app = FastAPI(title="Sandbox Controller", version="1.0.0")

class RunRequest(BaseModel):
    job_id: str                     # job global (API principale)
    sample_path: str                # ex: /shared/jobs/<job_id>/sample.exe
    os: str = "windows"             # windows ou linux
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


SANDBOX_JOBS: Dict[str, dict] = {}

@app.post("/sandbox/run", response_model=RunResponse)
def run(req: RunRequest):
    sandbox_job_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()

    SANDBOX_JOBS[sandbox_job_id] = {
        "sandbox_job_id": sandbox_job_id,
        "job_id": req.job_id,
        "sample_path": req.sample_path,
        "os": req.os,
        "timeout": req.timeout,
        "status": "running",
        "started_at": now,
        "finished_at": None,
        "analysis": None,
    }

    # TODO:
    # - lancement VM (KVM)
    # - injection sample
    # - lancement Drakvuf / Cuckoo

    return RunResponse(
        sandbox_job_id=sandbox_job_id,
        job_id=req.job_id,
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

    # Pour l'instant c'est un mock : on force un résultat terminé
    if job["status"] != "completed":
        job["status"] = "completed"
        job["finished_at"] = datetime.utcnow().isoformat()
        job["analysis"] = {
        "process_tree": [
            {
                "pid": 3120,
                "ppid": 1024,
                "name": "sample.exe",
                "cmdline": "C:\\Users\\User\\Downloads\\sample.exe"
            },
            {
                "pid": 4188,
                "ppid": 3120,
                "name": "cmd.exe",
                "cmdline": "cmd.exe /c whoami"
            },
            {
                "pid": 4250,
                "ppid": 3120,
                "name": "powershell.exe",
                "cmdline": "powershell -enc SQBFAFgA..."
            }
        ],

        "file_system_changes": [
            {
                "path": "C:\\Users\\User\\AppData\\Roaming\\evil.dll",
                "operation": "created"
            },
            {
                "path": "C:\\Users\\User\\AppData\\Roaming\\config.json",
                "operation": "modified"
            }
        ],

        "network_iocs": [
            {
                "type": "ip",
                "value": "192.168.56.101",
                "port": 4444,
                "protocol": "tcp"
            },
            {
                "type": "ip",
                "value": "8.8.8.8",
                "port": 53,
                "protocol": "udp"
            },
            {
                "type": "domain",
                "value": "malicious-example.com"
            },
            {
                "type": "url",
                "value": "http://malicious-example.com/c2/checkin"
            },
            {
                "type": "user-agent",
                "value": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            }
        ],

        "registry_changes": [
            {
                "key": "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\\evil",
                "operation": "set"
            }
        ],

        "summary": {
            "malicious": True,
            "score": 85,
            "engine": "mock-sandbox"
        }
    }

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