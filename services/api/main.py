import os, uuid, hashlib, json
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from redis import Redis
from fastapi.responses import StreamingResponse
import io
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas
from reportlab.lib import colors
from reportlab.platypus import Table, TableStyle, SimpleDocTemplate, Paragraph, Spacer, PageBreak
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.pdfgen import canvas as pdf_canvas
from reportlab.platypus import KeepTogether


REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
RESULTS_PATH = Path(os.getenv("RESULTS_PATH", "/data/results"))
MAX_SIZE = 50 * 1024 * 1024

RESULTS_PATH.mkdir(parents=True, exist_ok=True)

redis_client = Redis.from_url(REDIS_URL, decode_responses=True)

app = FastAPI(title="Malware Analysis API", version="1.0.0")

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


@app.get("/health")
def health():
  try:
    redis_client.ping()
    r_ok = True
  except Exception:
    r_ok = False
  return {"status": "ok" if r_ok else "degraded", "redis": r_ok}


@app.post("/api/submit", response_model=SubmissionResponse)
async def submit(file: UploadFile = File(...)):
  data = await file.read()
  if len(data) > MAX_SIZE:
    raise HTTPException(413, "File too large")
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
    "submitted_at": datetime.utcnow().isoformat(),
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
def result(job_id: str):
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
def list_jobs():
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
def delete_job(job_id: str):
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
def download_result(job_id: str):
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

def format_ts(ts: str) -> str:
    return datetime.fromisoformat(ts).strftime("%Y-%m-%d %H:%M:%S")


def build_unified_report(job_id: str, meta: dict, static_raw: str | None, dynamic_raw: str | None):
    static = json.loads(static_raw) if static_raw else {}
    dynamic = json.loads(dynamic_raw) if dynamic_raw else {}

    vt = static.get("virustotal", {})
    vt_stats = vt.get("data", {}).get("attributes", {}).get("last_analysis_stats", {})

    malicious_count = vt_stats.get("malicious", 0)
    total_engines = sum(vt_stats.values()) if vt_stats else 0

    score = dynamic.get("analysis", {}).get("summary", {}).get("score", 0)
    malicious_dynamic = dynamic.get("analysis", {}).get("summary", {}).get("malicious", False)

    verdict_malicious = malicious_dynamic or malicious_count > 0

    ips = set()
    domains = set()
    urls = set()
    ports = set()
    user_agents = set()

    network_events = dynamic.get("analysis", {}).get("network_iocs", [])

    for evt in network_events:
        evt_type = evt.get("type")
        value = evt.get("value")

        if not evt_type or value is None:
            continue

        if evt_type == "ip":
            ips.add(value)

            port = evt.get("port")
            proto = evt.get("protocol")
            if port:
                ports.add(f"{port}/{proto or 'unknown'}")

        elif evt_type == "domain":
            domains.add(value)

        elif evt_type == "url":
            urls.add(value)

        elif evt_type in ("user-agent", "user_agent"):
            user_agents.add(value)

        elif evt_type == "port":
            ports.add(f"{value}/unknown")


    report = {
        "job_id": job_id,
        "file": {
            "name": meta.get("file_name"),
            "sha256": meta.get("file_hash"),
            "submitted_at": format_ts(meta.get("submitted_at")),
        },
        "verdict": {
            "malicious": verdict_malicious,
            "confidence": round(malicious_count / total_engines, 2) if total_engines else 0.0,
            "score": score,
        },
        "static_analysis": {
            "engine": "VirusTotal",
            "detections": malicious_count,
            "total_engines": total_engines,
            "tags": vt.get("data", {}).get("attributes", {}).get("tags", []),
            "yara_matches": static.get("yara_matches", []),
        },
        "dynamic_analysis": {
            "engine": dynamic.get("analysis", {}).get("summary", {}).get("engine", "unknown"),
            "processes": dynamic.get("analysis", {}).get("process_tree", []),
            "filesystem": dynamic.get("analysis", {}).get("file_system_changes", []),
            "network": dynamic.get("analysis", {}).get("network_iocs", []),
            "registry": dynamic.get("analysis", {}).get("registry_changes", []),
        },
        "iocs": {
            "ips": sorted(ips),
            "domains": sorted(domains),
            "urls": sorted(urls),
            "ports": sorted(ports),
            "user_agents": sorted(user_agents),
            "hashes": [meta.get("file_hash")],
        },
        "timestamps": {
            "generated_at": format_ts(datetime.utcnow().isoformat()),
        }
    }

    return report

@app.get("/api/report/{job_id}")
def get_report(job_id: str):
    job_raw = redis_client.get(f"job:{job_id}")
    if not job_raw:
        raise HTTPException(404, "job not found")

    meta = json.loads(job_raw)
    static_raw = redis_client.get(f"result_static:{job_id}")
    dynamic_raw = redis_client.get(f"result_dynamic:{job_id}")

    report = build_unified_report(job_id, meta, static_raw, dynamic_raw)
    return JSONResponse(report)

@app.get("/api/report/{job_id}/download")
def download_report(job_id: str):
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
def download_report_pdf(job_id: str):
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

    elements.append(Paragraph(
        f"""
        <b>Engine:</b> {static.get('engine')}<br/>
        <b>Detections:</b> {static.get('detections')}/{static.get('total_engines')}<br/>
        <b>Tags:</b> {", ".join(static.get("tags", [])) or "None"}
        """,
        styles["Normal"]
    ))
    elements.append(Spacer(1, 16))

    elements.append(Paragraph("Yara Matches", styles["SectionTitle"]))
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
    elements.append(Paragraph(
        f"<b>Engine:</b> {dyn.get('engine', 'unknown')}",
        styles["Normal"]
    ))
    elements.append(Spacer(1, 12))

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
