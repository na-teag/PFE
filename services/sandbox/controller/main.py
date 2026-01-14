import os
import json
import requests
from pathlib import Path
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Dict, Optional, List
from datetime import datetime
import uuid

app = FastAPI(title="Sandbox Controller", version="1.0.0")

# --- Cuckoo3 configuration ---

CUCKOO_SUBMIT_URL = os.getenv("CUCKOO_SUBMIT_URL", "http://192.168.122.1:8080")
CUCKOO_API_TOKEN = os.getenv("CUCKOO_API_KEY", "").strip()
CUCKOO_HEADERS = {"Authorization": f"token {CUCKOO_API_TOKEN}"} if CUCKOO_API_TOKEN else {}

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

def submit_to_cuckoo(sample_path: Path) -> str:
    """Submit a file to Cuckoo3 and return the analysis id."""
    try:
        with open(sample_path, "rb") as f:
            files = {"file": (sample_path.name, f)}
            data = {
                "settings": json.dumps({
                    "platforms": [{"platform": "windows", "os_version": "10"}],
                    "timeout": 120,
                })
            }
            r = requests.post(
                f"{CUCKOO_SUBMIT_URL}/submit/file",
                files=files,
                data=data,
                headers=CUCKOO_HEADERS,
                timeout=10,
            )
        r.raise_for_status()
    except Exception as e:
        import traceback
        print("Error in submit_to_cuckoo:", repr(e))
        traceback.print_exc()
        # propagate as 502 so client sees there is a Cuckoo problem
        raise HTTPException(status_code=502, detail=f"Cuckoo error: {e}")

    resp = r.json()
    analysis_id = resp.get("analysis_id") or resp.get("id")
    if not analysis_id:
        raise HTTPException(status_code=502, detail=f"No analysis id in Cuckoo response: {resp}")
    return analysis_id





def get_cuckoo_result(analysis_id: str) -> dict:
    """Fetch analysis details from Cuckoo3."""
    try:
        r = requests.get(
            f"{CUCKOO_SUBMIT_URL}/analysis/{analysis_id}",
            headers=CUCKOO_HEADERS,
            timeout=10,
        )
        r.raise_for_status()
    except Exception as e:
        import traceback
        print("Error in get_cuckoo_result:", repr(e))
        traceback.print_exc()
        raise HTTPException(status_code=502, detail=f"Cuckoo result error: {e}")

    data = r.json()
    state = data.get("state", "pending")

    return {
        "state": state,
        "raw": data,
    }




@app.post("/sandbox/run", response_model=RunResponse)
def run(req: RunRequest):
    print("sandbox/run received:", req.dict())
    sandbox_job_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()

    sample_path = Path(req.sample_path)
    if not sample_path.exists():
        raise HTTPException(400, f"Sample not found: {sample_path}")

    os_lower = req.os.lower()
    if os_lower in ("w10", "w11"):
        os_lower = "windows"
    if os_lower == "windows":
        try:
            cuckoo_id = submit_to_cuckoo(sample_path)
        except Exception as e:
            raise HTTPException(502, f"Cuckoo error: {e}")
        engine = "cuckoo3"
        backend_id = cuckoo_id
    elif os_lower == "linux":
        raise HTTPException(501, "Linux dynamic sandbox not implemented yet")
    else:
        raise HTTPException(400, f"Unsupported os: {req.os}")

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
        "engine": engine,
        "backend_id": backend_id,
    }


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

    """# Pour l'instant c'est un mock : on force un résultat terminé
    # TODO Pour l'instant c'est un mock : on force un résultat terminé

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
    }"""

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