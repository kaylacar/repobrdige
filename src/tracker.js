import path from "node:path";
import { mkdir } from "node:fs/promises";
import { buildContextPack } from "./context.js";
import { createDraft, supersedeOpenDrafts, listDrafts, writeDraft } from "./drafts.js";
import { repoExists, runGit } from "./git.js";
import { appPaths, ensureDir, isoNow, readJson, repoPaths, slugify, writeJson } from "./storage.js";

export async function ensureTrackedRepo(root, input) {
  const repoId = input.id || slugify(input.upstreamUrl);
  const paths = repoPaths(root, repoId);

  await ensureDir(appPaths(root).reposRoot);
  await ensureDir(appPaths(root).mirrorsRoot);
  await ensureDir(paths.base);
  await ensureDir(paths.contextDir);
  await ensureDir(paths.draftsDir);

  const config = {
    id: repoId,
    upstreamUrl: input.upstreamUrl,
    defaultBranch: input.defaultBranch || null,
    focus: input.focus || null,
    createdAt: isoNow(),
    updatedAt: isoNow()
  };

  const previous = await readJson(paths.configFile);
  await writeJson(paths.configFile, previous ? { ...previous, ...config, createdAt: previous.createdAt } : config);

  return { repoId, paths, config: await readJson(paths.configFile) };
}

export async function syncTrackedRepo(root, repoId) {
  const paths = repoPaths(root, repoId);
  const config = await readJson(paths.configFile);
  if (!config) {
    throw new Error(`Unknown repo id: ${repoId}`);
  }

  await mkdir(path.dirname(paths.mirrorDir), { recursive: true });

  if (!repoExists(paths.mirrorDir)) {
    runGit(["clone", config.upstreamUrl, paths.mirrorDir]);
  } else {
    runGit(["fetch", "--all", "--prune"], { cwd: paths.mirrorDir });
  }

  const defaultBranch = config.defaultBranch || detectCurrentBranch(paths.mirrorDir);
  ensureLocalBranch(paths.mirrorDir, defaultBranch);
  runGit(["pull", "--ff-only", "origin", defaultBranch], { cwd: paths.mirrorDir });

  const previousState = await readJson(paths.stateFile, {});
  const lastSyncedCommit = runGit(["rev-parse", "HEAD"], { cwd: paths.mirrorDir });
  const contextPack = await buildContextPack({
    mirrorDir: paths.mirrorDir,
    repoId,
    basisCommit: lastSyncedCommit,
    previousCommit: previousState.lastAnalyzedCommit || null
  });

  const state = {
    id: repoId,
    upstreamUrl: config.upstreamUrl,
    defaultBranch,
    localPath: paths.mirrorDir,
    lastSyncedCommit,
    lastAnalyzedCommit: previousState.lastAnalyzedCommit || null,
    lastSyncAt: isoNow(),
    status: "synced"
  };

  await writeJson(paths.stateFile, state);
  await writeJson(path.join(paths.contextDir, `${lastSyncedCommit}.json`), contextPack);

  let draft = null;
  if (contextPack.deltaSummary.meaningful) {
    await supersedeOpenDrafts(paths.draftsDir, lastSyncedCommit);
    draft = createDraft({
      repoId,
      repoLabel: labelFromUrl(config.upstreamUrl),
      basisCommit: lastSyncedCommit,
      contextPack,
      focus: config.focus
    });
    await writeDraft(paths.draftsDir, draft);
  }

  state.lastAnalyzedCommit = lastSyncedCommit;
  state.lastAnalyzedAt = isoNow();
  await writeJson(paths.stateFile, state);

  return {
    repoId,
    state,
    contextPack,
    draft,
    drafts: await listDrafts(paths.draftsDir)
  };
}

export async function getRepoStatus(root, repoId) {
  const paths = repoPaths(root, repoId);
  return {
    config: await readJson(paths.configFile),
    state: await readJson(paths.stateFile),
    drafts: await listDrafts(paths.draftsDir)
  };
}

function detectCurrentBranch(mirrorDir) {
  const symbolic = runGit(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], { cwd: mirrorDir });
  return symbolic.replace("origin/", "");
}

function ensureLocalBranch(mirrorDir, branch) {
  const localBranches = runGit(["branch", "--list", branch], { cwd: mirrorDir });
  if (!localBranches) {
    runGit(["switch", "-c", branch, "--track", `origin/${branch}`], { cwd: mirrorDir });
  } else {
    runGit(["switch", branch], { cwd: mirrorDir });
  }
}

function labelFromUrl(url) {
  return url.replace(/\.git$/i, "").split("/").slice(-2).join("/");
}
