const fs = require("fs");
const path = require("path");

const assistantRoot = "{VAULT_PATH}";
const runtimeDir = path.join(assistantRoot, "\u8fd0\u884c\u65f6");
const currentTaskFile = path.join(runtimeDir, "\u5f53\u524d\u4efb\u52a1.md");
const interruptedTasksFile = path.join(runtimeDir, "\u4e2d\u65ad\u4efb\u52a1.md");
const lastSessionFile = path.join(runtimeDir, "\u4e0a\u6b21\u4f1a\u8bdd.md");
const recoveryIndexFile = path.join(runtimeDir, "\u6062\u590d\u7d22\u5f15.md");

const watchedFiles = new Set(
  [currentTaskFile, interruptedTasksFile, lastSessionFile].map(normalizePath),
);

function normalizePath(filePath) {
  return path.resolve(filePath).toLowerCase();
}

function writeJson(payload) {
  process.stdout.write(JSON.stringify(payload));
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function safeRead(filePath) {
  if (!fs.existsSync(filePath)) {
    return "";
  }
  return fs.readFileSync(filePath, "utf8");
}

function parseJson(raw) {
  if (!raw.trim()) {
    return null;
  }

  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function collectStringPaths(value, bucket = []) {
  if (typeof value === "string") {
    if (
      value.includes(".assistant") &&
      (value.endsWith(".md") || value.includes(".md\""))
    ) {
      bucket.push(value);
    }
    return bucket;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      collectStringPaths(item, bucket);
    }
    return bucket;
  }

  if (value && typeof value === "object") {
    for (const [key, nested] of Object.entries(value)) {
      if (
        (key === "file_path" || key === "filePath" || key === "path") &&
        typeof nested === "string"
      ) {
        bucket.push(nested);
        continue;
      }
      collectStringPaths(nested, bucket);
    }
  }

  return bucket;
}

function shouldRefresh(payload, raw) {
  if (!payload) {
    return true;
  }

  const toolName = payload.tool_name || payload.toolName || "";
  if (toolName && !["Write", "Edit", "MultiEdit"].includes(toolName)) {
    return false;
  }

  const candidates = new Set(
    collectStringPaths(payload).map((item) =>
      normalizePath(item.replace(/^"+|"+$/g, "")),
    ),
  );

  if ([...candidates].some((item) => watchedFiles.has(item))) {
    return true;
  }

  return (
    typeof raw === "string" &&
    [
      "\u5f53\u524d\u4efb\u52a1.md",
      "\u4e2d\u65ad\u4efb\u52a1.md",
      "\u4e0a\u6b21\u4f1a\u8bdd.md",
    ].some((fileName) => raw.includes(fileName))
  );
}

function clean(value) {
  return String(value || "")
    .replace(/\r/g, "")
    .replace(/\n+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function parseKeyValueTable(content) {
  const lines = content.split(/\r?\n/);
  const data = {};
  let started = false;

  for (const line of lines) {
    if (!line.startsWith("|")) {
      if (started) {
        break;
      }
      continue;
    }

    const cells = line
      .split("|")
      .slice(1, -1)
      .map((item) => item.trim());

    if (cells.length !== 2) {
      continue;
    }

    if (/^-+$/.test(cells[0].replace(/:/g, ""))) {
      started = true;
      continue;
    }

    if (cells[0] === "\u9879\u76ee" && cells[1] === "\u503c") {
      started = true;
      continue;
    }

    if (!started) {
      continue;
    }

    data[cells[0]] = cells[1];
  }

  return data;
}

function parseInterruptedTasks(content) {
  const lines = content.split(/\r?\n/);
  const rows = [];
  let headers = null;

  for (const line of lines) {
    if (!line.startsWith("|")) {
      if (headers && rows.length > 0) {
        break;
      }
      continue;
    }

    const cells = line
      .split("|")
      .slice(1, -1)
      .map((item) => item.trim());

    if (!headers) {
      if (cells[0] === "\u4f18\u5148\u7ea7") {
        headers = cells;
      }
      continue;
    }

    if (cells.every((cell) => /^:?-{3,}:?$/.test(cell))) {
      continue;
    }

    if (cells.length !== headers.length) {
      continue;
    }

    const row = {};
    headers.forEach((header, index) => {
      row[header] = cells[index];
    });
    rows.push(row);
  }

  return rows;
}

function buildRecoveryIndex() {
  const currentTask = parseKeyValueTable(safeRead(currentTaskFile));
  const interruptedTasks = parseInterruptedTasks(safeRead(interruptedTasksFile));
  const lastSession = parseKeyValueTable(safeRead(lastSessionFile));

  const currentTaskName = clean(currentTask["\u4efb\u52a1"]) || "\u65e0";
  const currentStatus = clean(currentTask["\u72b6\u6001"]) || "\u672a\u77e5";
  const currentNextStep = clean(currentTask["\u4e0b\u4e00\u6b65"]) || "\u65e0";
  const lastDone =
    clean(currentTask["\u4e0a\u6b21\u5b8c\u6210\u6b65\u9aa4"]) || "\u65e0";

  const topInterrupted = interruptedTasks.slice(0, 3);
  const interruptedLines =
    topInterrupted.length > 0
      ? topInterrupted
          .map((item) => {
            const priority = clean(item["\u4f18\u5148\u7ea7"]) || "P?";
            const task = clean(item["\u4efb\u52a1"]) || "\u672a\u547d\u540d";
            const status = clean(item["\u72b6\u6001"]) || "\u672a\u77e5";
            const nextStep = clean(item["\u4e0b\u4e00\u6b65"]) || "\u65e0";
            return `- [${priority}] ${task} | ${status} | ${nextStep}`;
          })
          .join("\n")
      : "- \u65e0";

  const lastSessionDate = clean(lastSession["\u65e5\u671f"]) || "\u65e0";
  const lastSessionTask = clean(lastSession["\u4efb\u52a1"]) || "\u65e0";
  const lastSessionStatus = clean(lastSession["\u72b6\u6001"]) || "\u65e0";
  const lastSessionSummary = clean(lastSession["\u6458\u8981"]) || "\u65e0";

  const generatedAt = new Date().toLocaleString("sv-SE", { hour12: false });

  return [
    "---",
    "tags: [\u8fd0\u884c\u65f6, \u6062\u590d\u7d22\u5f15]",
    "created: 2026-03-13",
    `updated: ${generatedAt}`,
    "---",
    "",
    "# \u6062\u590d\u7d22\u5f15",
    "",
    "\u7ee7\u7eed\u4efb\u52a1\u65f6\u5148\u8bfb\u672c\u6587\uff1b\u53ea\u5728\u4fe1\u606f\u4e0d\u8db3\u65f6\u518d\u56de\u8bfb\u8be6\u7ec6\u8fd0\u884c\u65f6\u6587\u4ef6\u3002",
    "",
    "## \u5f53\u524d\u4e3b\u4efb\u52a1",
    `- \u4efb\u52a1: ${currentTaskName}`,
    `- \u72b6\u6001: ${currentStatus}`,
    `- \u4e0a\u6b21\u5b8c\u6210: ${lastDone}`,
    `- \u4e0b\u4e00\u6b65: ${currentNextStep}`,
    "",
    "## \u4e2d\u65ad\u4efb\u52a1 Top 3",
    interruptedLines,
    "",
    "## \u4e0a\u6b21\u4f1a\u8bdd",
    `- ${lastSessionDate} | ${lastSessionTask} | ${lastSessionStatus}`,
    `- \u6458\u8981: ${lastSessionSummary}`,
    "",
    "## \u56de\u9000\u8bfb\u53d6",
    "- \u8be6\u7ec6\u4e0d\u8db3\u65f6\uff0c\u518d\u8bfb\uff1a`\u5f53\u524d\u4efb\u52a1.md -> \u4e2d\u65ad\u4efb\u52a1.md -> \u4e0a\u6b21\u4f1a\u8bdd.md`",
    "",
  ].join("\n");
}

function writeRecoveryIndex() {
  fs.mkdirSync(runtimeDir, { recursive: true });
  fs.writeFileSync(recoveryIndexFile, buildRecoveryIndex(), "utf8");
}

function main() {
  const raw = readStdin();
  const payload = parseJson(raw);

  if (!shouldRefresh(payload, raw)) {
    writeJson({});
    return;
  }

  writeRecoveryIndex();
  writeJson({});
}

try {
  main();
} catch {
  writeJson({ systemMessage: "memory hook error in posttooluse.js" });
}
