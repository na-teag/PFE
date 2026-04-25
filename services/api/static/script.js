// ─── CONFIG ───────────────────────────────────────────────
const PAGE_SIZE = 10;
const MAX_FILE_SIZE = 50 * 1024 * 1024;
const ALLOWED_EXT = [".exe",".dll",".pdf",".doc",".docx",".zip",".ps1",".sh",".bat",".js",".py",".elf"];

// ─── STATE ────────────────────────────────────────────────
let currentJobId = null;
let currentView = "report";
let allJobs = [];
let filteredJobs = [];
let currentPage = 1;
let refreshInterval = null;
let healthInterval = null;
let jobsAbortCtrl = null;
let reportPollInterval = null;
let selectedFile = null;
// ─── AJOUTER UN INTERVALLE DE RAFRAÎCHISSEMENT AUTOMATIQUE ──
let dashboardRefreshInterval = null;
let isRefreshing = false; // Éviter les appels concurrents
let isLoggedIn = false;

// ─── FETCH avec gestion 401 ───────────────────────────────
async function apiFetch(url, opts = {}) {
  opts.credentials = "include"; // toujours envoyer le cookie session
  let r;
  try { r = await fetch(url, opts); }
  catch(e) { throw new Error("API unavailable"); }

  if (r.status === 401) {
    // Session expirée → retour au login
    if (isLoggedIn) {
      showLogin("Your session has expired. Please log in again");
    }
    throw new Error("Unauthorized");
  }
  return r;
}

function isValidUUID(uuid) {
  const regex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return regex.test(uuid);
}

function showLogin(msg = "") {
  isLoggedIn = false;
  stopAll();
  
  // Cacher le contenu principal avec les classes
  document.querySelector("header").classList.remove("flex-display");
  document.querySelector("header").classList.add("hidden");
  
  document.querySelector(".layout").classList.remove("grid-display");
  document.querySelector(".layout").classList.add("hidden");
  
  // Afficher le login overlay
  document.getElementById("loginOverlay").classList.remove("hidden");
  document.getElementById("loginOverlay").classList.add("flex-display");
  
  document.getElementById("loginInput").value = "";
  document.getElementById("loginError").textContent = msg;
}

async function checkAuth() {
  try {
    const rj = await fetch("/api/jobs", { credentials: "include" });
    if (rj.status === 401) {
      // Afficher uniquement le login
      showLogin();
    } else {
      isLoggedIn = true;
      
      // Cacher le login overlay
      document.getElementById("loginOverlay").classList.remove("flex-display");
      document.getElementById("loginOverlay").classList.add("hidden");
      
      // Afficher le header
      document.querySelector("header").classList.remove("hidden");
      document.querySelector("header").classList.add("flex-display");
      
      // Afficher le layout
      document.querySelector(".layout").classList.remove("hidden");
      document.querySelector(".layout").classList.add("grid-display");
      
      start();
    }
  } catch {
    showLogin();
  }
}

async function doLogin() {
  const val = document.getElementById("loginInput").value.trim();
  if (!val) return;
  const err = document.getElementById("loginError");
  const btn = document.getElementById("loginBtn");
  err.textContent = "";
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>Connexion...';
  stopAutoRefresh();

  try {
    const r = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: val }),
      credentials: "include"
    });
    if (r.ok) {
      isLoggedIn = true;
      
      // Cacher le login overlay
      document.getElementById("loginOverlay").classList.remove("flex-display");
      document.getElementById("loginOverlay").classList.add("hidden");
      
      // Afficher le header
      document.querySelector("header").classList.remove("hidden");
      document.querySelector("header").classList.add("flex-display");
      
      // Afficher le layout
      document.querySelector(".layout").classList.remove("hidden");
      document.querySelector(".layout").classList.add("grid-display");
      
      start();
    } else if (r.status === 429) {
      err.textContent = "Too many attempts. Please try again in 5 minutes";
    } else {
      err.textContent = "API key invalid";
    }
  } catch {
    err.textContent = "Network error";
  } finally {
    btn.disabled = false;
    btn.textContent = "Login";
  }
}

async function doLogout() {
  stopAutoRefresh();
  stopAll();
  try {
    await apiFetch("/api/logout", { method: "POST", credentials: "include" });
  } catch {}
  isLoggedIn = false; 
  showLogin();
}

// ─── HEALTH ───────────────────────────────────────────────
async function checkHealth() {
  const dot = document.getElementById("healthDot");
  const lbl = document.getElementById("healthLabel");
  try {
    const r = await fetch("/health", { credentials: "include" });
    if (r.ok) {
      const data = await r.json();
      const ok = data.status === "ok";
      dot.className = "health-dot " + (ok ? "ok" : "err");
      lbl.textContent = ok ? "API healthy" : "Redis degraded";
    } else {
      dot.className = "health-dot err"; lbl.textContent = "API error";
    }
  } catch { dot.className = "health-dot err"; lbl.textContent = "Unreachable"; }
}

// ─── FILE ─────────────────────────────────────────────────
function onFileSelected() {
  const f = document.getElementById("fileInput").files[0];
  if (!f) return;
  const ext = "." + f.name.split(".").pop().toLowerCase();
  const nameEl = document.getElementById("fileName");
  const btn = document.getElementById("submitBtn");
  const result = document.getElementById("submitResult");
  if (!f.type) {
    result.textContent = "Unknown file type";
    result.className = "submit-result error";
    btn.disabled = true;
    return;
  }
  if (f.size > MAX_FILE_SIZE) {
    nameEl.textContent = ""; result.textContent = "File too large (max 50MB)";
    result.className = "submit-result error"; btn.disabled = true; selectedFile = null; return;
  }
  if (!ALLOWED_EXT.includes(ext)) {
    nameEl.textContent = ""; result.textContent = "File type not allowed: " + ext;
    result.className = "submit-result error"; btn.disabled = true; selectedFile = null; return;
  }
  selectedFile = f; nameEl.textContent = f.name; result.textContent = ""; btn.disabled = false;
}

// ─── SUBMIT ───────────────────────────────────────────────
async function submitFile() {
  if (!selectedFile) return;
  const btn = document.getElementById("submitBtn");
  const result = document.getElementById("submitResult");
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>Submitting...';
  result.textContent = ""; result.className = "submit-result";
  try {
    const fd = new FormData();
    fd.append("file", selectedFile);
    fd.append("sandbox_os", document.getElementById("osSelect").value);
    const r = await apiFetch("/api/submit", { method: "POST", body: fd });
    const data = await r.json();
    if (!r.ok) {
      result.textContent = "Error: " + (data.detail || r.status);
      result.className = "submit-result error";
    } else {
      result.textContent = "Submitted: " + (data.job_id || "ok");
      result.className = "submit-result ok";
      document.getElementById("fileName").textContent = "";
      selectedFile = null; document.getElementById("fileInput").value = "";
      await loadJobs();
      if (!currentJobId) {
        await renderDashboard();
      }
      startAutoRefresh();
    }
  } catch(e) {
    if (e.message !== "Unauthorized") {
      result.textContent = e.message; result.className = "submit-result error";
    }
  } finally {
    btn.disabled = false; btn.textContent = "Submit";
  }
}

// ─── JOBS ─────────────────────────────────────────────────
async function loadJobs() {
  if (jobsAbortCtrl) jobsAbortCtrl.abort();
  jobsAbortCtrl = new AbortController();
  try {
    const r = await fetch("/api/jobs", { credentials: "include", signal: jobsAbortCtrl.signal });
    if (r.status === 401) { 
      if (isLoggedIn){
        showLogin("Your session has expired. Please log in again");
      }
      return; 
    }
    const data = await r.json();
    allJobs = data.jobs || [];
    applyFilterSort();
  } catch(e) {
    if (e.name !== "AbortError") console.error("loadJobs:", e);
  }
}

function onFilter() { currentPage = 1; applyFilterSort(); }

function applyFilterSort() {
  const query = (document.getElementById("searchInput").value || "").toLowerCase().trim();
  const sort = document.getElementById("sortSelect").value;
  let jobs = query ? allJobs.filter(j => j.file_name.toLowerCase().includes(query)) : [...allJobs];
  jobs.sort((a, b) => {
    if (sort === "date-desc") return (b.submitted_at || "") > (a.submitted_at || "") ? 1 : -1;
    if (sort === "date-asc")  return (a.submitted_at || "") > (b.submitted_at || "") ? 1 : -1;
    if (sort === "name-asc")  return a.file_name.localeCompare(b.file_name);
    if (sort === "name-desc") return b.file_name.localeCompare(a.file_name);
    if (sort === "status")    return (a.status_static + a.status_dynamic).localeCompare(b.status_static + b.status_dynamic);
    return 0;
  });
  filteredJobs = jobs;
  renderJobsList(query);
}

function renderJobsList(query = "") {
  const total = filteredJobs.length;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  if (currentPage > totalPages) currentPage = totalPages;
  const pageJobs = filteredJobs.slice((currentPage - 1) * PAGE_SIZE, currentPage * PAGE_SIZE);

  document.getElementById("jobCount").textContent =
    query ? `${total}/${allJobs.length}` : `${allJobs.length} job${allJobs.length !== 1 ? "s" : ""}`;

  const list = document.getElementById("jobsList");
  if (!pageJobs.length) {
    list.innerHTML = `<div class="empty-jobs">${query ? 'No results for "' + escHtml(query) + '"' : "No jobs yet"}</div>`;
  } else {
    list.innerHTML = "";
    pageJobs.forEach(j => {
      const div = document.createElement("div");
      div.className = "job-row" + (j.job_id === currentJobId ? " active" : "");
      const highlightedName = query
        ? escHtml(j.file_name).replace(new RegExp(escRegex(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), "gi"), m => `<mark>${m}</mark>`)
        : escHtml(j.file_name);
      const dateStr = j.submitted_at ? formatDate(j.submitted_at) : "";
      div.dataset.jobId = j.job_id;
      div.innerHTML = `
        <div class="job-info">
          <div class="job-name">${highlightedName}</div>
          <div class="job-meta">
            <div class="job-id">${escHtml(j.job_id)}</div>
            ${dateStr ? `<div class="job-date">${escHtml(dateStr)}</div>` : ""}
          </div>
        </div>
        <div class="badges">
          <span class="badge ${escHtml(j.status_static)}">${escHtml(j.status_static)}</span>
          <span class="badge ${escHtml(j.status_dynamic)}">${escHtml(j.status_dynamic)}</span>
        </div>`;
      div.addEventListener("click", () => selectJob(j.job_id));
      list.appendChild(div);
    });
  }

  const paginationBar = document.getElementById("paginationBar");
  if (totalPages <= 1) {
    paginationBar.classList.add("hidden");
    paginationBar.classList.remove("flex-display");
  } else {
    paginationBar.classList.remove("hidden");
    paginationBar.classList.add("flex-display");
    document.getElementById("pageInfo").textContent = `Page ${currentPage}/${totalPages}`;
    const pageBtns = document.getElementById("pageBtns");
    pageBtns.innerHTML = "";
    const addBtn = (label, page, isCurrent, disabled) => {
      const b = document.createElement("button");
      b.className = "page-btn" + (isCurrent ? " current" : "");
      b.textContent = label; b.disabled = disabled || isCurrent;
      b.addEventListener("click", () => { currentPage = page; renderJobsList(query); });
      pageBtns.appendChild(b);
    };
    addBtn("←", currentPage - 1, false, currentPage === 1);
    for (let p = Math.max(1, currentPage - 2); p <= Math.min(totalPages, currentPage + 2); p++) {
      addBtn(p, p, p === currentPage, false);
    }
    addBtn("→", currentPage + 1, false, currentPage === totalPages);
  }
}

// ─── SELECT / REPORT ──────────────────────────────────────
function selectJob(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  currentJobId = id; 
  currentView = "report";
    // Arrêter l'auto-refresh quand on regarde un job spécifique
  stopAutoRefresh();
  stopReportPoll(); 
  applyFilterSort(); 
  loadReport(id);
}

async function loadReport(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  const main = document.getElementById("mainContent");
  main.innerHTML = '<div class="placeholder"><div class="spinner loading-spinner"></div><div>Loading...</div></div>';
  try {
    const r = await apiFetch(`/api/report/${id}`);
    const data = await r.json();
    if (!r.ok) {
      main.innerHTML = `<div class="card"><div class="error-msg">Error: ${escHtml(data.detail || String(r.status))}</div></div>`;
      return;
    }
    renderReport(id, data);
    const isFinished = isJobFinished(data);
    if (!isFinished) startReportPoll(id);
  } catch(e) {
    if (e.message !== "Unauthorized")
      main.innerHTML = `<div class="card"><div class="error-msg">${escHtml(e.message)}</div></div>`;
  }
}

function isJobFinished(data) {
  return (data.status_static === "completed" || data.status_static === "failed")
      && (data.status_dynamic === "completed" || data.status_dynamic === "failed");
}

function startReportPoll(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  stopReportPoll();
  reportPollInterval = setInterval(async () => {
    try {
      const r = await apiFetch(`/api/report/${id}`);
      if (!r.ok) return;
      const data = await r.json();
      if (currentView === "report") {
        renderReport(id, data);
      }
      
      // Si le job est terminé
      if (isJobFinished(data)) {
        stopReportPoll();
        await loadJobs();
        
        if (!currentJobId) {
          await renderDashboard();
        } else {
          applyFilterSort();
        }
        
        // Vérifier si tous les jobs sont terminés
        const allFinished = allJobs.every(job => 
          (job.status_static === "completed" || job.status_static === "failed") &&
          (job.status_dynamic === "completed" || job.status_dynamic === "failed")
        );
        
        // Si tous les jobs sont terminés, arrêter l'auto-refresh
        if (allFinished && allJobs.length > 0) {
          stopAutoRefresh();
        }
      }
    } catch {}
  }, 5000);
}

function stopReportPoll() {
  if (reportPollInterval) { clearInterval(reportPollInterval); reportPollInterval = null; }
}

function renderReport(id, data) {
  const main = document.getElementById("mainContent");
  const v = data.verdict || {};
  const iocs = data.iocs || {};
  const isMalicious = v.malicious === true || v.malicious === "true";
  const finished = isJobFinished(data);

  // Verdict card
  const verdictCard = makeCard("Verdict",
    finished ? "" : `<div class="auto-refresh-badge"><div class="pulse"></div>Analysis in progress...</div>`,
    `<div class="verdict-grid">
      <div class="verdict-cell"><div class="verdict-label">Malicious</div><div class="verdict-value ${isMalicious ? 'malicious' : 'clean'}">${isMalicious ? "Yes" : "No"}</div></div>
      <div class="verdict-cell"><div class="verdict-label">Score</div><div class="verdict-value">${v.score != null ? escHtml(String(v.score)) : "-"}</div></div>
      <div class="verdict-cell"><div class="verdict-label">Confidence</div><div class="verdict-value">${v.confidence != null ? escHtml(String(v.confidence)) : "-"}</div></div>
    </div>`
  );

  // IOCs card
  const iocsCard = makeCard("IOCs", "",
    `<div class="iocs-grid">
      ${renderIOCGroup("IPs", iocs.ips)}
      ${renderIOCGroup("Domains", iocs.domains)}
      ${renderIOCGroup("URLs", iocs.urls)}
    </div>`
  );

  // Actions card — addEventListener uniquement (XSS fix)
  const actionsCard = document.createElement("div");
  actionsCard.className = "card";
  const actionsHeader = document.createElement("div");
  actionsHeader.className = "card-header";
  actionsHeader.innerHTML = '<div class="card-title">Actions</div>';
  actionsCard.appendChild(actionsHeader);
  const actionsBar = document.createElement("div");
  actionsBar.className = "actions-bar";

  const openSafe = (url) => {
    window.open(url, "_blank", "noopener,noreferrer");
  };

  const btnResult = makeBtn("JSON Result", "btn-secondary", () => showResult(id));
  btnResult.id = "btnResult";
  const btnReport = makeBtn("JSON Report", "btn-secondary active-view", () => showReport(id));
  btnReport.id = "btnReport";
  const btnDlResult = makeBtn("Download Result", "btn-secondary", () => openSafe("/api/result/" + id + "/download"));
  const btnDlPdf    = makeBtn("Download PDF",    "btn-secondary", () => openSafe("/api/report/" + id + "/pdf"));
  const btnDelete   = makeBtn("Delete Job",      "btn-danger",    () => deleteJob(id));

  [btnResult, btnReport, btnDlResult, btnDlPdf, btnDelete].forEach(b => actionsBar.appendChild(b));
  actionsCard.appendChild(actionsBar);

  // JSON card
  const jsonCard = makeCard("Raw JSON", "", "");
  const pre = document.createElement("pre");
  pre.className = "json-viewer"; pre.id = "jsonViewer";
  pre.innerHTML = syntaxHighlight(data);
  jsonCard.appendChild(pre);

  main.innerHTML = "";
  [verdictCard, iocsCard, actionsCard, jsonCard].forEach(c => main.appendChild(c));
}

function makeCard(title, headerExtra, bodyHTML) {
  const card = document.createElement("div");
  card.className = "card";
  card.innerHTML = `<div class="card-header"><div class="card-title">${escHtml(title)}</div>${headerExtra}</div>${bodyHTML}`;
  return card;
}

function makeBtn(label, classes, handler) {
  const b = document.createElement("button");
  b.className = "btn " + classes; b.textContent = label;
  b.addEventListener("click", handler);
  return b;
}

function setActiveViewBtn(view) {
  currentView = view;
  const bR = document.getElementById("btnResult");
  const bRp = document.getElementById("btnReport");
  if (!bR || !bRp) return;
  bR.classList.toggle("active-view", view === "result");
  bRp.classList.toggle("active-view", view === "report");
}

async function showResult(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  setActiveViewBtn("result");
  try {
    const r = await apiFetch(`/api/result/${id}`);
    const data = await r.json();
    const el = document.getElementById("jsonViewer");
    if (el) el.innerHTML = r.ok ? syntaxHighlight(data) : `<span class="error-msg">Error: ${escHtml(data.detail)}</span>`;
  } catch(e) {
    const el = document.getElementById("jsonViewer");
    if (el && e.message !== "Unauthorized") el.innerHTML = `<span class="error-msg">${escHtml(e.message)}</span>`;
  }
}

async function showReport(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  setActiveViewBtn("report");
  try {
    const r = await apiFetch(`/api/report/${id}`);
    const data = await r.json();
    const el = document.getElementById("jsonViewer");
    if (el) el.innerHTML = r.ok ? syntaxHighlight(data) : `<span class="error-msg">Error: ${escHtml(data.detail)}</span>`;
  } catch(e) {
    const el = document.getElementById("jsonViewer");
    if (el && e.message !== "Unauthorized") el.innerHTML = `<span class="error-msg">${escHtml(e.message)}</span>`;
  }
}

async function deleteJob(id) {
  if (!isValidUUID(id)) {
    console.debug("Invalid job ID:", id);
    return;
  }
  if (!confirm(`Delete job ${id} and all its results ?`)) return;
  stopReportPoll();
  try {
    const r = await apiFetch(`/api/jobs/${id}`, { method: "DELETE" });
    if (r.ok) {
      currentJobId = null;
      await loadJobs();
      await renderDashboard();
      
      // Vérifier s'il reste des jobs en cours
      const hasRunningJobs = allJobs.some(job => 
        (job.status_static !== "completed" && job.status_static !== "failed") ||
        (job.status_dynamic !== "completed" && job.status_dynamic !== "failed")
      );
      
      // Arrêter l'auto-refresh si plus de jobs en cours
      if (!hasRunningJobs) {
        stopAutoRefresh();
      }
    } else {
      const data = await r.json();
      alert("Error: " + (data.detail || r.status));
    }
  } catch(e) { 
    if (e.message !== "Unauthorized") alert(e.message); 
  }
}

// ─── HELPERS ──────────────────────────────────────────────
function renderIOCGroup(label, items) {
  const arr = Array.isArray(items) ? items : [];
  return `<div class="ioc-group">
    <div class="ioc-label">${escHtml(label)}</div>
    ${arr.length ? arr.map(i => `<div class="ioc-item">${escHtml(i)}</div>`).join("") : '<div class="ioc-empty">none</div>'}
  </div>`;
}

function formatDate(ts) {
  try {
    const d = new Date(ts);
    return d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit" })
      + " " + d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  } catch { return ""; }
}

function escHtml(s) {
  return String(s || "").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

function escRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function syntaxHighlight(json) {
  if (typeof json !== "string") json = JSON.stringify(json, null, 2);
  json = json.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
  return json.replace(
    /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(\.\d+)?([eE][+\-]?\d+)?)/g,
    m => {
      let cls = "json-number";
      if (/^"/.test(m)) cls = /:$/.test(m) ? "json-key" : "json-string";
      else if (/true|false/.test(m)) cls = "json-boolean";
      else if (/null/.test(m)) cls = "json-null";
      return `<span class="${cls}">${m}</span>`;
    }
  );
}

function stopAll() {
  clearInterval(refreshInterval); 
  refreshInterval = null;
   if (healthInterval) {
    clearInterval(healthInterval);
    healthInterval = null;
  }
  stopAutoRefresh();
  stopReportPoll();
  if (jobsAbortCtrl) { 
    jobsAbortCtrl.abort(); 
    jobsAbortCtrl = null; 
  }
}

// ─── VISIBILITY ───────────────────────────────────────────
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    // Ne rien faire quand l'onglet est caché
  } else {
    // Quand l'onglet devient visible
    if (currentJobId) {
      startReportPoll(currentJobId);
    } else {
      // Recharger les données et vérifier si on doit redémarrer l'auto-refresh
      loadJobs().then(() => {
        if (!currentJobId) {
          renderDashboard();
          
          // Vérifier s'il y a des jobs en cours
          const hasRunningJobs = allJobs.some(job => 
            (job.status_static !== "completed" && job.status_static !== "failed") ||
            (job.status_dynamic !== "completed" && job.status_dynamic !== "failed")
          );
          
          if (hasRunningJobs && !dashboardRefreshInterval) {
            startAutoRefresh();
          }
        }
      });
    }
  }
});

function drawPipelineChart(running, completed, failed) {
  const ctx = document.getElementById("statusChart");
  if (!ctx) return;

  const c = ctx.getContext("2d");
  const w = ctx.width = 400;
  const h = ctx.height = 200;
  
  // Effacer le canvas
  c.clearRect(0, 0, w, h);
  
  // Titre du graphique
  c.fillStyle = "#1e293b";
  c.font = "bold 14px Arial";
  c.textAlign = "center";
  c.fillText("Pipeline status", w/2, 18);
  
  // Données
  const data = [
    { label: "Running", val: running, color: "#3b82f6" },
    { label: "Completed", val: completed, color: "#22c55e" },
    { label: "Failed", val: failed, color: "#ef4444" }
  ];
  
  const max = Math.max(...data.map(d => d.val), 1);
  const barWidth = w - 100;
  const startY = 45;
  
  // Dessiner les barres
  data.forEach((d, i) => {
    const y = startY + i * 35;
    const barLength = (d.val / max) * barWidth;
    
    // Barre
    c.fillStyle = d.color;
    c.fillRect(80, y, barLength, 18);
    
    // Label
    c.fillStyle = "#475569";
    c.font = "12px Arial";
    c.textAlign = "left";
    c.fillText(d.label, 10, y + 13);
    
    // Valeur
    c.fillStyle = "#1e293b";
    c.font = "bold 12px Arial";
    c.fillText(d.val.toString(), 85 + barLength, y + 13);
  });
  
  // Légende en bas
  const legendY = h - 25;
  const legendStartX = 30;
  const legendSpacing = 100;
  
  data.forEach((d, i) => {
    c.fillStyle = d.color;
    c.fillRect(legendStartX + i * legendSpacing, legendY, 12, 12);
    c.fillStyle = "#64748b";
    c.font = "11px Arial";
    c.textAlign = "left";
    c.fillText(d.label, legendStartX + i * legendSpacing + 16, legendY + 10);
  });
}

async function drawVerdictChart(jobs) {
  const ctx = document.getElementById("trendChart");
  if (!ctx) return;

  const c = ctx.getContext("2d");
  const w = ctx.width = 400;
  const h = ctx.height = 200;
  
  // Effacer le canvas
  c.clearRect(0, 0, w, h);
  
  // Titre du graphique
  c.fillStyle = "#1e293b";
  c.font = "bold 14px Arial";
  c.textAlign = "center";
  c.fillText("Malware detection", w/2, 18);
  
  let malicious = 0;
  let clean = 0;

  // Récupérer les verdicts pour tous les jobs terminés
  const verdictPromises = jobs.map(async (j) => {
    if (j.status_static === "completed" || j.status_static === "failed") {
      try {
        const r = await fetch(`/api/report/${j.job_id}`);
        if (r.ok) {
          const data = await r.json();
          return data.verdict?.malicious === true || data.verdict?.malicious === "true";
        }
      } catch(e) {
        console.debug(`Error retrieving the verdict for ${j.job_id}:`, e);
      }
    }
    return null;
  });

  const results = await Promise.all(verdictPromises);
  
  results.forEach(isMalicious => {
    if (isMalicious === true) {
      malicious++;
    } else if (isMalicious === false) {
      clean++;
    }
  });

  const total = malicious + clean;
  const centerX = w / 2;
  const centerY = h / 2 + 10;
  const radius = 65;
  
  // Vérifier si aucun job n'existe
  if (total === 0) {
    // Dessiner un cercle gris clair complet
    c.beginPath();
    c.fillStyle = "#e5e7eb";
    c.moveTo(centerX, centerY);
    c.arc(centerX, centerY, radius, 0, Math.PI * 2);
    c.closePath();
    c.fill();
    
    // Cercle intérieur blanc pour effet "donut"
    c.beginPath();
    c.fillStyle = "#fff";
    c.arc(centerX, centerY, radius * 0.55, 0, Math.PI * 2);
    c.fill();
    
    // Texte au centre
    c.fillStyle = "#1e293b";
    c.font = "bold 16px Arial";
    c.textAlign = "center";
    c.fillText("0%", centerX, centerY - 5);
    c.font = "11px Arial";
    c.fillStyle = "#64748b";
    c.fillText("malicious rate", centerX, centerY + 12);
    
    // Légende
    const legendX = w - 85;
    const legendYStart = 45;
    
    c.fillStyle = "#ef4444";
    c.fillRect(legendX, legendYStart, 12, 12);
    c.fillStyle = "#475569";
    c.font = "11px Arial";
    c.textAlign = "left";
    c.fillText("Malicious (0)", legendX + 18, legendYStart + 10);
    
    c.fillStyle = "#22c55e";
    c.fillRect(legendX, legendYStart + 25, 12, 12);
    c.fillStyle = "#475569";
    c.fillText("Clean (0)", legendX + 18, legendYStart + 35);
    
    return;
  }
  
  // Données pour le camembert (cas normal avec des jobs)
  const data = [
    { label: "Malicious", val: malicious, color: "#ef4444" },
    { label: "Clean", val: clean, color: "#22c55e" }
  ];
  
  // Dessiner le camembert
  let start = -Math.PI / 2;
  
  data.forEach(d => {
    const slice = (d.val / total) * Math.PI * 2;
    c.beginPath();
    c.fillStyle = d.color;
    c.moveTo(centerX, centerY);
    c.arc(centerX, centerY, radius, start, start + slice);
    c.closePath();
    c.fill();
    start += slice;
  });
  
  // Cercle intérieur blanc pour effet "donut"
  c.beginPath();
  c.fillStyle = "#fff";
  c.arc(centerX, centerY, radius * 0.55, 0, Math.PI * 2);
  c.fill();
  
  // Texte au centre
  c.fillStyle = "#1e293b";
  c.font = "bold 16px Arial";
  c.textAlign = "center";
  c.fillText(`${Math.round((malicious / total) * 100)}%`, centerX, centerY - 5);
  c.font = "11px Arial";
  c.fillStyle = "#64748b";
  c.fillText("malicious rate", centerX, centerY + 12);
  
  // Légende à droite
  const legendX = w - 85;
  const legendYStart = 45;
  
  data.forEach((d, i) => {
    c.fillStyle = d.color;
    c.fillRect(legendX, legendYStart + i * 25, 12, 12);
    c.fillStyle = "#475569";
    c.font = "11px Arial";
    c.textAlign = "left";
    c.fillText(`${d.label} (${d.val})`, legendX + 18, legendYStart + i * 25 + 10);
  });
}

async function renderDashboard() {
  currentJobId = null;
  const total = allJobs.length;

  const running = allJobs.filter(j =>
    j.status_static === "queued" || j.status_dynamic === "queued"
  ).length;

  const completed = allJobs.filter(j =>
    j.status_static === "completed" && j.status_dynamic === "completed"
  ).length;

  const failed = allJobs.filter(j =>
    j.status_static === "failed" || j.status_dynamic === "failed"
  ).length;

  const successRate = total ? Math.round((completed / total) * 100) : 0;

  const recent = [...allJobs]
    .sort((a,b) => (b.submitted_at > a.submitted_at ? 1 : -1))
    .slice(0, 5);

  const main = document.getElementById("mainContent");
  
  function makeActivityItem(j) {
    const div = document.createElement("div");
    div.className = "activity-item";
    div.addEventListener("click", () => { if(isValidUUID(j.job_id)) selectJob(j.job_id); });
    div.innerHTML = `
      <div class="activity-left">
        <div class="dot ${j.status_dynamic}"></div>
      </div>
      <div class="activity-main">
        <div class="activity-title">${escHtml(j.file_name)}</div>
        <div class="activity-sub">
          ${escHtml(j.job_id)} • ${formatDate(j.submitted_at)}
        </div>
      </div>
      <div class="activity-badges">
        <span class="badge ${j.status_static}">${j.status_static}</span>
        <span class="badge ${j.status_dynamic}">${j.status_dynamic}</span>
      </div>
    `;
    return div;
  }

  main.innerHTML = `
    <!-- HEADER DASHBOARD -->
    <div class="card">
      <div class="card-header">
        <div class="card-title">Threat Overview</div>
        <div class="auto-refresh-badge">
          <div class="pulse"></div> Live
        </div>
      </div>

      <div class="kpi-grid">
        <div class="kpi">
          <div class="kpi-label">Total Jobs</div>
          <div class="kpi-value">${total}</div>
        </div>
        <div class="kpi running">
          <div class="kpi-label">Running</div>
          <div class="kpi-value">${running}</div>
        </div>
        <div class="kpi">
          <div class="kpi-label">Completed</div>
          <div class="kpi-value">${completed}</div>
        </div>
        <div class="kpi danger">
          <div class="kpi-label">Failed</div>
          <div class="kpi-value">${failed}</div>
        </div>
        <div class="kpi good">
          <div class="kpi-label">Success Rate</div>
          <div class="kpi-value">${successRate}%</div>
        </div>
        <div class="kpi danger">
          <div class="kpi-label">Malicious Rate</div>
          <div class="kpi-value" id="maliciousRateValue">--%</div>
        </div>
      </div>
    </div>

    <!-- GRAPHS -->
    <div class="card">
      <div class="card-header">
        <div class="card-title">Analytics</div>
      </div>

      <div class="charts-grid">
        <div>
          <canvas id="statusChart" width="400" height="200" class="chart-canvas"></canvas>
        </div>
        <div>
          <canvas id="trendChart" width="400" height="200" class="chart-canvas"></canvas>
        </div>
      </div>
    </div>

    <!-- RECENT -->
    <div class="card">
      <div class="card-header">
        <div class="card-title">Recent Activity</div>
      </div>
      <div class="activity-feed" id="activityFeed"></div>
    </div>

    <!-- QUICK ACTIONS -->
    <div class="card">
      <div class="card-header">
        <div class="card-title">Quick Actions</div>
      </div>

      <div class="actions-bar">
        <button class="btn btn-primary" id="uploadActionBtn">Upload File</button>
        <button class="btn btn-secondary" id="refreshDataBtn">Refresh Data</button>
      </div>
    </div>
  `;

  const activityFeed = document.getElementById("activityFeed");
  if (recent.length) {
    recent.forEach(j => activityFeed.appendChild(makeActivityItem(j)));
  } else {
    activityFeed.innerHTML = '<div class="empty-jobs">No activity yet</div>';
  }

  drawPipelineChart(running, completed, failed);
  
  // Attendre que les verdicts soient chargés
  await drawVerdictChart(allJobs);
  
  // Mettre à jour le taux de malveillance après chargement
  const maliciousCount = await getMaliciousCount(allJobs);
  const maliciousRate = total ? Math.round((maliciousCount / total) * 100) : 0;
  const rateElement = document.getElementById("maliciousRateValue");
  if (rateElement) rateElement.textContent = `${maliciousRate}%`;

  document.getElementById("uploadActionBtn").addEventListener("click", () => {
    document.getElementById("fileInput").click();
  });
  document.getElementById("refreshDataBtn").addEventListener("click", async () => {
    await loadJobs();
    await renderDashboard();
  });
}

// Fonction utilitaire pour compter les jobs malveillants
async function getMaliciousCount(jobs) {
  let malicious = 0;
  const verdictPromises = jobs.map(async (j) => {
    if (j.status_static === "completed" || j.status_static === "failed") {
      try {
        const r = await apiFetch(`/api/report/${j.job_id}`);
        if (r.ok) {
          const data = await r.json();
          return data.verdict?.malicious === true || data.verdict?.malicious === "true";
        }
      } catch(e) {
        console.debug(e);
      }
    }
    return false;
  });
  
  const results = await Promise.all(verdictPromises);
  results.forEach(isMalicious => {
    if (isMalicious) malicious++;
  });
  return malicious;
}

// ─── BOOT ─────────────────────────────────────────────────
async function start() {
  document.querySelector("header").classList.remove("hidden");
  document.querySelector("header").classList.add("flex-display");
  
  document.querySelector(".layout").classList.remove("hidden");
  document.querySelector(".layout").classList.add("grid-display");
  
  await checkHealth();
  healthInterval = setInterval(checkHealth, 30000);

  await loadJobs();
  await renderDashboard();
}

function startAutoRefresh() {
  // Ne pas démarrer si déjà en cours
  if (dashboardRefreshInterval) return;
  
  dashboardRefreshInterval = setInterval(async () => {
    // Ne pas rafraîchir si déjà en cours
    if (!isRefreshing) {
      isRefreshing = true;
      
      try {
        // Récupérer les jobs actuels
        const r = await fetch("/api/jobs", { credentials: "include" });
        if (r.status === 401) { 
          showLogin("Your session has expired. Please log in again"); 
          isRefreshing = false;
          return; 
        }
        const data = await r.json();
        const newJobs = data.jobs || [];
        
        // Vérifier si des changements ont eu lieu
        let hasChanges = false;
        
        // 1. Vérifier si le nombre de jobs a changé
        if (newJobs.length !== allJobs.length) {
          hasChanges = true;
        } else {
          // 2. Vérifier les changements de statut pour chaque job
          for (let i = 0; i < newJobs.length; i++) {
            const newJob = newJobs[i];
            const oldJob = allJobs.find(j => j.job_id === newJob.job_id);
            
            if (!oldJob) {
              hasChanges = true;
              break;
            }
            
            // Vérifier si les statuts ont changé
            if (oldJob.status_static !== newJob.status_static || 
                oldJob.status_dynamic !== newJob.status_dynamic) {
              hasChanges = true;
              break;
            }
          }
        }
        
        // Si des changements sont détectés, mettre à jour
        if (hasChanges) {
          allJobs = newJobs; // Mettre à jour les jobs
          applyFilterSort(); // Met à jour la sidebar (toujours nécessaire)
          
          // Rafraîchir le dashboard SEULEMENT si on est sur le dashboard
          if (!currentJobId) {
            await renderDashboard();
          }
          
          // Vérifier si tous les jobs sont terminés
          const allFinished = allJobs.every(job => 
            (job.status_static === "completed" || job.status_static === "failed") &&
            (job.status_dynamic === "completed" || job.status_dynamic === "failed")
          );
          
          // Si tous les jobs sont terminés, arrêter l'auto-refresh
          if (allFinished && allJobs.length > 0) {
            console.debug("All jobs are complete, auto-refresh has stopped");
            stopAutoRefresh();
          }
        }
        
      } catch(e) {
        console.error("Auto-refresh error:", e);
      } finally {
        isRefreshing = false;
      }
    }
  }, 3000);
}

function stopAutoRefresh() {
  if (dashboardRefreshInterval) {
    clearInterval(dashboardRefreshInterval);
    dashboardRefreshInterval = null;
  }
}

function goHome() {
  currentJobId = null;
  stopReportPoll();
  renderDashboard();
  applyFilterSort();
  
  // Vérifier s'il y a des jobs en cours avant de redémarrer l'auto-refresh
  const hasRunningJobs = allJobs.some(job => 
    (job.status_static !== "completed" && job.status_static !== "failed") ||
    (job.status_dynamic !== "completed" && job.status_dynamic !== "failed")
  );
  
  // Redémarrer l'auto-refresh seulement s'il y a des jobs en cours
  if (hasRunningJobs && !dashboardRefreshInterval) {
    startAutoRefresh();
  }
}

function initEventListeners() {
    document.getElementById("loginBtn").addEventListener("click", doLogin);
    document.getElementById("logoutBtn").addEventListener("click", doLogout);
    document.getElementById("homeBtn").addEventListener("click", goHome);
    document.getElementById("submitBtn").addEventListener("click", submitFile);
    document.getElementById("fileInput").addEventListener("change", onFileSelected);
    document.getElementById("searchInput").addEventListener("input", onFilter);
    document.getElementById("sortSelect").addEventListener("change", onFilter);
    document.getElementById("loginInput").addEventListener("keydown", function(e) { 
        if (e.key === "Enter") doLogin(); 
    });

    const dropZone = document.getElementById("dropZone");
    dropZone.addEventListener("click", function() { 
        document.getElementById("fileInput").click(); 
    });
    dropZone.addEventListener("dragover", function(e) { 
        e.preventDefault(); 
        dropZone.classList.add("drag"); 
    });
    dropZone.addEventListener("dragleave", function() { 
        dropZone.classList.remove("drag"); 
    });
    dropZone.addEventListener("drop", function(e) {
        e.preventDefault(); 
        dropZone.classList.remove("drag");
        if (e.dataTransfer.files.length) {
            document.getElementById("fileInput").files = e.dataTransfer.files;
            onFileSelected();
        }
    });
}

initEventListeners();
// Vérifier si une session est déjà active au chargement
checkAuth();