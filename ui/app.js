const state = {
  repos: [],
  selectedRepoId: null
};

const repoList = document.getElementById("repoList");
const repoCount = document.getElementById("repoCount");
const heroTitle = document.getElementById("heroTitle");
const heroSubtitle = document.getElementById("heroSubtitle");
const repoStats = document.getElementById("repoStats");
const draftPanel = document.getElementById("draftPanel");
const watchPanel = document.getElementById("watchPanel");
const currentTarget = document.getElementById("currentTarget");
const banner = document.getElementById("banner");
const syncButton = document.getElementById("syncButton");
const refreshButton = document.getElementById("refreshButton");
const trackForm = document.getElementById("trackForm");
const trackUrl = document.getElementById("trackUrl");
const trackId = document.getElementById("trackId");
const trackFocus = document.getElementById("trackFocus");

syncButton.addEventListener("click", async () => {
  if (!state.selectedRepoId) {
    return;
  }

  setBanner(`Syncing ${state.selectedRepoId}...`);
  syncButton.disabled = true;
  try {
    await requestJson(`/repos/${encodeURIComponent(state.selectedRepoId)}/sync`, { method: "POST" });
    await loadAll();
    setBanner(`Synced ${state.selectedRepoId}.`);
  } catch (error) {
    setBanner(error.message, true);
  } finally {
    syncButton.disabled = false;
  }
});

refreshButton.addEventListener("click", async () => {
  setBanner("Refreshing view...");
  try {
    await loadAll();
    setBanner("View refreshed.");
  } catch (error) {
    setBanner(error.message, true);
  }
});

trackForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const url = trackUrl.value.trim();
  const id = trackId.value.trim();
  const focus = trackFocus.value.trim();

  if (!url) {
    setBanner("Repo URL is required.", true);
    return;
  }

  setBanner("Tracking repo...");
  try {
    const response = await requestJson("/repos", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url,
        id: id || undefined,
        focus: focus || undefined
      })
    });

    state.selectedRepoId = response.repo.id;
    trackForm.reset();
    await loadAll();
    setBanner(`Tracked ${response.repo.id}.`);
  } catch (error) {
    setBanner(error.message, true);
  }
});

await loadAll();

async function loadAll() {
  const [reposResponse, watchResponse] = await Promise.all([
    requestJson("/repos"),
    requestJson("/watch-status").catch(() => ({ watch: null }))
  ]);

  state.repos = reposResponse.repos ?? [];
  if (!state.selectedRepoId || !state.repos.some((repo) => repo.id === state.selectedRepoId)) {
    state.selectedRepoId = state.repos[0]?.id ?? null;
  }

  renderRepoList();
  renderSelectedRepo();
  renderWatch(watchResponse.watch);
}

function renderRepoList() {
  repoCount.textContent = `${state.repos.length} tracked repo${state.repos.length === 1 ? "" : "s"}`;
  repoList.innerHTML = "";

  for (const repo of state.repos) {
    const button = document.createElement("button");
    button.className = `repo-card${repo.id === state.selectedRepoId ? " active" : ""}`;
    button.innerHTML = `
      <h2>${escapeHtml(repo.id)}</h2>
      <div class="pill ${repo.sync.freshness === "degraded" ? "degraded" : ""}">${escapeHtml(repo.sync.freshness)}</div>
      <p class="small">${escapeHtml(repo.upstreamUrl)}</p>
      <p class="small">Drafts: ${repo.draftCount}</p>
    `;
    button.addEventListener("click", () => {
      state.selectedRepoId = repo.id;
      renderRepoList();
      renderSelectedRepo();
    });
    repoList.appendChild(button);
  }
}

function renderSelectedRepo() {
  const repo = state.repos.find((entry) => entry.id === state.selectedRepoId);
  if (!repo) {
    heroTitle.textContent = "No tracked repos";
    heroSubtitle.textContent = "Track a repo first, then this app shell will show current sync, draft, and watch data.";
    repoStats.innerHTML = "";
    draftPanel.textContent = "No draft available.";
    currentTarget.textContent = "No repo selected";
    syncButton.disabled = true;
    return;
  }

  heroTitle.textContent = repo.id;
  heroSubtitle.textContent = repo.upstreamUrl;
  currentTarget.textContent = repo.upstreamUrl;
  syncButton.disabled = false;

  repoStats.innerHTML = [
    stat("Status", repo.sync.status),
    stat("Freshness", repo.sync.freshness),
    stat("Branch", repo.defaultBranch || "unknown"),
    stat("Draft Count", String(repo.draftCount)),
    stat("Last Sync", repo.sync.lastSyncAt || "never"),
    stat("Last Commit", repo.sync.lastSyncedCommit || "n/a")
  ].join("");

  if (repo.latestDraft) {
    draftPanel.innerHTML = `
      <p class="draft-title">${escapeHtml(repo.latestDraft.title)}</p>
      <div class="detail-list">
        <div class="detail-row"><span class="small">Status</span><strong>${escapeHtml(repo.latestDraft.status)}</strong></div>
        <div class="detail-row"><span class="small">Basis Commit</span><code>${escapeHtml(repo.latestDraft.basisCommit)}</code></div>
        <div class="detail-row"><span class="small">Generated</span><strong>${escapeHtml(repo.latestDraft.generatedAt)}</strong></div>
      </div>
    `;
  } else {
    draftPanel.textContent = "No draft available.";
  }
}

function renderWatch(watch) {
  if (!watch) {
    watchPanel.textContent = "No watch run recorded yet.";
    return;
  }

  const rows = (watch.results ?? [])
    .map((result) => `
      <div class="watch-row">
        <span class="small">${escapeHtml(result.repoId)}</span>
        <strong>${escapeHtml(result.status)}</strong>
      </div>
    `)
    .join("");

  watchPanel.innerHTML = `
    <div class="detail-list">
      <div class="detail-row"><span class="small">Run</span><code>${escapeHtml(watch.runId)}</code></div>
      <div class="detail-row"><span class="small">Iteration</span><strong>${escapeHtml(String(watch.iteration))}</strong></div>
      <div class="detail-row"><span class="small">Interval</span><strong>${escapeHtml(String(watch.intervalSeconds))}s</strong></div>
    </div>
    <div class="watch-list">${rows || '<div class="small">No repo results.</div>'}</div>
  `;
}

async function requestJson(url, options) {
  const response = await fetch(url, options);
  const body = await response.text();
  const data = body ? JSON.parse(body) : null;
  if (!response.ok) {
    throw new Error(data?.error || `Request failed: ${response.status}`);
  }
  return data;
}

function setBanner(message, isError = false) {
  banner.hidden = false;
  banner.textContent = message;
  banner.className = isError ? "banner error" : "banner";
}

function stat(label, value) {
  return `
    <div>
      <div class="stat-label">${escapeHtml(label)}</div>
      <div class="stat-value">${escapeHtml(value)}</div>
    </div>
  `;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
