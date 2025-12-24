import os, json, time
from dotenv import load_dotenv
from pathlib import Path
from redis import Redis
import requests
import yara

load_dotenv()
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
VT_KEY = os.getenv("VIRUSTOTAL_API_KEY", "")
RESULTS_PATH = Path(os.getenv("RESULTS_PATH", "/data/results"))
PROJECT_ROOT = Path(__file__).resolve().parent.parent
YARA_DIR_PATH = Path(str(PROJECT_ROOT) + os.getenv("YARA_DIR_PATH", "/yara-rules"))

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)


def vt_analyze(file_hash: str) -> dict:
  headers = {
    "accept": "application/json",
    "x-apikey": VT_KEY
  }
  url = f"https://www.virustotal.com/api/v3/files/{file_hash}"
  r = requests.get(url, headers=headers)
  if r.status_code == 200:
    return r.json()
  elif r.status_code == 404 and "NotFoundError" in r.json().get("error", {}).get("code", ""):
    return {"message": "unknown file"}
  raise ConnectionRefusedError(f"VirusTotal error {r.status_code}")


def load_rules(rules_dir: Path, index_name: str = "index.yar") -> yara.Rules:
  index_path = rules_dir / index_name
  if not index_path.exists():
    raise FileNotFoundError(f"Index YARA introuvable : {index_path}")
  return yara.compile(filepath=str(index_path))

def scan_file(rules: yara.Rules, file_path: Path):
  if not file_path.is_file():
    raise FileNotFoundError(file_path)
  return rules.match(filepath=str(file_path))


def main():
    print("Worker static démarré")
    while True:
        job = redis_client.brpop("analysis_queue_static", timeout=5)
        if not job:
            continue

        _, payload = job
        meta = json.loads(payload)
        job_id = meta["job_id"]

        print(f"[+] Job reçu: {job_id}")

        try:
            rules = load_rules(YARA_DIR_PATH, "index.yar")
            matches = scan_file(rules, Path(meta["file_path"]))
        except Exception as e:
            print(f"[!] Erreur YARA: {e}")
            matches = []

        try:
            VT_result = vt_analyze(meta["file_hash"])
        except ConnectionRefusedError as e:
            print(f"[!] Connection refused: {e}")
            VT_result = {}


        res = {
            "job_id": job_id,
            "file_hash": meta["file_hash"],
            "virustotal": VT_result,
            "yara_matches": matches,
        }

        redis_client.set(f"result_static:{job_id}", json.dumps(res), ex=604800)
        meta["status_static"] = "completed"
        redis_client.set(f"job:{job_id}", json.dumps(meta), ex=604800)


if __name__ == "__main__":
  main()
