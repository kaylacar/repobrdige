import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { runGit } from "./git.js";
import { isoNow } from "./storage.js";

const TRIVIAL_PATTERNS = [
  /^\.gitignore$/i,
  /^license/i,
  /^.*\.lock$/i,
  /^\.github\//i,
  /^.*\.(png|jpg|jpeg|gif|svg)$/i
];

const PRIORITY_FILES = [
  "README.md",
  "README",
  "package.json",
  "Cargo.toml",
  "pyproject.toml",
  "Makefile",
  "CMakeLists.txt",
  "go.mod"
];

export function detectMeaningfulDelta(changedFiles, lastAnalyzedCommit) {
  if (!lastAnalyzedCommit) {
    return { meaningful: true, reason: "initial-analysis" };
  }

  if (changedFiles.length === 0) {
    return { meaningful: false, reason: "no-change" };
  }

  const substantive = changedFiles.filter(
    (file) => !TRIVIAL_PATTERNS.some((pattern) => pattern.test(file))
  );

  if (substantive.length === 0) {
    return { meaningful: false, reason: "trivial-change-only" };
  }

  return { meaningful: true, reason: "substantive-files-changed", substantiveFiles: substantive };
}

export async function buildContextPack({ mirrorDir, repoId, basisCommit, previousCommit }) {
  const readmePreview = await readReadmePreview(mirrorDir);
  const keyFiles = await collectKeyFiles(mirrorDir);
  const recentCommits = readRecentCommits(mirrorDir, 5);
  const changedFiles = previousCommit
    ? readLines(runGit(["diff", "--name-only", `${previousCommit}..${basisCommit}`], { cwd: mirrorDir }))
    : keyFiles.map((entry) => entry.path);
  const commitSubjects = previousCommit
    ? readLines(runGit(["log", "--pretty=format:%s", `${previousCommit}..${basisCommit}`], { cwd: mirrorDir }))
    : recentCommits.map((entry) => entry.subject);

  const delta = detectMeaningfulDelta(changedFiles, previousCommit);

  return {
    repoId,
    basisCommit,
    previousCommit: previousCommit || null,
    generatedAt: isoNow(),
    repoSummary: readmePreview,
    keyFiles,
    recentCommits,
    deltaSummary: {
      changedFiles,
      commitSubjects,
      changedFileCount: changedFiles.length,
      commitCount: commitSubjects.length,
      meaningful: delta.meaningful,
      reason: delta.reason
    }
  };
}

async function readReadmePreview(mirrorDir) {
  for (const candidate of ["README.md", "README", "readme.md"]) {
    try {
      const content = await readFile(path.join(mirrorDir, candidate), "utf8");
      const lines = content
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean)
        .slice(0, 8);
      if (lines.length > 0) {
        return lines.join(" ");
      }
    } catch (error) {
      if (error && error.code !== "ENOENT") {
        throw error;
      }
    }
  }

  return "No README preview available.";
}

async function collectKeyFiles(mirrorDir) {
  const entries = await readdir(mirrorDir, { withFileTypes: true });
  const files = entries.filter((entry) => entry.isFile()).map((entry) => entry.name);
  const ordered = [
    ...PRIORITY_FILES.filter((file) => files.includes(file)),
    ...files.filter((file) => !PRIORITY_FILES.includes(file)).sort().slice(0, 5)
  ].slice(0, 8);

  const result = [];
  for (const file of ordered) {
    try {
      const content = await readFile(path.join(mirrorDir, file), "utf8");
      const preview = content
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean)
        .slice(0, 3)
        .join(" ");
      result.push({ path: file, preview: preview || "(empty file)" });
    } catch {
      result.push({ path: file, preview: "(binary or unreadable preview)" });
    }
  }

  return result;
}

function readRecentCommits(mirrorDir, limit) {
  const output = runGit(
    ["log", `-n${limit}`, "--pretty=format:%H%x09%ad%x09%s", "--date=short"],
    { cwd: mirrorDir }
  );
  return readLines(output).map((line) => {
    const [sha, date, subject] = line.split("\t");
    return { sha, date, subject };
  });
}

function readLines(text) {
  if (!text) {
    return [];
  }
  return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
}
