# Contributing

## Local State

`.assistant/` is local user/workspace state and must not be committed. Durable protocol, template, and policy changes belong in tracked surfaces such as `docs/`, `skills/`, `tests/`, or `vault-template/`.

Generated `docs/tasks/{task_id}/` task artifacts are local workflow artifacts and ignored by default. Keep `docs/tasks/README.md` tracked.

## Validation

Run the focused suite for small changes:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite quick
```

Run the core suite before submitting workflow, installer, validator, or provider-boundary changes:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite core
```

Run every repository verifier that does not require an explicit workspace root:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 900
```

`verify-installation.ps1` is intentionally outside the default no-argument `all` loop. Exercise installation lifecycle coverage with `run-isolated-install-smoke.ps1` for each of the `core`, `governed`, and `full` presets. After `.github/workflows/full-validation.yml` reaches the default branch, it provides daily and input-free manual full validation. This is ordinary engineering validation, not Release Qualification.

Provider tools are optional advisory inputs. Installation, updates, and validation must not install, register, or connect external providers by default.

Do not mutate user-private Claude, Codex, or MCP configuration unless a task explicitly requires it and the change is reviewed as part of the diff.

## License

No repository license has been specified yet. Do not add a license file or relicense content without explicit maintainer approval.
