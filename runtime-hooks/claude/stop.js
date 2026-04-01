const fs = require("fs");

const taskFile =
  "{VAULT_PATH}\\\u8fd0\u884c\u65f6\\\u5f53\u524d\u4efb\u52a1.md";

function writeJson(payload) {
  process.stdout.write(JSON.stringify(payload));
}

function main() {
  try {
    fs.readFileSync(0, "utf8");
  } catch {
    // Ignore missing stdin; Stop hook only needs local state.
  }

  if (!fs.existsSync(taskFile)) {
    writeJson({});
    return;
  }

  const content = fs.readFileSync(taskFile, "utf8");
  const hasActiveStatus = /\|\s*\u72b6\u6001\s*\|\s*\u8fdb\u884c\u4e2d\s*\|/.test(
    content,
  );
  const hasNoTask = /\|\s*\u4efb\u52a1\s*\|\s*\u65e0\s*\|/.test(content);

  if (hasActiveStatus && !hasNoTask) {
    writeJson({
      systemMessage:
        "Runtime memory still marks the current task as in progress. Before stopping, update current-task and, if appropriate, last-session or interrupted-tasks.",
    });
    return;
  }

  writeJson({});
}

try {
  main();
} catch {
  writeJson({ systemMessage: "memory hook error in stop.js" });
}
