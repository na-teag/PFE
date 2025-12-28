from fastapi import FastAPI
from pydantic import BaseModel
import uuid

app = FastAPI(title="Sandbox Controller")


class RunRequest(BaseModel):
  sample_path: str
  os: str = "windows"
  timeout: int = 120


@app.post("/sandbox/run")
def run(req: RunRequest):
  sandbox_job_id = str(uuid.uuid4())
  # Ici, tu ajoutes la logique pour lancer la VM (KVM/VirtualBox)
  # et stocker temporairement l'état du job (en mémoire, fichier, Redis…)
  return {"sandbox_job_id": sandbox_job_id, "status": "running"}


@app.get("/sandbox/result/{sandbox_job_id}")
def result(sandbox_job_id: str):
  # À remplacer par la vraie collecte de résultats
  return {
    "sandbox_job_id": sandbox_job_id,
    "status": "completed",
    "process_tree": [],
    "file_system_changes": [],
    "network_iocs": [],
  }
