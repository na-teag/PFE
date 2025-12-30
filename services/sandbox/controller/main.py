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
        SANDBOX_IMAGE,
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

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
