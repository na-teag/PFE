import os, sys, traceback
import tempfile
import uuid

from pathlib import Path, PurePath
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from typing import Dict, Optional, List
from datetime import datetime
import shutil
import subprocess

from analysis.build_report import build_report



app = FastAPI(title="Sandbox Controller", version="1.0.0")

SANDBOX_JOBS: Dict[str, dict] = {}
API_URL = "http://192.168.122.2:8000"

SSH_KEY_PATH = str(Path.home() / ".ssh/kvm/id_rsa")
VM_NAME = "sandbox-ebpf"
VM_USER = "analyst"

BASE_DIR = Path(__file__).parent
ANALYSIS_DIR = BASE_DIR / "analysis"
LOG_DIR = ANALYSIS_DIR / "log"
LOG_DIR.mkdir(parents=True, exist_ok=True)

ANALYSIS_SCRIPT = ANALYSIS_DIR / "run_analysis.sh"


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



def submit_to_ebpf(sample_path: Path, sandbox_job_id: str, timeout: int) -> str:
    stderr_log = LOG_DIR / f"{sandbox_job_id}.err.log"
    stdout_log = LOG_DIR / f"{sandbox_job_id}.out.log"
    try:
        env = os.environ.copy()
        env["SANDBOX_JOB_ID"] = sandbox_job_id
        env["SANDBOX_TIMEOUT"] = str(timeout)

        subprocess.Popen(
            [str(ANALYSIS_SCRIPT), str(sample_path)],
            stdout=stdout_log.open("ab"),
            stderr=stderr_log.open("ab"),
            env=env,
            start_new_session=True
        )

    except Exception as e:
        tb = traceback.format_exc()
        msg = f"[WARN] Failed to start analysis script for {sample_path} : {e}\n\n{tb}\n"
        SANDBOX_JOBS[sandbox_job_id]["status"] = "fatal_error"
        with stderr_log.open("ab") as f:
            f.write(msg.encode())
        raise HTTPException(500, f" Failed to start analysis script for {sample_path} : {e}")

    finally:
        # on supprime le sample local : il a déjà été copié par le script
        try:
            if sample_path and sample_path.exists():
                sample_path.unlink()
        except Exception:
            tb = traceback.format_exc()
            msg = f"[WARN] Cleanup failed for {sample_path}\n{tb}\n"
            sys.stderr.write(msg)
            with stderr_log.open("ab") as f:
                f.write(msg.encode())


    return sandbox_job_id






def get_ebpf_result(analysis_id: str) -> dict:
    stderr_log = LOG_DIR / f"{analysis_id}.err.log"
    stdout_log = LOG_DIR / f"{analysis_id}.out.log"
    tmp_path = None
    try:
        env = os.environ.copy()
        env["SANDBOX_JOB_ID"] = analysis_id

        # get ip
        out = subprocess.check_output(
            ["virsh", "domifaddr", VM_NAME],
            text=True
        )
        ip = None
        for line in out.splitlines():
            if "ipv4" in line:
                ip = line.split()[3].split("/")[0]
        if not ip:
            raise RuntimeError("VM IP not found")

        # create tmp file
        tmp = tempfile.NamedTemporaryFile(
            prefix=f"ebpf_{analysis_id}_",
            suffix=".log",
            delete=False
        )
        tmp_path = Path(tmp.name)
        tmp.close()

        # get file via scp
        cmd = [
            "scp",
            "-i", str(SSH_KEY_PATH),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            f"{VM_USER}@{ip}:/tmp/ebpf.log",
            str(tmp_path),
        ]
        subprocess.run(
            cmd,
            check=True,
            stdout=stdout_log.open("ab"),
            stderr=stderr_log.open("ab"),
            text=True,
        )

    except Exception as e:
        tb = traceback.format_exc()
        msg = f"[WARN] Failed to get log result : {e}\n\n{tb}\n"
        SANDBOX_JOBS[analysis_id]["status"] = "fatal_error"
        with stderr_log.open("ab") as f:
            f.write(msg.encode())
        raise HTTPException(500, f"Failed to get log result : {e}")


    report = None
    try:
        report = build_report(tmp_path)
    except Exception as e:
        tb = traceback.format_exc()
        msg = f"[WARN] Failed to build report : {e}\n\n{tb}\n"
        SANDBOX_JOBS[analysis_id]["status"] = "fatal_error"
        with stderr_log.open("ab") as f:
            f.write(msg.encode())
        raise HTTPException(500, f"Failed to build report : {e}")

    return {
        "state": "finished",
        "raw": report
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

    # REGISTER JOB
    SANDBOX_JOBS[sandbox_job_id] = {
        "sandbox_job_id": sandbox_job_id,
        "job_id": job_id,
        "os": os_sandbox,
        "timeout": timeout,
        "status": "pending",
        "started_at": now,
        "finished_at": None,
        "analysis": None,
        "engine": "ebpf",
        "backend_id": sandbox_job_id,
    }

    # LAUNCH ANALYSIS
    submit_to_ebpf(sample_path, sandbox_job_id, timeout)

    SANDBOX_JOBS[sandbox_job_id]["status"] = "running"

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
    
    if job["engine"] == "ebpf":
        try:
            data = get_ebpf_result(job["backend_id"])
            state = data.get("state", "pending")
            status_map = {
                "pending": "queued",
                "running": "running",
                "finished": "completed",
                "fatal_error": "failed"
            }
            status = status_map.get(state, "running")
        except Exception as e:
            raise HTTPException(502, f"Failed to get ebpf result: {e}")
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