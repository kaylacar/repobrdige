import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

export function appPaths(root) {
  return {
    root,
    dataRoot: path.join(root, "data"),
    reposRoot: path.join(root, "data", "repos"),
    mirrorsRoot: path.join(root, "data", "mirrors")
  };
}

export function repoPaths(root, repoId) {
  const base = path.join(appPaths(root).reposRoot, repoId);
  return {
    base,
    stateFile: path.join(base, "state.json"),
    configFile: path.join(base, "config.json"),
    contextDir: path.join(base, "context"),
    draftsDir: path.join(base, "drafts"),
    mirrorDir: path.join(appPaths(root).mirrorsRoot, repoId)
  };
}

export async function ensureDir(dir) {
  await mkdir(dir, { recursive: true });
}

export async function readJson(file, fallback = null) {
  try {
    const content = await readFile(file, "utf8");
    return JSON.parse(content);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return fallback;
    }
    throw error;
  }
}

export async function writeJson(file, value) {
  await ensureDir(path.dirname(file));
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

export function isoNow() {
  return new Date().toISOString();
}

export function slugify(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}
