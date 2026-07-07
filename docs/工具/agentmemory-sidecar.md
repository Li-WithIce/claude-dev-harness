# agentmemory Sidecar

Status: optional read-only historical recall sidecar.

## Use When

- a task depends on older decisions
- the user asks to recall prior context
- current repo evidence needs historical explanation

## Boundary

- Historical context only.
- `.assistant` and current task artifacts remain authoritative.
- Must not write `.assistant/运行时/*`.
- Must not modify `plan.md` frontmatter.
- Must not modify `test.md` conclusion.
- Must not promote wisdom directly.
- Any `agentmemory connect` or registration is user opt-in.

## Windows / WSL Caveat

- agentmemory remains opt-in.
- WSL2 may be the practical fast path for setup and runtime behavior.
- Native Windows setup may be manual, limited, or environment-specific.
- Harness install/update must not run `agentmemory connect`.
- agentmemory is read-only historical recall, not a replacement for `.assistant` or `docs/tasks`.

## Conflict Rule

Current user instruction, current repo files, current task artifacts, and `.assistant` override agentmemory recall.
