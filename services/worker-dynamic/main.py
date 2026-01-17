import os, json, time
from pathlib import Path
from redis import Redis
import requests

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
SANDBOX_URL = os.getenv("SANDBOX_URL", "http://sandbox-controller:9000")

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)



def call_sandbox(job_id: str, path: Path, sandbox_os: str) -> dict:
  print("Calling sandbox:", SANDBOX_URL, "for job", job_id, "path", path)
  print("Dynamic worker payload to sandbox:", {
    "job_id": job_id,
    "sample_path": str(path),
    "os": sandbox_os,
    "timeout": 120,
})

  r = requests.post(f"{SANDBOX_URL}/sandbox/run", json={
    "job_id": job_id,
    "sample_path": str(path),
    "os": sandbox_os,
    "timeout": 120,
  })
  r.raise_for_status()
  sjob = r.json()["sandbox_job_id"]
  while True:
    r2 = requests.get(f"{SANDBOX_URL}/sandbox/result/{sjob}")
    r2.raise_for_status()
    data = r2.json()
    if data["status"] == "completed":
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
    if sandbox_os in ("w10", "w11"):
      sandbox_os = "windows"
    path = Path(meta["file_path"])
    os_name = meta.get("os", "windows")  # default to windows if not set

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
