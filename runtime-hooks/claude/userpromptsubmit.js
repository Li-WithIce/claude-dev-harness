const fs = require("fs");

function writeJson(payload) {
  process.stdout.write(JSON.stringify(payload));
}

function main() {
  let raw = "";
  try {
    raw = fs.readFileSync(0, "utf8");
  } catch {
    raw = "";
  }

  if (!raw.trim()) {
    writeJson({});
    return;
  }

  let blob = raw;
  try {
    blob = JSON.stringify(JSON.parse(raw));
  } catch {
    blob = raw;
  }

  const resumePattern = new RegExp(
    [
      "\\bresume\\b",
      "\\bcontinue\\b",
      "what were we doing",
      "\u7ee7\u7eed",
      "\u6062\u590d",
      "\u7ee7\u7eed\u521a\u624d\u7684\u4efb\u52a1",
      "\u521a\u624d\u505a\u5230\u54ea\u91cc\u4e86",
      "\\\\u7ee7\\\\u7eed",
      "\\\\u6062\\\\u590d",
      "\\\\u7ee7\\\\u7eed\\\\u521a\\\\u624d\\\\u7684\\\\u4efb\\\\u52a1",
      "\\\\u521a\\\\u624d\\\\u505a\\\\u5230\\\\u54ea\\\\u91cc\\\\u4e86",
    ].join("|"),
    "i",
  );

  if (resumePattern.test(blob)) {
    writeJson({
      systemMessage:
        "Resume trigger detected. Read runtime/recovery-index first. Fallback order: current-task -> interrupted-tasks -> last-session. Bootstrap status is in config/引导状态.md, not for runtime task inference.",
    });
    return;
  }

  writeJson({});
}

try {
  main();
} catch {
  writeJson({ systemMessage: "memory hook error in userpromptsubmit.js" });
}
