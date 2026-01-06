from flask import Flask, request, jsonify
import subprocess
import uuid
import os

app = Flask(__name__)

SANDBOX_IMAGE = "output/packer-malware-target.qcow2"
RESULT_DIR = "/tmp/sandbox_results"

os.makedirs(RESULT_DIR, exist_ok=True)

@app.route("/sandbox/run", methods=["POST"])
def run_sandbox():
    data = request.json
    sample_path = data["sample_path"]

    job_id = str(uuid.uuid4())
    result_file = f"{RESULT_DIR}/{job_id}.json"

    subprocess.Popen([
    "./run_analysis.sh",
    sample_path,
    result_file
    ])


    return jsonify({
        "sandbox_job_id": job_id,
        "status": "running"
    })

@app.route("/sandbox/result/<job_id>")
def sandbox_result(job_id):
    result_file = f"{RESULT_DIR}/{job_id}.json"

    if not os.path.exists(result_file):
        return jsonify({"status": "running"})

    with open(result_file) as f:
        return jsonify({
            "status": "completed",
            "result": f.read()
        })

<<<<<<< HEAD

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

def submit_to_cuckoo(sample_path: Path) -> int:
    """Submit a file to Cuckoo3 and return the analysis id."""
    with open(sample_path, "rb") as f:
        files = {"file": (sample_path.name, f)}
        r = requests.post(f"{CUCKOO_API_URL}/analyses/", files=files, headers=CUCKOO_HEADERS)
    r.raise_for_status()
    data = r.json()
    analysis_id = data.get("id")
    if analysis_id is None:
        raise RuntimeError(f"No analysis id in Cuckoo response: {data}")
    return analysis_id


def get_cuckoo_result(analysis_id: int) -> dict:
    """Fetch analysis details from Cuckoo3."""
    r = requests.get(f"{CUCKOO_API_URL}/analyses/{analysis_id}/", headers=CUCKOO_HEADERS)
    r.raise_for_status()
    return r.json()


@app.post("/sandbox/run", response_model=RunResponse)
def run(req: RunRequest):
    sandbox_job_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()

    sample_path = Path(req.sample_path)
    if not sample_path.exists():
        raise HTTPException(400, f"Sample not found: {sample_path}")

    os_lower = req.os.lower()
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
        data = get_cuckoo_result(job["backend_id"])
        status = data.get("status", "running")  # adapte cette clé après avoir vu le JSON Cuckoo
    else:
        raise HTTPException(500, f"Unknown engine: {job['engine']}")

<<<<<<< HEAD
<<<<<<< HEAD
    # TODO Pour l'instant c'est un mock : on force un résultat terminé
=======
=======

>>>>>>> 7b6e722 (chore: gitignore and env)
    job["status"] = status
    if status == "completed" and not job["finished_at"]:
        job["finished_at"] = datetime.utcnow().isoformat()

    analysis = SandboxAnalysis(
        process_tree=[],
        file_system_changes=[],
        network_iocs=[],
        registry_changes=[],
        summary={"engine": job["engine"], "raw": data},
    )
    job["analysis"] = analysis

    """# Pour l'instant c'est un mock : on force un résultat terminé
<<<<<<< HEAD
>>>>>>> 3f4530e (feat: Cuckoo3 endpoints)
=======
    # TODO Pour l'instant c'est un mock : on force un résultat terminé

>>>>>>> 7b6e722 (chore: gitignore and env)
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
=======
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
>>>>>>> f0c2dcf (feat: add dragvuf test)
