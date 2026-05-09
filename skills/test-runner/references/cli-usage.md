# CLI Usage

These examples use the optional Gemini adapter under the canonical `test-runner` skill.

## Recommended Inputs

- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md` when present
- test logs, screenshots, command outputs, and evidence bundles

## Example Commands

```powershell
& <skill-root>\scripts\ask_gemini.ps1 `
  "Generate the current task test report. The conclusion must be exactly pass, fail, or blocked." `
  -f docs/tasks/<task-id>/plan.md `
  -f docs/tasks/<task-id>/spec.md `
  -f docs/tasks/<task-id>/logs/test-run.log `
  -o docs/tasks/<task-id>/test.md
```

```bash
<skill-root>/scripts/ask_gemini.sh \
  "Generate the current task test report. The conclusion must be exactly pass, fail, or blocked." \
  --file docs/tasks/<task-id>/plan.md \
  --file docs/tasks/<task-id>/spec.md \
  --file docs/tasks/<task-id>/logs/test-run.log \
  -o docs/tasks/<task-id>/test.md
```

Successful execution prints:

```text
output_path=<path>
```
