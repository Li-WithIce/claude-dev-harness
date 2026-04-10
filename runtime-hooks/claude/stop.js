// Shared-memory stop hook.
// Warns when either the shared pointer or current-flow still looks active.
// The hook is self-contained because tests render it into a temporary directory.

const fs = require("fs");
const path = require("path");

const assistantRoot = "{VAULT_PATH}";
const currentTaskPath = path.join(assistantRoot, "运行时", "当前任务.md");
const currentFlowPath = path.join(assistantRoot, "orchestration", "current-flow.md");
const activeStages = new Set(["PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST"]);

/**
 * Writes a JSON payload to stdout.
 * @param {object} payload The hook response payload.
 * @returns {void}
 */
function writeJson(payload) {
  process.stdout.write(JSON.stringify(payload));
}

/**
 * Reads a file as UTF-8 and returns an empty string when it is missing.
 * @param {string} filePath Absolute file path.
 * @returns {string}
 */
function safeRead(filePath) {
  if (!fs.existsSync(filePath)) {
    return "";
  }
  return fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
}

/**
 * Reads a single value from a Markdown key-value table.
 * @param {string} content Markdown file content.
 * @param {string} key Table key to match.
 * @returns {string}
 */
function parseTableValue(content, key) {
  const pattern = new RegExp(`^\\|\\s*${escapeRegExp(key)}\\s*\\|\\s*(.+?)\\s*\\|$`, "m");
  const match = content.match(pattern);
  return match ? stripTicks(match[1].trim()) : "";
}

/**
 * Reads a simple YAML/frontmatter field.
 * @param {string} content File content.
 * @param {string} key YAML key to match.
 * @returns {string}
 */
function parseYamlValue(content, key) {
  const pattern = new RegExp(`^${escapeRegExp(key)}:\\s*(.+)$`, "m");
  const match = content.match(pattern);
  if (!match) {
    return "";
  }
  return stripTicks(match[1].trim());
}

/**
 * Escapes a string for use in a regular expression.
 * @param {string} value Raw string.
 * @returns {string}
 */
function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Removes Markdown inline-code wrappers.
 * @param {string} value Raw field value.
 * @returns {string}
 */
function stripTicks(value) {
  const text = String(value || "").trim();
  if (text.startsWith("`") && text.endsWith("`")) {
    return text.slice(1, -1);
  }
  return text;
}

/**
 * Returns true when a task or status value means idle.
 * @param {string} value Field value.
 * @returns {boolean}
 */
function isIdle(value) {
  const normalized = stripTicks(value).trim().toLowerCase();
  return !normalized || ["none", "无", "空闲", "idle", "done"].includes(normalized);
}

/**
 * Resolves the current pointer snapshot.
 * @returns {{taskId: string, taskName: string, status: string}}
 */
function getPointerState() {
  const content = safeRead(currentTaskPath);
  return {
    taskId: parseTableValue(content, "task_id") || parseYamlValue(content, "task_id"),
    taskName: parseTableValue(content, "任务"),
    status: parseTableValue(content, "状态"),
  };
}

/**
 * Resolves the current-flow snapshot.
 * @returns {{taskId: string, taskName: string, status: string, currentDoc: string}}
 */
function getFlowState() {
  const content = safeRead(currentFlowPath);
  return {
    taskId: parseYamlValue(content, "task_id"),
    taskName: parseYamlValue(content, "task_name"),
    status: parseYamlValue(content, "stage"),
    currentDoc: parseYamlValue(content, "current_doc"),
  };
}

/**
 * Returns whether the flow snapshot is still active.
 * @param {{taskId: string, status: string}} flowState Parsed flow state.
 * @returns {boolean}
 */
function isActiveFlow(flowState) {
  return !isIdle(flowState.taskId) && activeStages.has(flowState.status);
}

/**
 * Returns whether the shared pointer is still active.
 * @param {{taskId: string, taskName: string, status: string}} pointerState Parsed pointer state.
 * @returns {boolean}
 */
function isActivePointer(pointerState) {
  return !isIdle(pointerState.taskId) && !isIdle(pointerState.taskName) && activeStages.has(pointerState.status);
}

/**
 * Entry point for the stop hook.
 * @returns {void}
 */
function main() {
  const pointerState = getPointerState();
  const flowState = getFlowState();

  if (!isActivePointer(pointerState) && !isActiveFlow(flowState)) {
    writeJson({});
    return;
  }

  if (!isActivePointer(pointerState) && isActiveFlow(flowState)) {
    writeJson({
      systemMessage: `Shared pointer is idle, but current-flow is still active (status=${flowState.status}, source=current-flow, current_doc=${flowState.currentDoc}).`,
    });
    return;
  }

  writeJson({
    systemMessage: `Shared pointer still looks active (status=${pointerState.status}, task_id=${pointerState.taskId}). Refresh current-task or last-session before stopping.`,
  });
}

try {
  main();
} catch {
  writeJson({ systemMessage: "memory hook error in stop.js" });
}
