import os, json, time, hashlib
from pathlib import Path
from redis import Redis
import requests

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
VT_KEY = os.getenv("VIRUSTOTAL_API_KEY", "")
RESULTS_PATH = Path(os.getenv("RESULTS_PATH", "/data/results"))
YARA_RULES_PATH = Path(os.getenv("YARA_RULES_PATH", "/yara-rules"))

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)


def vt_analyze(path: Path) -> dict:
  # simplifié: Hash lookup
  h = hashlib.sha256(path.read_bytes()).hexdigest()
  headers = {"x-apikey": VT_KEY}
  url = f"https://www.virustotal.com/api/v3/files/{h}"
  r = requests.get(url, headers=headers)
  if r.status_code == 200:
    return r.json()
  return {"error": f"VT status {r.status_code}"}


def main():
  while True:
    job = redis_client.brpop("analysis_queue_static", timeout=5)
    if not job:
      continue
    _, payload = job
    meta = json.loads(payload)
    job_id = meta["job_id"]
    path = Path(meta["file_path"])

    res = {
      "job_id": job_id,
      "file_hash": meta["file_hash"],
      "virustotal": vt_analyze(path),
      "yara_matches": [],
    }

    redis_client.set(f"result_static:{job_id}", json.dumps(res), ex=7 * 24 * 3600)
    meta["status_static"] = "completed"
    redis_client.set(f"job:{job_id}", json.dumps(meta), ex=7 * 24 * 3600)

    time.sleep(1)


if __name__ == "__main__":
  main()
