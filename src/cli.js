#!/usr/bin/env node
import path from "node:path";
import { ensureTrackedRepo, getRepoStatus, syncTrackedRepo } from "./tracker.js";

const root = path.resolve(process.cwd());
const [, , command, ...args] = process.argv;

async function main() {
  if (command === "track") {
    const options = parseArgs(args);
    requireValue(options.url, "--url is required");
    const result = await ensureTrackedRepo(root, {
      id: options.id,
      upstreamUrl: options.url,
      defaultBranch: options.branch,
      focus: options.focus
    });
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  if (command === "sync") {
    const options = parseArgs(args);
    requireValue(options.id, "--id is required");
    const result = await syncTrackedRepo(root, options.id);
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  if (command === "status") {
    const options = parseArgs(args);
    requireValue(options.id, "--id is required");
    const result = await getRepoStatus(root, options.id);
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  printUsage();
  process.exitCode = 1;
}

function parseArgs(values) {
  const options = {};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    const value = values[index + 1];
    if (!key.startsWith("--")) {
      continue;
    }
    options[key.slice(2)] = value;
    index += 1;
  }
  return options;
}

function requireValue(value, message) {
  if (!value) {
    throw new Error(message);
  }
}

function printUsage() {
  console.error("Usage:");
  console.error("  node src/cli.js track --id llm-c --url https://github.com/karpathy/llm.c.git [--branch master] [--focus \"integration drift\"]");
  console.error("  node src/cli.js sync --id llm-c");
  console.error("  node src/cli.js status --id llm-c");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
