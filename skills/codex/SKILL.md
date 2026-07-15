---
name: codex
description: Delegate coding tasks to Codex CLI for execution. Invoke this skill when the user explicitly asks to use Codex, or when harness-lite frontmatter / workflow descriptor assigns the current stage to the `codex` backend. Codex is an autonomous coding agent with the same tools as Claude (file read/write, grep, bash) — it explores the codebase and implements changes on its own.
---

## Critical rules

- Use the bundled shell script rather than calling `codex` CLI directly — the script handles output capture, session tracking, and real-time progress streaming correctly.
- Run the script once per task. If it succeeds (exit code 0), read the output file and proceed. Don't re-run just because the output seems short — Codex often makes changes quietly without narrating every step.
- In harness-lite, a stage assigned to `tool: codex` is enough authorization to use this skill; no extra user opt-in is required at that stage boundary.
- Quote file paths containing `[`, `]`, spaces, or special characters (e.g. `--file "src/app/[locale]/page.tsx"`). Without quotes, zsh treats `[...]` as a glob pattern and fails with "no matches found".
- **Keep the task prompt to the goal and constraints, not the implementation steps.** Aim for under ~500 words. Codex has the same tools as Claude and will explore the codebase itself — spelling out every file to change or every step tends to constrain it rather than help.
- **Don't paste file contents into the prompt.** Use `--file` to point Codex to key files — it reads them directly at their current version. Pasting contents wastes tokens and risks passing stale code.
- **Don't mention this skill or its configuration in the prompt.** Codex doesn't need to know about it.

## How to call the script

### Linux/macOS (bash)

The script path is:

```
~/.claude/skills/codex/scripts/invoke_codex.sh
```

Minimal invocation:

```bash
~/.claude/skills/codex/scripts/invoke_codex.sh "Your request in natural language"
```

With file context:

```bash
~/.claude/skills/codex/scripts/invoke_codex.sh "Refactor these components to use the new API" \
  --file src/components/UserList.tsx \
  --file src/components/UserDetail.tsx
```

Multi-turn conversation (continue a previous session):

```bash
~/.claude/skills/codex/scripts/invoke_codex.sh "Also add retry logic with exponential backoff" \
  --session <session_id from previous run>
```

### Windows (PowerShell)

Use PowerShell 7.3 or newer (`pwsh`). The Windows wrapper fails before doing any work under older hosts.

The script path is:

```
~/.claude/skills/codex/scripts/invoke_codex.ps1
```

Minimal invocation:

```powershell
& "$HOME/.claude/skills/codex/scripts/invoke_codex.ps1" "Your request in natural language"
```

With file context:

```powershell
& "$HOME/.claude/skills/codex/scripts/invoke_codex.ps1" "Refactor these components to use the new API" `
  -File @('src/components/UserList.tsx', 'src/components/UserDetail.tsx')
```

Multi-turn conversation (continue a previous session):

```powershell
& "$HOME/.claude/skills/codex/scripts/invoke_codex.ps1" "Also add retry logic with exponential backoff" `
  -Session <session_id from previous run>
```

### Output format

Both wrappers use the same success protocol below. The Windows PowerShell wrapper reports success only when Codex exits with code 0 and emits an agent response; nonzero exit, timeout, or an empty response leaves the requested output path unchanged. The Bash wrapper is a separate implementation and is not covered by that Windows atomic-publication guarantee.

The script prints on success:

```
session_id=<thread_id>
output_path=<path to markdown file>
```

Read the file at `output_path` to get CodeX's response. Save `session_id` if you plan follow-up calls.

## Workflow

1. Understand the problem: read the key files to grasp what's broken or needed. Focus on being able to describe the problem and goal clearly — you don't need to design the full solution or enumerate every affected file. Codex will explore the codebase itself.
2. Run the script with a focused task description: the goal, key constraints, and any non-obvious context. For discussion or analysis without changes, use the wrapper-specific read-only option below.
3. Pass 1-4 entry-point files with Bash `--file` or PowerShell `-File` as starting hints. Codex has the same tools as Claude and will discover related files on its own — no need to enumerate everything upfront.
4. Read the output — Codex executes changes and reports what it did.
5. Review the changes in your workspace.

For multi-step projects, use Bash `--session <id>` or PowerShell `-Session <id>` to continue with full conversation history. For independent parallel tasks, use the Task tool with `run_in_background: true`.

## Failure handling

- **`script: tcgetattr/ioctl: Operation not supported on socket`** (exit code 1): the `script` command probes stdin with `tcgetattr` at startup and only tolerates `ENOTTY`/`ENODEV` errors. When Claude Code connects stdin via a socketpair, the kernel returns `EOPNOTSUPP` instead — which `script` doesn't whitelist, so it exits immediately. The script detects this automatically by probing with `script -q /dev/null true` first and falls back to direct execution. Update to the latest version if you still see this error.
- **Exit code 137**: the task was interrupted (user cancel or OOM). Not a Codex bug — retry or break the task into smaller pieces.
- **`ERROR codex_core::codex: failed to load skill ...`** in stderr: one of Codex's own installed skills has a broken YAML file. This warning is harmless and doesn't affect the current task — ignore it.
- **Codex exited successfully without an agent response** (Windows): the PowerShell wrapper returns nonzero and leaves the requested output path unchanged. Check stderr and the streamed progress for the underlying failure.

### Bash options

- `--workspace <path>` — Target workspace directory (defaults to current directory).
- `--file <path>` — Point CodeX to key entry-point files (repeatable, workspace-relative or absolute). Don't duplicate their contents in the prompt.
- `--session <id>` — Resume a previous session for multi-turn conversation.
- `--model <name>` — Override model for a new session (default: uses Codex config).
- `--reasoning <level>` — Reasoning effort: `low`, `medium`, `high` (default: `medium`). Use `high` for code review, debugging, complex refactoring, or root cause analysis.
- `--sandbox <mode>` — Override sandbox policy for a new session.
- `--read-only` — Read-only sandbox for a new session.
- `--full-auto` — Full-auto for a new session; this is the Bash default unless sandbox/read-only is selected.
- `--output <path>` — Response path.

### Bash resume limitations

The Bash wrapper's resume branch forwards the session id, reasoning effort, prompt/file context, and workspace working directory. Its parsed `--model`, `--sandbox`, `--read-only`, and `--full-auto` flags do not alter a resumed session; do not rely on them for resume isolation. The Bash wrapper has no `--ephemeral` option. Use the Windows PowerShell wrapper when resumed readonly or ephemeral behavior is required.

### Windows PowerShell options

- `-Workspace <path>` — Target workspace directory (defaults to the caller's current directory).
- `-File @('<path1>', '<path2>')` / `-f @('<path1>', '<path2>')` — Priority entry-point files; bind the parameter once with a PowerShell array.
- `-Session <id>` — Resume a previous session.
- `-Model <name>` — Override model; otherwise use Codex config.
- `-Reasoning <level>` — `low`, `medium`, `high`, or `max` (default: `medium`). Use `max` only when the selected model exposes that single-subject tier.
- `-Sandbox <mode>` — `read-only`, `workspace-write`, or `danger-full-access`; no sandbox override is supplied by default.
- `-ReadOnly` — Read-only mode for new and resumed sessions.
- `-FullAuto` — Opt in to full-auto for a new session; it is not the Windows default and does not apply to resume.
- `-Ephemeral` — Do not persist Codex session files.
- `-TimeoutSeconds <seconds>` — Main-process timeout (default: 1800 seconds); timeout returns nonzero and closes the supported process tree.
- `-Output <path>` / `-o <path>` — Response path; relative paths use the caller's current directory and successful output is published atomically.
- `-OutputSchema <path>` — JSON Schema for the final model response.
- `-TelemetryOutput <path>` — Atomic JSON with model/reasoning, timing, aggregate turn/tool/skill counts, and available token usage; it excludes prompts, command text, thread ids, and private paths.
- `-AgentOutputOnly` — Exclude command summaries from the response file.
- `-Quiet` — Suppress live command and message previews.
- `-Isolated` — Disable plugins, apps, browser/computer use, memory, image generation, and multi-agent/fanout features for a fresh single-subject evaluation context.

## Resume mode limitations

The current Windows wrapper uses the Codex 0.141 resume contract:

- It passes `--json`, `--skip-git-repo-check`, `--ignore-user-config`, optional `--ephemeral`, and optional `-m/--model`.
- The follow-up prompt is sent through stdin with the explicit trailing `-` prompt argument.
- Resume has no direct `--sandbox` or `--cd` option. Windows `-ReadOnly` is enforced with `-c sandbox_mode="read-only"`; an explicit `-Sandbox` uses the same config key.
- `-Workspace` sets the wrapper process working directory, but it does not rewrite the original session's stored context.
- `-FullAuto` applies only to new sessions.
- When the Microsoft Store app path cannot be started through `ProcessStartInfo`, the wrapper uses the Codex app's user-scoped `.codex/.sandbox-bin/codex.exe`; an explicit `CODEX_EXECUTABLE` can override this only with an existing file.

These resume guarantees are specific to `invoke_codex.ps1`. The Bash wrapper is a separate implementation and does not inherit the Windows hardening contract. Existing `ask_codex.ps1` and `ask_codex.sh` commands remain thin compatibility shims.
