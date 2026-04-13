import os, uuid, hashlib, json
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, UploadFile, File, HTTPException, Form, Response, Header, Cookie, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from redis import Redis
from fastapi.responses import StreamingResponse
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
import io
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.platypus import Table, TableStyle, SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.pdfgen import canvas as pdf_canvas
from reportlab.platypus import KeepTogether
import secrets
from datetime import datetime
from zoneinfo import ZoneInfo


REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
RESULTS_PATH = Path(os.getenv("RESULTS_PATH", "/data/results"))
API_KEY = os.getenv("API_KEY")
MAX_SIZE = 50 * 1024 * 1024

RESULTS_PATH.mkdir(parents=True, exist_ok=True)

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)

app = FastAPI(title="Malware Analysis API", version="1.0.0")
BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"

app.mount("/static", StaticFiles(directory=STATIC_DIR, html=True), name="static")


HEADER_BLUE = colors.HexColor("#2F5597")
SECTION_BLUE = colors.HexColor("#E9EFF7")
TABLE_HEADER_GREY = colors.HexColor("#D9D9D9")
BORDER_GREY = colors.HexColor("#A6A6A6")
TEXT_GREY = colors.HexColor("#404040")

class SubmissionResponse(BaseModel):
  job_id: str
  status: str
  file_hash: str
  submitted_at: str


class ResultResponse(BaseModel):
  job_id: str
  status_static: str
  status_dynamic: str
  static_result: Optional[dict]
  dynamic_result: Optional[dict]

class LoginRequest(BaseModel):
    api_key: str

def create_session() -> str:
    token = secrets.token_urlsafe(32)
    redis_client.setex(f"session:{token}", 3600, "1")
    return token

def verify_session(token: str) -> bool:
    return redis_client.exists(f"session:{token}") == 1

def delete_session(token: str):
    redis_client.delete(f"session:{token}")

def format_ts(ts: str) -> str:
    return datetime.fromisoformat(ts).strftime("%Y-%m-%d %H:%M:%S")

def verify_api_key(api_key: str):
    if not API_KEY:
        raise HTTPException(status_code=500, detail="API key not configured")

    if api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")

def verify_auth(
    x_api_key: Optional[str] = Header(None),
    session: Optional[str] = Cookie(None)
):
    if not API_KEY:
        raise HTTPException(500, "API key not configured")
    if x_api_key == API_KEY:
        return True
    if session and verify_session(session):
        return True
    raise HTTPException(401, "Unauthorized")

@app.get("/health")
def health():
  try:
    redis_client.ping()
    r_ok = True
  except Exception:
    r_ok = False
  return {"status": "ok" if r_ok else "degraded", "redis": r_ok}

@app.post("/api/login")
def login(data: LoginRequest, response: Response, request: Request):
    ip = request.client.host
    key = f"login_attempts:{ip}"
    attempts = redis_client.incr(key)
    if attempts == 1:
        redis_client.expire(key, 300)  # fenêtre de 5 minutes
    if attempts > 10:
        raise HTTPException(429, "Trop de tentatives, réessayez dans 5 minutes")
    verify_api_key(data.api_key)
    redis_client.delete(key)  # reset si succès
    token = create_session()
    response.set_cookie(key="session", value=token, httponly=True,
                        secure=True, samesite="Lax", max_age=3600, path="/")
    return {"status": "authenticated"}

@app.post("/api/logout")
def logout(response: Response, session: Optional[str] = Cookie(None),
           auth: bool = Depends(verify_auth)):
    if session:
        delete_session(session)
    response.delete_cookie(key="session", path="/")
    return {"status": "logged out"}

@app.post("/api/submit", response_model=SubmissionResponse)
async def submit(file: UploadFile = File(...), sandbox_os: str = Form(...), auth: bool = Depends(verify_auth)):
  data = await file.read()
  if len(data) > MAX_SIZE:
    raise HTTPException(413, "File too large")
  valid = {"windows", "linux"}
  if sandbox_os not in valid:
    raise HTTPException(400, f"Invalid os value: {sandbox_os}, should be in {valid}")
  h = hashlib.sha256(data).hexdigest()
  job_id = str(uuid.uuid4())

  path = RESULTS_PATH / f"{h}_{file.filename}"
  with open(path, "wb") as f:
    f.write(data)

  meta = {
    "job_id": job_id,
    "file_hash": h,
    "file_name": file.filename,
    "file_path": str(path),
    "os": sandbox_os,
    "submitted_at": format_ts(datetime.now(ZoneInfo("Europe/Paris")).isoformat()),
    "status_static": "queued",
    "status_dynamic": "queued",
  }
  redis_client.set(f"job:{job_id}", json.dumps(meta), ex=7 * 24 * 3600)
  redis_client.lpush("analysis_queue_static", json.dumps(meta))
  redis_client.lpush("analysis_queue_dynamic", json.dumps(meta))

  return SubmissionResponse(
    job_id=job_id,
    status="queued",
    file_hash=h,
    submitted_at=meta["submitted_at"],
  )


@app.get("/api/result/{job_id}", response_model=ResultResponse)
def result(job_id: str, auth: bool = Depends(verify_auth)):
  job_raw = redis_client.get(f"job:{job_id}")
  if not job_raw:
    raise HTTPException(404, "job not found")
  meta = json.loads(job_raw)

  static_raw = redis_client.get(f"result_static:{job_id}")
  dyn_raw = redis_client.get(f"result_dynamic:{job_id}")

  return ResultResponse(
    job_id=job_id,
    status_static=meta.get("status_static", "unknown"),
    status_dynamic=meta.get("status_dynamic", "unknown"),
    static_result=json.loads(static_raw) if static_raw else None,
    dynamic_result=json.loads(dyn_raw) if dyn_raw else None,
  )

@app.get("/api/jobs")
def list_jobs(auth: bool = Depends(verify_auth)):
    jobs = []

    for key in redis_client.scan_iter("job:*"):
        raw = redis_client.get(key)
        if not raw:
            continue

        meta = json.loads(raw)
        jobs.append({
            "job_id": meta.get("job_id"),
            "file_name": meta.get("file_name"),
            "file_hash": meta.get("file_hash"),
            "submitted_at": meta.get("submitted_at"),
            "status_static": meta.get("status_static"),
            "status_dynamic": meta.get("status_dynamic"),
        })

    jobs.sort(key=lambda x: x["submitted_at"], reverse=True)

    return {
        "count": len(jobs),
        "jobs": jobs
    }

@app.delete("/api/jobs/{job_id}")
def delete_job(job_id: str, auth: bool = Depends(verify_auth)):
    job_key = f"job:{job_id}"

    job_raw = redis_client.get(job_key)
    if not job_raw:
        raise HTTPException(404, "job not found")

    meta = json.loads(job_raw)

    file_path = meta.get("file_path")
    if file_path:
        try:
            path = Path(file_path)
            if path.exists():
                path.unlink()
        except Exception as e:
            raise HTTPException(500, f"failed to delete file: {e}")

    redis_client.delete(
        job_key,
        f"result_static:{job_id}",
        f"result_dynamic:{job_id}",
    )

    return {"status": "deleted", "job_id": job_id}

@app.get("/api/result/{job_id}/download")
def download_result(job_id: str, auth: bool = Depends(verify_auth)):
    job_raw = redis_client.get(f"job:{job_id}")
    if not job_raw:
        raise HTTPException(status_code=404, detail="job not found")

    meta = json.loads(job_raw)

    static_raw = redis_client.get(f"result_static:{job_id}")
    dynamic_raw = redis_client.get(f"result_dynamic:{job_id}")

    result = {
        "job_id": job_id,
        "status_static": meta.get("status_static", "unknown"),
        "status_dynamic": meta.get("status_dynamic", "unknown"),
        "static_result": json.loads(static_raw) if static_raw else None,
        "dynamic_result": json.loads(dynamic_raw) if dynamic_raw else None,
    }

    json_bytes = json.dumps(result, indent=2).encode("utf-8")

    filename = f"analysis_{job_id}.json"

    return StreamingResponse(
        io.BytesIO(json_bytes),
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"'
        }
    )


def build_unified_report(job_id: str, meta: dict, static_raw: str | None, dynamic_raw: str | None):
    static = json.loads(static_raw) if static_raw else {}
    dynamic = json.loads(dynamic_raw) if dynamic_raw else {}

    # STATIC: VirusTotal parsing
    vt = static.get("virustotal", {})
    vt_stats = vt.get("data", {}).get("attributes", {}).get("last_analysis_stats", {})

    malicious_count = vt_stats.get("malicious", 0)
    total_engines = sum(vt_stats.values()) if vt_stats else 0

    popular_threat_classification = vt.get("data", {}).get("attributes", {}).get("popular_threat_classification", {})
    
    last_analysis_results = vt.get("data", {}).get("attributes", {}).get("last_analysis_results", {})

    filtered_last_analysis_results = {
        engine_name: {
            "engine_name": engine_info.get("engine_name"),
            "result": engine_info.get("result")
        }
        for engine_name, engine_info in last_analysis_results.items()
        if engine_info.get("result") is not None
    }

    engine_type = dynamic.get("analysis", {}).get("summary", {}).get("engine", "unknown")

    # Initialize common variables
    score = 0
    tags = []
    ttps = []
    tasks = []
    all_hashes = {"sha256": meta.get("file_hash")}
    malicious_dynamic = False

    # DYNAMIC: Cuckoo3 parsing
    if engine_type == "cuckoo3" :
        cuckoo_raw = dynamic.get("analysis", {}).get("summary", {}).get("raw", {}) if dynamic else {}
        
        score = cuckoo_raw.get("score", 0)
        tags = cuckoo_raw.get("tags", [])
        ttps = cuckoo_raw.get("ttps", [])
        tasks = cuckoo_raw.get("tasks", [])
        malicious_dynamic = score >= 5
        
        submitted = cuckoo_raw.get("submitted", {})
        target = cuckoo_raw.get("target", {})
        all_hashes = {
            "md5": submitted.get("md5") or target.get("md5"),
            "sha1": submitted.get("sha1") or target.get("sha1"),
            "sha512": submitted.get("sha512") or target.get("sha512"),
        }

    # DYNAMIC : EBPF parsing
    elif engine_type == "ebpf":
        ebpf_raw = dynamic.get("analysis", {}).get("summary", {}).get("raw", {})
        
        summary = ebpf_raw.get("summary", {})
        verdict_ebpf = summary.get("verdict", "unknown")
        score = summary.get("score", 0)
        reasons = summary.get("reasons", [])
        
        files = ebpf_raw.get("files", [])
        executions = ebpf_raw.get("executions", [])
        network_data = ebpf_raw.get("network", {})
        network_urls = network_data.get("urls", [])
        
        tags = reasons if isinstance(reasons, list) else []
        
        malicious_dynamic = score >= 5

    # IOCs (extend with network when available)
    ips = set()
    domains = set()
    urls = set()
    ports = set()
    user_agents = set()

    network_events = dynamic.get("analysis", {}).get("network_iocs", [])
    for event in network_events:
        event_type = event.get("type", "").lower()
        value = event.get("value", "")
    
        if event_type == "ip":
            ips.add(value)
        elif event_type == "domain":
            domains.add(value)
        elif event_type == "url":
            urls.add(value)
        elif event_type == "port":
            ports.add(value)
        elif event_type == "user_agent":
            user_agents.add(value)

    if engine_type == "ebpf" and network_urls:
        urls.update(network_urls)
            
    verdict_malicious = malicious_dynamic or malicious_count > 0

    # Build dynamic analysis section based on engine
    dynamic_section = {
        "engine": engine_type,
        "score": score,
        "tags": tags,
        "processes": dynamic.get("analysis", {}).get("process_tree", []),
        "filesystem": dynamic.get("analysis", {}).get("file_system_changes", []),
        "network": dynamic.get("analysis", {}).get("network_iocs", []),
        "registry": dynamic.get("analysis", {}).get("registry_changes", []),
    }
    
    if engine_type == "cuckoo3":
        cuckoo_raw = dynamic.get("analysis", {}).get("summary", {}).get("raw", {})
        dynamic_section.update({
            "analysis_id": cuckoo_raw.get("id"),
            "state": cuckoo_raw.get("state"),
            "ttps": ttps,
            "tasks": tasks,
        })
    elif engine_type == "ebpf":
        ebpf_raw = dynamic.get("analysis", {}).get("summary", {}).get("raw", {})
        dynamic_section.update({
            "verdict": verdict_ebpf if 'verdict_ebpf' in locals() else "unknown",
            "reasons": reasons if 'reasons' in locals() else [],
            "files": files if 'files' in locals() else [],
            "executions": executions if 'executions' in locals() else [],
        })

    timestamps = {
        "generated_at": format_ts(datetime.now(ZoneInfo("Europe/Paris")).isoformat()),
    }
    
    if engine_type == "cuckoo3":
        cuckoo_raw = dynamic.get("analysis", {}).get("summary", {}).get("raw", {})
        if cuckoo_raw.get("created_on"):
            timestamps["cuckoo_created"] = format_ts(cuckoo_raw.get("created_on"))




    report = {
        "job_id": job_id,
        "file": {
            "name": meta.get("file_name"),
            "sha256": meta.get("file_hash"),
            "submitted_at": format_ts(meta.get("submitted_at")),
            **{k: v for k, v in all_hashes.items() if v and k != "sha256"},
        },
        "verdict": {
            "malicious": verdict_malicious,
            "confidence": round(malicious_count / max(total_engines, 1), 2),
            "score": score,
        },
        "static_analysis": {
            "engine": "VirusTotal",
            "detections": malicious_count,
            "total_engines": total_engines,
            "tags": vt.get("data", {}).get("attributes", {}).get("tags", []),
            "popular_threat_classification": popular_threat_classification,
            "last_analysis_results": filtered_last_analysis_results,
            "yara_matches": static.get("yara_matches", []),
        },
        "dynamic_analysis": dynamic_section,
        "iocs": {
            "ips": sorted(ips),
            "domains": sorted(domains),
            "urls": sorted(urls),
            "ports": sorted(ports),
            "user_agents": sorted(user_agents),
            "hashes": [meta.get("file_hash")] + [v for v in all_hashes.values() if v and v != meta.get("file_hash")],
            "tags": tags,
            "ttps": [t.get("id") for t in ttps] if ttps else [],
        },
        "timestamps": timestamps
    }

    return report

@app.get("/api/report/{job_id}")
def get_report(job_id: str, auth: bool = Depends(verify_auth)):
    job_raw = redis_client.get(f"job:{job_id}")
    if not job_raw:
        raise HTTPException(404, "job not found")

    meta = json.loads(job_raw)
    static_raw = redis_client.get(f"result_static:{job_id}")
    dynamic_raw = redis_client.get(f"result_dynamic:{job_id}")

    report = build_unified_report(job_id, meta, static_raw, dynamic_raw)
    return JSONResponse(report)

@app.get("/api/report/{job_id}/download")
def download_report(job_id: str, auth: bool = Depends(verify_auth)):
    job_raw = redis_client.get(f"job:{job_id}")
    if not job_raw:
        raise HTTPException(404, "job not found")

    meta = json.loads(job_raw)
    static_raw = redis_client.get(f"result_static:{job_id}")
    dynamic_raw = redis_client.get(f"result_dynamic:{job_id}")

    report = build_unified_report(job_id, meta, static_raw, dynamic_raw)

    json_bytes = json.dumps(report, indent=2).encode("utf-8")
    filename = f"report_{job_id}.json"

    return StreamingResponse(
        io.BytesIO(json_bytes),
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"'
        }
    )

def draw_header_footer(c: pdf_canvas.Canvas, doc, report):
    width, height = letter

    # Header bar
    c.setFillColor(HEADER_BLUE)
    c.rect(0, height - 50, width, 50, stroke=0, fill=1)

    c.setFillColor(colors.white)
    c.setFont("Helvetica-Bold", 14)
    c.drawString(40, height - 32, "Malware Analysis Report")

    c.setFont("Helvetica", 9)
    c.drawRightString(
        width - 40, height - 32,
        f"Job ID: {report['job_id']}  |  File: {report['file']['name']}"
    )

    # Footer
    c.setStrokeColor(BORDER_GREY)
    c.line(40, 35, width - 40, 35)

    c.setFont("Helvetica", 9)
    c.setFillColor(TEXT_GREY)
    footer_text = "Page {}".format(c.getPageNumber() if hasattr(c, "getPageNumber") else 1)
    c.drawCentredString(width / 2, 20, footer_text)


@app.get("/api/report/{job_id}/pdf")
def download_report_pdf(job_id: str, auth: bool = Depends(verify_auth)):
    job_raw = redis_client.get(f"job:{job_id}")
    if not job_raw:
        raise HTTPException(404, "job not found")

    meta = json.loads(job_raw)
    static_raw = redis_client.get(f"result_static:{job_id}")
    dynamic_raw = redis_client.get(f"result_dynamic:{job_id}")

    report = build_unified_report(job_id, meta, static_raw, dynamic_raw)

    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        rightMargin=40,
        leftMargin=40,
        topMargin=80,
        bottomMargin=60
    )

    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(
        name="FileInfo",
        fontSize=11,
        fontName="Helvetica-Bold",
        leading=16,
        spaceAfter=8
    ))
    styles.add(ParagraphStyle(
        name="SectionTitle",
        fontSize=16,
        fontName="Helvetica-Bold",
        textColor=HEADER_BLUE,
        spaceAfter=8
    ))
    styles.add(ParagraphStyle(
        name="DynamicAnalysis",
        fontSize=12,
        fontName="Helvetica-Bold",
        spaceAfter=8
    ))
    styles.add(ParagraphStyle(
        name="SubsectionTitle",
        fontSize=13,
        fontName="Helvetica-Bold",
        textColor=HEADER_BLUE,
        spaceAfter=6
    ))
    styles.add(ParagraphStyle(
        name="SubSubsectionTitle",
        fontSize=11,
        fontName="Helvetica-Bold",
        textColor=HEADER_BLUE,
        spaceAfter=4
    ))

    elements = []

    file_info = f""" 
        Job ID: {report['job_id']}<br/> 
        File: {report['file']['name']}<br/> 
        File Hash : {report['file']['sha256']}<br/>
        Submitted at: {report['file']['submitted_at']}<br/> 
        Generated at: {report['timestamps']['generated_at']} 
    """ 
    elements.append(Paragraph(file_info, styles["FileInfo"]))
    elements.append(Spacer(1, 16))

    # =========================
    # Verdict block
    # =========================
    verdict = report["verdict"]

    verdict_table = Table([
        ["Malicious", "Confidence", "Score"],
        [
            str(verdict["malicious"]),
            f"{verdict['confidence']*100}%",
            str(verdict["score"])
        ]
    ], colWidths=[150, 150, 150])

    verdict_table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), TABLE_HEADER_GREY),
        ('TEXTCOLOR', (0,0), (-1,0), colors.black),
        ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
        ('BACKGROUND', (0,1), (-1,1), colors.red if verdict["malicious"] else colors.green),
        ('TEXTCOLOR', (0,1), (-1,1), colors.white),
        ('GRID', (0,0), (-1,-1), 0.5, BORDER_GREY),
        ('ALIGN', (0,0), (-1,-1), 'CENTER'),
    ]))

    elements.append(Paragraph("Verdict", styles["SectionTitle"]))
    elements.append(Spacer(1, 12))
    elements.append(verdict_table)
    elements.append(Spacer(1, 16))

    # =========================
    # Static Analysis
    # =========================
    static = report["static_analysis"]
    elements.append(Paragraph("Static Analysis", styles["SectionTitle"]))
    elements.append(Spacer(1, 12))


    elements.append(Paragraph("Virus Total analysis", styles["SubsectionTitle"]))
    elements.append(Spacer(1, 12))

    elements.append(Paragraph(
        f"""
        <b>Engine:</b> {static.get('engine')}<br/>
        <b>Detections Anti Virus from hash:</b> {static.get('detections')}/{static.get('total_engines')}<br/>
        <b>Tags:</b> {", ".join(static.get("tags", [])) or "None"}
        """,
        styles["Normal"]
    ))
    elements.append(Spacer(1, 16))

    popular_threat_classification = static.get("popular_threat_classification", {})
    elements.append(Paragraph("Popular Threat Classification", styles["SubSubsectionTitle"]))
    elements.append(Spacer(1, 12))

    if popular_threat_classification:
        popular_names = popular_threat_classification.get("popular_threat_name", [])
        if popular_names:
            threat_names = ", ".join([f"{item['value']} ({item['count']})" for item in popular_names])
            elements.append(Paragraph(f"Popular Threat Names: {threat_names}", styles["Normal"]))
            elements.append(Spacer(1, 12))
        
        suggested_label = popular_threat_classification.get('suggested_threat_label', 'None')
        elements.append(Paragraph(f"Suggested Threat Label: {suggested_label}", styles["Normal"]))
    else:
        elements.append(Paragraph("No popular threat classification found", styles["Normal"]))
    
    elements.append(Spacer(1, 16))

    elements.append(Paragraph("Last Analysis Results", styles["SubSubsectionTitle"]))
    elements.append(Spacer(1, 12))

    last_analysis_results = static.get("last_analysis_results", {})
    if last_analysis_results:
        rows = []
        for engine_name, engine_info in last_analysis_results.items():
            result = engine_info.get('result', 'Unknown')
            row = [f"Engine Name: {engine_name}", f"Result: {result}"]
            rows.append(row)
        
        table = Table(rows, colWidths=[250, 250])
        table.setStyle(TableStyle([
            ('GRID', (0, 0), (-1, -1), 0, colors.white),
            ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ('FONTNAME', (0, 0), (-1, -1), 'Helvetica'),
            ('FONTSize', (0, 0), (-1, -1), 10),
            ('TOPPADDING', (0, 0), (-1, -1), 1),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 1),
            ('LEFTPADDING', (0, 0), (-1, -1), 1),
            ('RIGHTPADDING', (0, 0), (-1, -1), 1),
        ]))
        elements.append(table)
    else:
        elements.append(Paragraph("No analysis results found", styles["Normal"]))
    
    elements.append(Spacer(1, 16))

    # =========================
    # Yara Matches
    # =========================

    elements.append(Paragraph("Local analysis", styles["SubsectionTitle"]))
    elements.append(Spacer(1, 12))

    elements.append(Paragraph("Yara Matches", styles["SubSubsectionTitle"]))
    elements.append(Spacer(1, 8))
    for y in static.get("yara_matches", []) or ["None"]:
        elements.append(Paragraph(f"- {y}", styles["Normal"]))

    elements.append(Spacer(1, 16))
    
    # =========================
    # Dynamic Analysis
    # =========================
    dyn = report["dynamic_analysis"]
    elements.append(Paragraph("Dynamic Analysis", styles["SectionTitle"]))
    elements.append(Spacer(1, 12))
    engine_type = dyn.get("engine", "unknown")
    elements.append(Paragraph(
        f"<b>Engine:</b> {dyn.get('engine', 'unknown')}",
        styles["Normal"]
    ))
    elements.append(Spacer(1, 12))
    elements.append(Paragraph(f"<b>Score:</b> {dyn.get('score', 0)} | <b>Tags:</b> {', '.join(dyn.get('tags', []))}", styles["Normal"]))
    elements.append(Spacer(1, 16))

    # ===== CUCKOO3-SPECIFIC SECTIONS =====
    if engine_type == "cuckoo3":
        # TTPS table (Cuckoo3 only)
        ttps = dyn.get("ttps", [])
        if ttps:
            rows = [["ID", "Name", "Tactics"]] + [[t.get("id", ""), t.get("name", ""), ", ".join(t.get("tactics", []))] for t in ttps]
            t = Table(rows, colWidths=[80, 200, 150])
            t.setStyle(TableStyle([('BACKGROUND', (0,0), (-1,0), TABLE_HEADER_GREY), ('GRID', (0,0), (-1,-1), 0.5, BORDER_GREY), ('ALIGN', (0,0), (-1,-1), 'LEFT')]))
            elements.append(Paragraph("MITRE ATTACK TTPs", styles["SectionTitle"]))
            elements.append(Spacer(1, 12))
            elements.append(t)
            elements.append(Spacer(1, 16))

        # Tasks table (Cuckoo3 only)
        tasks_data = dyn.get("tasks", [])
        if tasks_data:
            rows = [["Task ID", "Platform", "Duration"]] + [[t.get("id"), f"{t.get('platform')}-{t.get('os_version')}", f"{format_ts(t.get('started_on'))} → {format_ts(t.get('stopped_on'))}"] for t in tasks_data]
            task_table = Table(rows, colWidths=[120, 100, 220])
            elements.append(Paragraph("Analysis Tasks", styles["SectionTitle"]))
            elements.append(Spacer(1, 12))
            elements.append(task_table)
            elements.append(Spacer(1, 16))

    # ===== EBPF-SPECIFIC SECTIONS =====
    elif engine_type == "ebpf":
        # eBPF Verdict and Reasons
        verdict_ebpf = dyn.get("verdict", "unknown")
        reasons = dyn.get("reasons", [])
        
        elements.append(Paragraph("Analysis Verdict", styles["SubsectionTitle"]))
        elements.append(Spacer(1, 12))
        elements.append(Paragraph(f"<b>Verdict:</b> {verdict_ebpf}", styles["Normal"]))
        
        if reasons:
            elements.append(Paragraph("<b>Reasons:</b>", styles["Normal"]))
            for reason in reasons:
                elements.append(Paragraph(f"- {reason}", styles["Normal"]))
        elements.append(Spacer(1, 16))
    
    # eBPF Files
    files = dyn.get("files", [])
    if files:
        elements.append(Paragraph("Files Accessed", styles["SubsectionTitle"]))
        elements.append(Spacer(1, 12))
        for f in files:
            elements.append(Paragraph(f"- {f}", styles["Normal"]))
        elements.append(Spacer(1, 16))
    
    # eBPF Executions
    executions = dyn.get("executions", [])
    if executions:
        elements.append(Paragraph("Process Executions", styles["SubsectionTitle"]))
        elements.append(Spacer(1, 12))
        for exe in executions:
            if isinstance(exe, dict):
                binary = exe.get('binary', 'unknown')
                arg1 = exe.get('arg1', '')
                arg2 = exe.get('arg2', '')
                cmd_parts = [binary]
                if arg1:
                    cmd_parts.append(arg1)
                if arg2:
                    cmd_parts.append(arg2)
            
                command = ' '.join(cmd_parts)
                elements.append(Paragraph(f"- {command}", styles["Normal"]))
            else:
                elements.append(Paragraph(f"- {str(exe)}", styles["Normal"]))
        elements.append(Spacer(1, 16))

    # ===== COMMON SECTIONS (Both engines) =====
    def section_table(title, headers, rows, widths):
        table_elements = []
        table_elements.append(Paragraph(title, styles["DynamicAnalysis"]))
        table_elements.append(Spacer(1, 4))
    
        t = Table([headers] + rows, colWidths=widths, repeatRows=1)
        t.setStyle(TableStyle([
            ('BACKGROUND', (0,0), (-1,0), TABLE_HEADER_GREY),
            ('GRID', (0,0), (-1,-1), 0.5, BORDER_GREY),
            ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
            ('VALIGN', (0,0), (-1,-1), 'TOP'),
        ]))
    
        table_elements.append(t)
        table_elements.append(Spacer(1, 16))
    
        elements.append(KeepTogether(table_elements))


    sections = [
        ("Processes", ["PID", "Name", "PPID", "Command"], dyn.get("processes", []), [50, 120, 50, 260]),
        ("Filesystem Changes", ["Path", "Operation"], dyn.get("filesystem", []), [320, 160]),
        ("Network IOCs", ["Type", "Value"], dyn.get("network", []), [100, 380]),
        ("Registry Changes", ["Key", "Operation"], dyn.get("registry", []), [320, 160]),
    ]

    for title, headers, rows, widths in sections:
        if rows:
            section_table(title, headers, [[
                r.get(k.lower(), "") if k.lower() in r else r.get("cmdline","") 
                for k in headers
            ] for r in rows], widths)
        else:
            elements.append(Paragraph(title, styles["DynamicAnalysis"]))
            elements.append(Paragraph("None", styles["Normal"]))
            elements.append(Spacer(1, 16))

    # =========================
    # IOCs
    # =========================
    iocs = report.get("iocs", {})

    elements.append(Paragraph("Indicators of Compromise (IOCs)", styles["SectionTitle"]))
    elements.append(Spacer(1, 12))

    def ioc_block(title, values):
        elements.append(Paragraph(title, styles["DynamicAnalysis"]))
        if values:
            for v in values:
                elements.append(Paragraph(f"- {str(v)}", styles["Normal"]))
        else:
            elements.append(Paragraph("None", styles["Normal"]))
        elements.append(Spacer(1, 12))

    ioc_block("IP Addresses", iocs.get("ips", []))
    ioc_block("Domains", iocs.get("domains", []))
    ioc_block("URLs", iocs.get("urls", []))
    ioc_block("Ports", iocs.get("ports", []))
    ioc_block("User-Agents", iocs.get("user_agents", []))
    ioc_block("Hashes", iocs.get("hashes", []))

    doc.build(
        elements,
        onFirstPage=lambda c, d: draw_header_footer(c, d, report),
        onLaterPages=lambda c, d: draw_header_footer(c, d, report)
    )

    buffer.seek(0)

    return StreamingResponse(
        buffer,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="report_{job_id}.pdf"'}
    )

@app.get("/", response_class=HTMLResponse)
@app.get("/ui", response_class=HTMLResponse)
@app.get("/ui/", response_class=HTMLResponse)
def serve_ui():
    index_path = STATIC_DIR / "index.html"
    if not index_path.exists():
        return HTMLResponse("index.html not found", status_code=404)

    return HTMLResponse(content=index_path.read_text(encoding="utf-8"))
