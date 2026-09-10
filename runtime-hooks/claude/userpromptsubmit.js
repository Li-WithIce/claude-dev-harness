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
      "\u521a\u624d\u505a\u5230\u54ea\u91cc\u4e86",
      "\\\\u7ee7\\\\u7eed",
      "\\\\u6062\\\\u590d",
      "\\\\u521a\\\\u624d\\\\u505a\\\\u5230\\\\u54ea\\\\u91cc\\\\u4e86",
    ].join("|"),
    "i",
  );

  if (resumePattern.test(blob)) {
    writeJson({
      systemMessage:
        "Resume trigger detected. Clarify read-only status versus continued execution, then use the native v2 task entry for explicit recovery. No legacy pointer, flow, or plan fallback; this prompt does not authorize writes.",
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
