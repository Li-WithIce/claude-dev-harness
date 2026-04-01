# CLI Usage

## Script Paths

Skill-relative paths:

```text
scripts/ask_gemini.ps1
scripts/ask_gemini.sh
scripts/check-gemini-env.ps1
scripts/invoke-gemini.ps1
scripts/bootstrap-gemini-project.ps1
```

Priority:

- Windows native CLI: `scripts/ask_gemini.ps1`
- Bash / bridge fallback: `scripts/ask_gemini.sh`

## Native CLI Notes

- `ask_gemini.ps1` 会先检查 CLI 与认证来源，再执行只读分析
- 原生 Gemini CLI 做 TEST 分析时，默认 approval mode 使用 `plan`
- Gemini CLI 的本地 workspace skills 是可选能力，不是当前 TEST runner 的前置依赖
- 仓库级长期上下文优先写到项目根目录 `GEMINI.md`
- 如需初始化 `GEMINI.md`，可使用 `scripts/bootstrap-gemini-project.ps1`

## Recommended Inputs

- Current task `docs/<task-id>/spec.md`
- Current task `docs/<task-id>/plan.md`
- Current task `docs/<task-id>/review.md` when present
- Current task diffs, changed test files, or implementation notes
- Executed test output, logs, screenshots, and known limitations

## Example Commands

```powershell
# Windows native CLI: generate the current task test report
& <skill-root>\scripts\ask_gemini.ps1 `
  "Generate the current task test report. The conclusion must be exactly pass, fail, or blocked." `
  -f docs/<task-id>/spec.md `
  -f docs/<task-id>/plan.md `
  -f docs/<task-id>/review.md `
  -o docs/<task-id>/test.md

# Windows native CLI: re-check after a failing test run
& <skill-root>\scripts\ask_gemini.ps1 `
  "Re-evaluate the current task using review findings and test logs, then produce test.md." `
  -f docs/<task-id>/review.md `
  -f docs/<task-id>/logs/test-run.log `
  -o docs/<task-id>/test.md
```

```bash
# Bash / bridge fallback: generate the current task test report
<skill-root>/scripts/ask_gemini.sh \
  "Generate the current task test report. The conclusion must be exactly pass, fail, or blocked." \
  --file docs/<task-id>/spec.md \
  --file docs/<task-id>/plan.md \
  --file docs/<task-id>/review.md \
  -o docs/<task-id>/test.md

# Bash / bridge fallback: re-check after a failing test run
<skill-root>/scripts/ask_gemini.sh \
  "Re-evaluate the current task using review findings and test logs, then produce test.md." \
  --file docs/<task-id>/review.md \
  --file docs/<task-id>/logs/test-run.log \
  -o docs/<task-id>/test.md
```

Successful execution prints:

```text
output_path=<path>
```
