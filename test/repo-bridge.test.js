import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { ensureTrackedRepo, getRepoStatus, syncTrackedRepo } from "../src/tracker.js";

test("initial sync creates mirror, context pack, and ready draft", async () => {
  const fixture = await createFixtureRepo();
  const appRoot = await mkdtemp(path.join(os.tmpdir(), "repobrdige-app-"));

  await ensureTrackedRepo(appRoot, {
    id: "llm-c",
    upstreamUrl: fixture.remotePath,
    focus: "upstream changes relevant to downstream integrations"
  });

  const result = await syncTrackedRepo(appRoot, "llm-c");

  assert.equal(result.state.status, "synced");
  assert.equal(result.contextPack.deltaSummary.meaningful, true);
  assert.equal(result.draft.status, "ready");
  assert.equal(result.drafts.length, 1);
});

test("second sync with no upstream change does not create a duplicate draft", async () => {
  const fixture = await createFixtureRepo();
  const appRoot = await mkdtemp(path.join(os.tmpdir(), "repobrdige-app-"));

  await ensureTrackedRepo(appRoot, { id: "llm-c", upstreamUrl: fixture.remotePath });
  await syncTrackedRepo(appRoot, "llm-c");
  const second = await syncTrackedRepo(appRoot, "llm-c");

  assert.equal(second.contextPack.deltaSummary.meaningful, false);
  assert.equal(second.draft, null);

  const status = await getRepoStatus(appRoot, "llm-c");
  assert.equal(status.drafts.length, 1);
  assert.equal(status.drafts[0].status, "ready");
});

test("new upstream commit supersedes the prior ready draft and creates a fresh one", async () => {
  const fixture = await createFixtureRepo();
  const appRoot = await mkdtemp(path.join(os.tmpdir(), "repobrdige-app-"));

  await ensureTrackedRepo(appRoot, { id: "llm-c", upstreamUrl: fixture.remotePath });
  await syncTrackedRepo(appRoot, "llm-c");

  await addCommit(fixture.workPath, "main.c", '\nputs("v2");\n', "Update runtime behavior");

  const second = await syncTrackedRepo(appRoot, "llm-c");
  const status = await getRepoStatus(appRoot, "llm-c");

  assert.equal(second.contextPack.deltaSummary.meaningful, true);
  assert.equal(status.drafts.length, 2);
  assert.equal(status.drafts[0].status, "ready");
  assert.equal(status.drafts[1].status, "superseded");

  const newestDraftFile = path.join(appRoot, "data", "repos", "llm-c", "drafts", `${status.drafts[0].id}.json`);
  const newestDraft = JSON.parse(await readFile(newestDraftFile, "utf8"));
  assert.match(newestDraft.summary, /latest upstream state/i);
});

async function createFixtureRepo() {
  const root = await mkdtemp(path.join(os.tmpdir(), "repobrdige-fixture-"));
  const remotePath = path.join(root, "remote.git");
  const workPath = path.join(root, "work");

  runGit(["init", "--bare", remotePath], root);
  runGit(["clone", remotePath, workPath], root);
  runGit(["config", "user.email", "repobrdige@example.com"], workPath);
  runGit(["config", "user.name", "Repo Bridge"], workPath);

  await writeText(path.join(workPath, "README.md"), "# llm.c\n\nA compact language model runtime.\n");
  await writeText(path.join(workPath, "main.c"), "int main(void) { return 0; }\n");

  runGit(["add", "README.md", "main.c"], workPath);
  runGit(["commit", "-m", "Initial import"], workPath);
  runGit(["push", "origin", "HEAD"], workPath);

  return { root, remotePath, workPath };
}

async function addCommit(workPath, relativeFile, text, message) {
  const fullPath = path.join(workPath, relativeFile);
  const existing = await readFile(fullPath, "utf8");
  await writeText(fullPath, `${existing}${text}`);
  runGit(["add", relativeFile], workPath);
  runGit(["commit", "-m", message], workPath);
  runGit(["push", "origin", "HEAD"], workPath);
}

async function writeText(file, content) {
  const { writeFile } = await import("node:fs/promises");
  await writeFile(file, content, "utf8");
}

function runGit(args, cwd) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || "").trim());
  }
  return result.stdout.trim();
}
