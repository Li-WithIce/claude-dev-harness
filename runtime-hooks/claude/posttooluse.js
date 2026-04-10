// Shared-memory posttooluse hook.
// Rebuilds recovery-index after tool writes and records inbox fallback when another writer holds the runtime lock.
// The hook is self-contained because tests render it into a temporary directory.

const fs = require("fs");
const path = require("path");

const assistantRoot = "{VAULT_PATH}";
const runtimeDir = path.join(assistantRoot, "运行时");
const currentTaskPath = path.join(runtimeDir, "当前任务.md");
const currentFlowPath = path.join(assistantRoot, "orchestration", "current-flow.md");
const recoveryIndexPath = path.join(runtimeDir, "恢复索引.md");
const inboxPath = path.join(runtimeDir, "收件箱.md");
const lockPath = path.join(runtimeDir, "runtime.lock.json");
const activeStages = new Set(["PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST"]);
const placeholderSummary = "当前暂无收件箱事项";

/**
 * Writes a JSON payload to stdout.
 * @param {object} payload The hook response payload.
 * @returns {void}
 */
function writeJson(payload) {
  process.stdout.write(JSON.stringify(payload));
}

/**
 * Reads stdin as UTF-8.
 * @returns {string}
 */
function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
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
 * Returns the current local timestamp in the harness format.
 * @returns {string}
 */
function getTimestamp() {
  const now = new Date();
  const parts = new Intl.DateTimeFormat("sv-SE", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const values = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day} ${values.hour}:${values.minute}:${values.second}`;
}

/**
 * Returns today's date in yyyy-MM-dd format.
 * @returns {string}
 */
function getToday() {
  return getTimestamp().slice(0, 10);
}

/**
 * Ensures the runtime directory exists.
 * @returns {void}
 */
function ensureRuntimeDir() {
  fs.mkdirSync(runtimeDir, { recursive: true });
}

/**
 * Escapes a value for a Markdown table cell.
 * @param {string} value Raw cell content.
 * @returns {string}
 */
function escapeCell(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "-";
  }
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n/g, " <br> ").replace(/\|/g, "｜");
}

/**
 * Parses the current pointer and flow into one active task snapshot.
 * @returns {{taskId: string, taskName: string, status: string, currentDoc: string, next: string}}
 */
function resolveTaskState() {
  const currentTaskContent = safeRead(currentTaskPath);
  const flowContent = safeRead(currentFlowPath);

  const pointerTaskId = parseTableValue(currentTaskContent, "task_id") || parseYamlValue(currentTaskContent, "task_id");
  const pointerTaskName = parseTableValue(currentTaskContent, "任务");
  const pointerStatus = parseTableValue(currentTaskContent, "状态");
  const pointerCurrentDoc = parseTableValue(currentTaskContent, "当前文档");
  const pointerNext = parseTableValue(currentTaskContent, "下一步");

  const flowTaskId = parseYamlValue(flowContent, "task_id");
  const flowTaskName = parseYamlValue(flowContent, "task_name");
  const flowStatus = parseYamlValue(flowContent, "stage");
  const flowCurrentDoc = parseYamlValue(flowContent, "current_doc");
  const flowNext = parseYamlValue(flowContent, "next");

  if (!isIdle(flowTaskId) && activeStages.has(flowStatus) && (isIdle(pointerTaskId) || isIdle(pointerStatus))) {
    return {
      taskId: flowTaskId,
      taskName: flowTaskName || pointerTaskName || "未命名任务",
      status: flowStatus,
      currentDoc: flowCurrentDoc,
      next: flowNext || pointerNext || "continue",
    };
  }

  return {
    taskId: pointerTaskId || flowTaskId || "none",
    taskName: pointerTaskName || flowTaskName || "无",
    status: pointerStatus || flowStatus || "空闲",
    currentDoc: pointerCurrentDoc || flowCurrentDoc || "none",
    next: pointerNext || flowNext || "等待新任务",
  };
}

/**
 * Builds the recovery-index Markdown document.
 * @param {{taskId: string, taskName: string, status: string, currentDoc: string, next: string}} taskState Active task snapshot.
 * @returns {string}
 */
function buildRecoveryIndex(taskState) {
  return [
    "---",
    "tags: [运行时, 恢复索引]",
    `updated: ${getTimestamp()}`,
    "---",
    "",
    "# 恢复索引",
    "",
    "## 当前主任务",
    `- task_id: \`${taskState.taskId}\``,
    `- 任务: ${taskState.taskName}`,
    `- 状态: ${taskState.status}`,
    `- 当前文档: ${taskState.currentDoc}`,
    `- 下一步: ${taskState.next}`,
    "",
    "## 中断任务 Top 3",
    "- 无",
    "",
    "## 回退读取",
    "- 详细不足时，再读：`当前任务.md -> 中断任务.md -> 上次会话.md`",
  ].join("\n");
}

/**
 * Parses the inbox data rows.
 * @param {string} content Inbox file content.
 * @returns {Array<{createdAt: string, source: string, taskId: string, type: string, status: string, summary: string, payload: string}>}
 */
function parseInboxRows(content) {
  return content
    .split(/\r?\n/)
    .filter((line) => line.startsWith("|"))
    .map((line) => line.split("|").slice(1, -1).map((cell) => cell.trim()))
    .filter((cells) => cells.length >= 7 && cells[0] !== "created_at" && !/^[-:]+$/.test(cells[0]))
    .map((cells) => ({
      createdAt: cells[0],
      source: cells[1],
      taskId: cells[2],
      type: cells[3],
      status: cells[4],
      summary: cells[5],
      payload: cells[6],
    }));
}

/**
 * Writes a canonical inbox file.
 * @param {Array<{createdAt: string, source: string, taskId: string, type: string, status: string, summary: string, payload: string}>} rows Inbox rows.
 * @returns {void}
 */
function writeInbox(rows) {
  const effectiveRows = rows.length
    ? rows
    : [
        {
          createdAt: "-",
          source: "-",
          taskId: "-",
          type: "-",
          status: "cleared",
          summary: placeholderSummary,
          payload: "-",
        },
      ];

  const rowLines = effectiveRows.map(
    (row) =>
      `| ${escapeCell(row.createdAt)} | ${escapeCell(row.source)} | ${escapeCell(row.taskId)} | ${escapeCell(row.type)} | ${escapeCell(row.status)} | ${escapeCell(row.summary)} | ${escapeCell(row.payload)} |`,
  );

  const content = [
    "---",
    "tags: [runtime, inbox]",
    `created: ${getToday()}`,
    `updated: ${getTimestamp()}`,
    "schema_version: runtime-inbox/v1.0",
    "---",
    "",
    "# Runtime Inbox",
    "",
    "| created_at | source | task_id | type | status | summary | payload |",
    "|------------|--------|---------|------|--------|---------|---------|",
    ...rowLines,
    "",
  ].join("\n");

  fs.writeFileSync(inboxPath, content, "utf8");
}

/**
 * Appends a lock-blocked inbox entry.
 * @param {string} writerName Lock owner.
 * @param {string} taskId Task id held by the other writer.
 * @returns {void}
 */
function appendLockBlockedInbox(writerName, taskId) {
  const existing = parseInboxRows(safeRead(inboxPath)).filter((row) => row.summary !== placeholderSummary);
  existing.push({
    createdAt: getTimestamp(),
    source: "claude-posttooluse",
    taskId: taskId || "unknown",
    type: "lock-blocked",
    status: "open",
    summary: "Recovery-index refresh blocked by runtime lock.",
    payload: `Shared runtime lock is held by ${writerName} for task ${taskId || "unknown"}.`,
  });
  writeInbox(existing);
}

/**
 * Returns true when another writer still holds an active runtime lock.
 * @returns {{blocked: boolean, writer: string, taskId: string}}
 */
function checkForeignLock() {
  if (!fs.existsSync(lockPath)) {
    return { blocked: false, writer: "", taskId: "" };
  }

  try {
    const lock = JSON.parse(safeRead(lockPath));
    const ageMs = Date.now() - Date.parse(lock.locked_at);
    if (ageMs <= 30 * 60 * 1000 && lock.writer !== "claude-posttooluse") {
      return { blocked: true, writer: lock.writer || "unknown-writer", taskId: lock.task_id || "unknown" };
    }
  } catch {
    // Malformed lock files are discarded so the hook can keep moving.
  }

  fs.rmSync(lockPath, { force: true });
  return { blocked: false, writer: "", taskId: "" };
}

/**
 * Acquires the runtime lock for this hook run.
 * @param {string} taskId Active task id.
 * @returns {void}
 */
function acquireLock(taskId) {
  const lock = {
    writer: "claude-posttooluse",
    task_id: taskId,
    locked_at: new Date().toISOString(),
  };
  fs.writeFileSync(lockPath, JSON.stringify(lock), "utf8");
}

/**
 * Entry point for the posttooluse hook.
 * @returns {void}
 */
function main() {
  readStdin();
  ensureRuntimeDir();

  const foreignLock = checkForeignLock();
  if (foreignLock.blocked) {
    appendLockBlockedInbox(foreignLock.writer, foreignLock.taskId);
    writeJson({
      systemMessage: `Shared runtime lock is held by ${foreignLock.writer} for task ${foreignLock.taskId}. Recorded in runtime inbox.`,
    });
    return;
  }

  const taskState = resolveTaskState();
  acquireLock(taskState.taskId);

  try {
    fs.writeFileSync(recoveryIndexPath, buildRecoveryIndex(taskState), "utf8");
  } finally {
    fs.rmSync(lockPath, { force: true });
  }

  writeJson({});
}

try {
  main();
} catch {
  try {
    fs.rmSync(lockPath, { force: true });
  } catch {
    // Ignore cleanup failures in the error path.
  }
  writeJson({ systemMessage: "memory hook error in posttooluse.js" });
}
