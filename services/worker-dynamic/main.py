import os, json, time
from pathlib import Path

from fastapi import HTTPException
from redis import Redis
import requests

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
SANDBOX_CUCKOO_URL = os.getenv("SANDBOX_URL", "http://sandbox-controller:9000")
SANDBOX_PACKER_URL = "http://192.168.122.1:7070"

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)


def call_sandbox(job_id: str, path: Path, sandbox_os: str) -> dict:
    sandbox_url = ""
    r = None
    match sandbox_os:
        case "linux":
            sandbox_url = SANDBOX_PACKER_URL
            try:
                with open(path, "rb") as f:
                    r = requests.post(
                        f"{sandbox_url}/sandbox/run",
                        files={"sample": (path.name, f)},
                        data={
                            "job_id": job_id,
                            "os_sandbox": sandbox_os,
                            "timeout": 120,
                        },
                        timeout=30,
                    )
            except  Exception as e:
                import traceback
                print("Error in submit_to_cuckoo:", repr(e))
                traceback.print_exc()
                # propagate as 502 so client sees there is a sandbox problem
                raise HTTPException(status_code=502, detail=f"Cuckoo error: {e}")
        case "windows":
            sandbox_url = SANDBOX_CUCKOO_URL
            print("Calling sandbox:", sandbox_url, "for job", job_id, "path", path)
            print("Dynamic worker payload to sandbox:", {
                "job_id": job_id,
                "sample_path": str(path),
                "os": sandbox_os,
                "timeout": 120,
            })
            r = requests.post(f"{sandbox_url}/sandbox/run", json={
                "job_id": job_id,
                "sample_path": str(path),
                "os": sandbox_os,
                "timeout": 120,
            })

    r.raise_for_status()
    sjob = r.json()["sandbox_job_id"]
    start = time.monotonic()
    while True:
        r2 = requests.get(f"{sandbox_url}/sandbox/result/{sjob}", timeout=10)
        r2.raise_for_status()
        data = r2.json()
        if data["status"] == "completed":
            return data
        if time.monotonic() - start > 15 * 60:
            data["status"] = "timeout"
            return data
        time.sleep(5)


def main():
    while True:
        job = redis_client.brpop("analysis_queue_dynamic", timeout=5)
        if not job:
            continue
        _, payload = job
        meta = json.loads(payload)
        job_id = meta["job_id"]
        sandbox_os = meta["os"]
        path = Path(meta["file_path"])

        res = call_sandbox(job_id, path, sandbox_os)

        res["job_id"] = job_id

        redis_client.set(f"result_dynamic:{job_id}", json.dumps(res), ex=7 * 24 * 3600)
        # *** Relecture avant écriture ***
        job_raw = redis_client.get(f"job:{job_id}")
        if not job_raw:
            meta = {}
        else:
            meta = json.loads(job_raw)
        meta["status_dynamic"] = "completed"
        redis_client.set(f"job:{job_id}", json.dumps(meta), ex=7 * 24 * 3600)


if __name__ == "__main__":
    main()
