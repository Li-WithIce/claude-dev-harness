# Contributing

## Local State

`.assistant/` is local user/workspace state and must not be committed. Durable protocol, template, and policy changes belong in tracked surfaces such as `docs/`, `skills/`, `tests/`, or `vault-template/`.

`docs/tasks/<task-id>/` contains local workflow artifacts and is ignored by default. Keep `docs/tasks/README.md` tracked.

## Validation

Run the focused suite for small changes:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite quick
```

Run the core suite before submitting workflow, installer, validator, or provider-boundary changes:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite core
```

Provider tools are optional advisory inputs. Installation, updates, and validation must not install, register, or connect external providers by default.

Do not mutate user-private Claude, Codex, or MCP configuration unless a task explicitly requires it and the change is reviewed as part of the diff.

## License

No repository license has been specified yet. Do not add a license file or relicense content without explicit maintainer approval.
