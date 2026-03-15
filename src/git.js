import { spawnSync } from "node:child_process";

export function runGit(args, options = {}) {
  const result = spawnSync("git", args, {
    cwd: options.cwd,
    encoding: "utf8",
    env: { ...process.env, ...options.env }
  });

  if (result.status !== 0) {
    const joined = ["git", ...args].join(" ");
    const stderr = (result.stderr || "").trim();
    throw new Error(stderr ? `${joined} failed: ${stderr}` : `${joined} failed`);
  }

  return (result.stdout || "").trim();
}

export function repoExists(path) {
  try {
    runGit(["rev-parse", "--is-inside-work-tree"], { cwd: path });
    return true;
  } catch {
    return false;
  }
}
