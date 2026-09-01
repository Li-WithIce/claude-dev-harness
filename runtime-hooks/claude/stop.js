// Read-only v2 recovery projection. Never parse a legacy pointer, flow, or plan.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { resolveWorkspaceRoot } = require("./workspace-resolver");

function main() {
  const workspace = resolveWorkspaceRoot();
  if (!workspace) return {};
  const entry = path.join(workspace, ".assistant", "entry", "task.ps1");
  if (!fs.existsSync(entry)) {
    return { systemMessage: "v2 recovery unavailable: installed task entry is missing; no legacy fallback or runtime writes." };
  }
  const output = execFileSync("pwsh", [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-File", entry,
    "status", "-AsJson",
  ], { encoding: "utf8", windowsHide: true, timeout: 10000,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, HARNESS_PROTOCOL: "v2" } });
  const recovery = JSON.parse(output);
  if (recovery.operation !== "recovery-index" || !Array.isArray(recovery.tasks) ||
      !Object.prototype.hasOwnProperty.call(recovery, "current")) {
    throw new Error("invalid recovery projection");
  }
  if (!recovery.current) return {};
  return { systemMessage: "The v2 recovery index has an active current task. This is diagnostic only and does not authorize runtime writes; read-only work may stop without refresh." };
}

try {
  process.stdout.write(JSON.stringify(main()));
} catch {
  process.stdout.write(JSON.stringify({ systemMessage: "v2 recovery unavailable in stop.js; no legacy fallback or runtime writes." }));
}
