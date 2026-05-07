# Sandbox Mode Writeback Investigation

**Task:** 68bd1fbf — Investigate sandbox_mode writeback source
**Mode:** Read-only investigation (no code, config, or template edits performed)
**Date:** 2026-04-29
**Investigator:** config-investigator

---

## TL;DR

1. The `sandbox_mode = "workspace-write"` line in `C:\Users\28796\.codex\config.toml` is **NOT** written by the Harness (`install.ps1` / `update-managed-assets.ps1`). It is written by the **Codex CLI itself**, in the user-owned region of the file (above the `# >>> claude-dev-harness managed block >>>` marker).
2. The line that actually crashes the codex teammate at launch is **not** `sandbox_mode` itself — it is a **malformed CRLF on the preceding line**: `personality = "pragmatic"\r` followed immediately by `sandbox_mode = "workspace-write"\r\n` (a lone `\r` instead of `\r\n` between two top-level keys). This makes the TOML unparseable.
3. The Harness preserves the user region verbatim, so once the file gets corrupted by an external writer, every subsequent `install.ps1` run carries the corruption forward unchanged.
4. **No blocker for `onboarding-gitignore-safeguard`** — that task only adds entries to a workspace `.gitignore`, which is fully independent of the codex host config.

---

## Files / Commands actually inspected

### Live files
- `C:\Users\28796\.codex\config.toml` (current, mtime 2026-04-29 10:12:47)
- `C:\Users\28796\.codex\config - 副本.toml` (Mar 25 manual user backup)
- `C:\Users\28796\.codex\.personality_migration` (contents: `v1` — codex-internal migration marker)
- `C:\Users\28796\.codex\.codex-global-state.json` (codex GUI state)
- Directory listing of `C:\Users\28796\.codex\` (auth.json, sessions, sandbox.log, logs_2.sqlite, etc. — all owned by codex, not Harness)

### Repo files
- `D:\data\claude-dev-harness\install.ps1` (full read; specifically `Update-CodexConfig` lines 995–1021, `Remove-ManagedTomlBlock` lines 984–993, `Remove-ManagedSkillsConfigBlocks` lines 923–982, `Read-FileUtf8` lines 188–196, `Write-Utf8NoBom` lines 169–178)
- `D:\data\claude-dev-harness\scripts\update-managed-assets.ps1` (full read — confirmed it is just a wrapper around `install.ps1` + `tests/verify-installation.ps1`, performs no direct config writes)
- `D:\data\claude-dev-harness\agent-configs\codex\config.shared.toml.template` (full read — does **not** contain `sandbox_mode` or `personality`)
- `D:\data\claude-dev-harness\agent-configs\codex\config.user.example.toml` (full read — example shows `personality = "pragmatic"` as user content, with `[windows] sandbox = "unelevated"`)
- `D:\data\claude-dev-harness\agent-configs\codex\README.md` (boundary doc: install.ps1 only patches managed block)
- `D:\data\claude-dev-harness\skills\codex\scripts\ask_codex.sh` (full read — passes `--full-auto` / `--sandbox <mode>` as runtime args; never writes to `config.toml`)
- `D:\data\claude-dev-harness\skills\codex\scripts\ask_codex.ps1` (full read — same behavior, runtime flags only)
- `D:\data\claude-dev-harness\skills\codex\SKILL.md` (referenced for `--sandbox` documentation)
- `D:\data\claude-dev-harness\skills\workflow-team\scripts\spawn-team.ps1` (sampled — spawns teammates via `team_spawn_agent`, no config.toml mutation)
- `D:\data\claude-dev-harness\tests\verify-installation.ps1` (sampled lines 354–483 — read-only checks only)

### Backup snapshots compared (chronological)
- `backups\install-20260429-090741-739-14468\C_Users_28796_.codex_config.toml` (2643 B, pre-09:07 install) — clean CRLF
- `backups\install-20260429-090802-157-34324\C_Users_28796_.codex_config.toml` (2300 B)
- `backups\install-20260429-090835-306-54728\C_Users_28796_.codex_config.toml` (2310 B)
- `backups\install-20260429-090905-845-41580\C_Users_28796_.codex_config.toml` (2310 B) — clean CRLF
- `backups\install-20260429-093853-199-41128\C_Users_28796_.codex_config.toml` (2178 B)
- `backups\install-20260429-094140-760-37044\C_Users_28796_.codex_config.toml` (2256 B, latest backup) — **clean CRLF, properly separated lines**
- Live `C:\Users\28796\.codex\config.toml` (2274 B, mtime 10:12) — **broken: lone `\r` mid-line**

### Repo-wide grep (`Grep` tool)
- `sandbox_mode` — only matches in `skills/codex/scripts/ask_codex.sh` (CLI runtime arg, not config write)
- `workspace-write` — only in `skills/codex/SKILL.md` (doc string)
- `personality\s*=` — only in `agent-configs/codex/config.user.example.toml`
- `config\.toml`, `CodexHome`, `codexConfig` — write site is exclusively `install.ps1::Update-CodexConfig`, plus the test-only `verify-installation.ps1` (read-only assertions)

### Byte-level diff
- `od -c` of current file — shows `..."pragmatic"\r sandbox_mode...` (lone CR, no LF)
- `od -c` of 09:41 backup — shows `..."pragmatic"\r\n sandbox_mode...` (proper CRLF)

---

## Most likely write-back source

### Who is writing `sandbox_mode = "workspace-write"`

**The Codex CLI itself**, not the Harness. Evidence chain:

1. **Repo-wide search:** No code path in `install.ps1`, `scripts/update-managed-assets.ps1`, `agent-configs/codex/*.template`, `skills/**`, or any spawn/bootstrap script writes the literal string `sandbox_mode = "workspace-write"` to any TOML file. The only repo references to either token are CLI runtime flags (`--sandbox`) or doc strings.

2. **Boundary doc confirms intent:** `agent-configs/codex/README.md` line 13 explicitly states `install.ps1` only patches the Harness-managed block and **does not** overwrite `model`, `provider`, `auth`, or `project trust` — i.e. anything in the user region is preserved.

3. **`Update-CodexConfig` (install.ps1:995–1021) verified:**
   - Reads existing file (`Get-Content -Raw -Encoding utf8`).
   - Strips ONLY the `# >>> claude-dev-harness managed block >>>` … `# <<< … <<<` region (regex `Remove-ManagedTomlBlock`).
   - Strips `[[skills.config]]` blocks **only if** their `path = ...` matches a Harness-managed skill path (regex match on the rendered template paths).
   - Reassembles as `$sanitized.TrimEnd() + "`r`n`r`n" + $managedBlock + "`r`n"`.
   - The user's `personality`, `sandbox_mode`, `[windows]`, `[projects.*]`, `[model_providers.*]` are passed through unmodified.

4. **Backup deltas show codex CLI mutating the file between Harness runs:**
   - 09:09 backup → still has `[model_providers.jabin]`, `[windows] sandbox = "unelevated"`.
   - 09:38 backup → still has `[model_providers.jabin]`.
   - 09:41 backup → `[model_providers.jabin]` removed, `[windows] sandbox = "elevated"`, new `[projects.'c:\windows\system32']` trust entry added.
   - 09:41 → 10:12 (current) → **no install backup created** in this window, yet the file mtime is 10:12. Something OTHER than the Harness wrote the file in that window, and that write produced the corruption.

5. **Codex CLI is known to persist runtime decisions** (project trust, provider switches, sandbox mode). The presence of `.personality_migration`, `.codex-global-state.json`, `auth.json`, `state_5.sqlite`, and codex's own `config - 副本.toml` user backup all confirm Codex CLI freely rewrites `~/.codex/config.toml`.

### What actually crashes codex on launch

The crash trigger is **not** the value of `sandbox_mode`. It is the **malformed CRLF byte sequence** on lines 5–6:

```
0000200   p   r   a   g   m   a   t   i   c   "  \r   s   a   n   d
0000220   b   o   x   _   m   o   d   e       =       "   w   o   r   k
```

Concretely: `personality = "pragmatic"\rsandbox_mode = "workspace-write"\r\n` — a lone CR (0x0D) instead of CRLF between two top-level keys. Every other line in the file uses proper `\r\n`. A TOML parser sees this as either:
- A single malformed line `personality = "pragmatic"sandbox_mode = "workspace-write"` (two `=` signs → parse error), or
- An unterminated string (CR-in-value rejected by strict parsers).

Either way: **codex fails to load its own config and exits before serving the teammate.**

### Why the Harness perpetuates the corruption

`install.ps1` reads via `Get-Content -Raw` (preserves all bytes), then `Remove-ManagedSkillsConfigBlocks` does `$Content -split "`r?`n"`. The PowerShell regex `\r?\n` does **not** match a lone `\r`, so the corrupted line `..."pragmatic"\rsandbox_mode = "workspace-write"` is kept as a single split-element. On rejoin with `"`r`n"` the lone CR is faithfully preserved inside that line. The Harness will not heal this corruption — it transparently round-trips it forever.

---

## Evidence chain (compact)

| Step | Observation | Conclusion |
|------|-------------|-----------|
| 1 | Grep `sandbox_mode` in repo → only in `ask_codex.sh` runtime args | Harness never writes the key |
| 2 | Grep `workspace-write` in repo → only doc string | Harness never writes the value |
| 3 | `config.shared.toml.template` does not contain either token | Template is not the source |
| 4 | `Update-CodexConfig` only edits the marker-delimited managed block | User region (incl. lines 1–6) untouched by Harness |
| 5 | `update-managed-assets.ps1` is a wrapper over `install.ps1` + verify | Same conclusion as (4) |
| 6 | Backup at 09:41 has clean `\r\n`; live file at 10:12 has lone `\r` | Writer struck between 09:41 and 10:12 |
| 7 | No install backup exists in 09:41 → 10:12 window | Writer is not `install.ps1` |
| 8 | Backup deltas show provider blocks added/removed and `[windows] sandbox` flipped between Harness runs | Codex CLI is a routine writer of this file |
| 9 | `.personality_migration`, `.codex-global-state.json`, `auth.json`, `state_5.sqlite`, `sandbox.log` all live in `~/.codex` | Codex CLI owns and frequently mutates this directory |
| 10 | Lone `\r` is between two top-level keys; PS `-split "`r?`n"` does not split on lone CR | Harness round-trips the corruption rather than introducing it |

---

## Minimum mitigation (read-only proposal — pick ONE)

### Option A — Manually heal the user region (zero risk, immediate)
Open `C:\Users\28796\.codex\config.toml` in a CRLF-aware editor (VS Code, Notepad++) and either:
- Re-insert the missing `\n` after `personality = "pragmatic"` so lines 5 and 6 are properly separated, **or**
- Delete the `sandbox_mode = "workspace-write"` line entirely (codex defaults sandbox via `--full-auto` / `--sandbox` CLI flags, which the Harness already passes — see `ask_codex.sh:184–191`).

Codex teammate should launch successfully on the next spawn. Re-running `install.ps1` is **not** required and will **not** fix this byte-level corruption (see "Why the Harness perpetuates the corruption" above).

### Option B — Stop relying on the host `config.toml` for sandbox policy
`ask_codex.sh` / `ask_codex.ps1` already build `--full-auto` or `--sandbox <mode>` into the codex command line. Removing the `sandbox_mode = "workspace-write"` line from the user region eliminates one writeback target. If codex CLI re-creates the line later, it is harmless **as long as** the surrounding CRLF stays clean. Combine with Option A.

### Option C — Add a defensive normalization step in `Update-CodexConfig` (out of scope here, but worth a follow-up task)
Before writing, normalize the user region: replace any standalone `\r` (not followed by `\n`) with `\r\n`. This would be the only way to make the Harness self-heal external CRLF corruption. **Not implemented in this read-only task.**

**Recommended:** Option A right now (unblocks codex teammate immediately). File a separate small task for Option C if the corruption recurs.

---

## Blocker assessment for `onboarding-gitignore-safeguard`

**Not a blocker.**

- `onboarding-gitignore-safeguard` (per `install.ps1::Ensure-WorkspaceGitIgnoreEntries`, lines 216–271) only appends `.assistant/`, `AGENTS.md`, `GEMINI.md`, `.claude` to the workspace's `.gitignore`. It never touches `~/.codex/config.toml`.
- The codex teammate is independent from that gitignore work; the gitignore safeguard task is a workspace-side text manipulation that does not need a running codex agent to validate or merge.
- The two failure surfaces are orthogonal: the codex-config CRLF bug only blocks tasks that rely on **spawning a codex teammate**.

If a downstream task in the queue (e.g. anything that explicitly requires codex teammate execution) needs a healthy codex CLI, apply Option A first. Otherwise `onboarding-gitignore-safeguard` can proceed without dependency on this fix.

---

## Open questions / follow-ups (not pursued, read-only scope)

1. Identify the exact codex CLI version / code path that emits the lone CR. The repo contains no codex source, so this requires inspecting upstream codex (`@openai/codex`).
2. Decide whether `Update-CodexConfig` should normalize stray CR bytes defensively (Option C above).
3. Confirm whether `personality = "pragmatic"` is still a recognized codex config key in the user's installed codex version, or whether the `.personality_migration v1` marker means it is now ignored. If ignored, deleting it removes one corruption surface.
