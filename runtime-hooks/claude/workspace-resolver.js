const fs = require("fs");
const path = require("path");

function normalize(value) {
  return value ? path.resolve(value) : "";
}

function findFromCwd() {
  let candidate = normalize(process.cwd());
  while (candidate) {
    if (fs.existsSync(path.join(candidate, ".assistant"))) {
      return candidate;
    }
    const parent = path.dirname(candidate);
    if (parent === candidate) {
      break;
    }
    candidate = parent;
  }
  return "";
}

function resolveWorkspaceRoot() {
  const environmentRoots = [
    process.env.DEV_HARNESS_WORKSPACE_ROOT,
    process.env.CLAUDE_DEV_HARNESS_WORKSPACE_ROOT,
    process.env.WORKSPACE_ROOT,
  ]
    .filter(Boolean)
    .map(normalize);
  const uniqueRoots = [...new Set(environmentRoots.map((value) => value.toLowerCase()))];
  if (uniqueRoots.length > 1) {
    return "";
  }
  if (environmentRoots.length === 0) {
    return findFromCwd();
  }

  const workspaceRoot = environmentRoots[0];
  return workspaceRoot && fs.existsSync(path.join(workspaceRoot, ".assistant")) ? workspaceRoot : "";
}

function resolveAssistantRoot() {
  const workspaceRoot = resolveWorkspaceRoot();
  return workspaceRoot ? path.join(workspaceRoot, ".assistant") : "";
}

module.exports = { resolveAssistantRoot, resolveWorkspaceRoot };
