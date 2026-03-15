import path from "node:path";
import { readdir } from "node:fs/promises";
import { isoNow, readJson, writeJson } from "./storage.js";

export async function supersedeOpenDrafts(draftsDir, latestCommit) {
  const existing = await listDrafts(draftsDir);
  const touched = [];
  for (const draft of existing) {
    if ((draft.status === "draft" || draft.status === "ready") && draft.basisCommit !== latestCommit) {
      draft.status = "superseded";
      draft.supersededAt = isoNow();
      await writeJson(path.join(draftsDir, `${draft.id}.json`), draft);
      touched.push(draft);
    }
  }
  return touched;
}

export async function writeDraft(draftsDir, draft) {
  await writeJson(path.join(draftsDir, `${draft.id}.json`), draft);
}

export async function listDrafts(draftsDir) {
  try {
    const files = (await readdir(draftsDir)).filter((file) => file.endsWith(".json")).sort();
    const drafts = [];
    for (const file of files) {
      const draft = await readJson(path.join(draftsDir, file));
      if (draft) {
        drafts.push(draft);
      }
    }
    return drafts.sort((a, b) => (a.generatedAt < b.generatedAt ? 1 : -1));
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

export function createDraft({ repoId, repoLabel, basisCommit, contextPack, focus }) {
  const shortCommit = basisCommit.slice(0, 12);
  const changed = contextPack.deltaSummary.changedFiles.slice(0, 5);
  const subjects = contextPack.deltaSummary.commitSubjects.slice(0, 3);
  const title = `${repoLabel}: current upstream delta at ${shortCommit}`;
  const summary = [
    `I mirrored the latest upstream state for ${repoLabel} and reviewed the delta at ${shortCommit}.`,
    `This draft is based on ${contextPack.deltaSummary.commitCount || 1} recent commit(s) and ${contextPack.deltaSummary.changedFileCount} changed file(s).`,
    focus ? `Tracking focus: ${focus}.` : "This is a general public-repo observation draft."
  ].join(" ");

  const evidence = [
    changed.length > 0 ? `Changed files: ${changed.join(", ")}` : "Changed files: none",
    subjects.length > 0 ? `Recent commit subjects: ${subjects.join(" | ")}` : "Recent commit subjects: unavailable",
    `README snapshot: ${truncate(contextPack.repoSummary, 220)}`
  ];

  const proposalOrQuestion = focus
    ? `I am tracking this repo for ${focus}. If useful, I can turn this delta into a tighter patch or question scoped to the current upstream state.`
    : "If useful, I can follow up with a tighter patch, issue, or question scoped to the current upstream state rather than a stale snapshot.";

  return {
    id: `${basisCommit.slice(0, 12)}-${Date.now()}`,
    repoId,
    basisCommit,
    title,
    summary,
    evidence,
    proposalOrQuestion,
    references: changed.map((file) => ({ type: "file", value: file })),
    status: "ready",
    generatedAt: isoNow()
  };
}

function truncate(text, max) {
  return text.length <= max ? text : `${text.slice(0, max - 3)}...`;
}
