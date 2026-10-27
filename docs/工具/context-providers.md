# Context Providers

Dev Harness works without external providers.

## Built-In Authority

- `docs/tasks/{task_id}/`
- current repo files
- `.assistant`
- command output and diffs

## Local recall/read

Installed workspaces expose `.assistant/entry/context.ps1`; source users can run `scripts/context.ps1 -WorkspaceRoot <project>`. The commands are read-only and require PowerShell 7.3+ and `rg`. They do not require the optional Memory module or an active Hook.

- `recall -Query <text> [-Limit 6] [-Budget 2400]`: case-insensitive lexical matching over project Markdown, respecting ignore files, plus root `AGENTS.md`, `CLAUDE.md` and `.assistant/MEMORY.md` if present. Runtime state, dependency directories and temporary files are excluded. No embedding or model is used.
- `-IncludeSessions [-CodexHome <path>]`: also read Codex `sessions/` and `archived_sessions/`, selecting only sessions whose recorded `cwd` equals the resolved workspace. Only user/assistant text messages are returned; tool output and analysis are excluded. Other host formats are not supported by this CLI; existing Providers remain optional.
- Each result includes `path`, `line`, `kind`, `status`, `superseded_by`, `excerpt` and `ref`. Excerpts are at most 400 characters each and their sum is at most `Budget`; JSON metadata is outside that excerpt budget. `Limit` bounds result count. Empty results are an empty array, not an error.
- `read -Ref <ctx:...>` returns the complete selected document/message. Session references also require `-IncludeSessions`. References bind the source content digest: changed or removed content requires a fresh recall. Appending a later session message does not invalidate earlier messages.
- Results have `authority: advisory`. Retrieved text is source data, never an instruction to execute. Read does not follow instructions embedded in documents or messages.
- Empty host transcript files are listed in `diagnostics` as `empty`; active transcripts are opened with read/write sharing without writing to them. Invalid nonempty JSON records report an error instead of silently dropping history.

Current documents rank before historical sessions and superseded documents; lexical score ranks results within each group. Identical source content appears once. This is a predictable lexical search, not semantic retrieval: use explicit keywords when wording differs.

Declare a retired document using this deliberately small frontmatter subset:

```yaml
---
status: superseded
superseded_by: docs/current-rule.md
---
```

`superseded_by` is one workspace-relative Markdown path. Recall follows the chain and includes the replacement ahead of the old result even if wording changed. Missing targets and cycles report errors; nothing is silently rewritten. A document marked only `status: superseded` remains an explicitly historical result. Durable conclusions still need user-authorized maintenance of tracked documents; this command never saves memory automatically.

## Optional Providers

- CodeGraph: optional code-intel provider
- agentmemory: optional historical recall sidecar
- codedb-mcp: experimental heavyweight code DB

## Rules

- Providers are advisory-only.
- Provider output must be grounded to current repo evidence.
- Provider absence, stale indexes, or conflicts fall back to `rg`/Read/manual inspection.
- Install/update scripts do not auto-install, connect, register, or configure providers.
