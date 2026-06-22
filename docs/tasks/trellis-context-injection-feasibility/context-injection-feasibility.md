---
task_id: trellis-context-injection-feasibility
artifact: context-injection-feasibility
updated: 2026-06-22
status: final
---
# Trellis Context Injection Feasibility

## 0. Decision

Trellis context injection should **not** be implemented as automatic runtime behavior in dev-harness right now.

The safe near-term move is to keep context handling **advisory-only**:

- `plan.md read_first:` remains the minimal context entry list.
- `context-manifest.yaml` remains a documented explanation of phase / file / reason / required / notes.
- lazy loading remains controlled by `.assistant/entry/AGENTS.md` and the current stage skill.
- `skills_whitelist` remains controlled by the workflow descriptor.
- no file other than `plan.md` frontmatter becomes stage or tool truth.

This means the current recommendation is:

- **adopt now**: reviewer and TEST wording that checks whether context artifacts stayed advisory-only.
- **adapt later**: an explicit preflight command or host-specific adapter that prints suggested reads, only after a separate plan.
- **defer**: phase-aware automatic injection engine.
- **reject**: any path where `context-manifest.yaml` drives lazy loading, rewrites workflow descriptor fields, or becomes a second truth.

## 1. Trellis context injection facts

`trellis-source-based-corrections.md` corrected the earlier comparison: Trellis context injection is a runtime engine, not only a context taxonomy.

From the local Trellis source snapshot summarized there:

- session-start hooks inject workflow summary, current task, active tasks, spec index, developer identity, and git state.
- workflow-state hints are pushed on each user turn according to task state.
- sub-agent context can be pushed before agent launch or pulled by the agent.
- the implementation depends on `.trellis/scripts` plus platform-specific hooks.

That is materially different from dev-harness. dev-harness currently relies on explicit files and agent discipline: `read_first:`, stage skills, append-only runs, and validator checks.

## 2. Current dev-harness boundary

dev-harness has intentionally small, file-first state:

| Concern | Current owner | Boundary |
|---|---|---|
| Current stage / tool | `plan.md` frontmatter | single truth |
| Minimal task context | `plan.md read_first:` | explicit human-readable list |
| Optional context rationale | `context-manifest.yaml` | advisory-only artifact |
| Skill loading | `.assistant/entry/AGENTS.md` + orchestrator rules | lazy loading, not manifest-driven |
| Tool defaults | `agent-configs/workflows/harness-lite.yaml` | workflow descriptor owns `skills_whitelist` |
| Validation | `validate-lite-artifacts.ps1` | hard errors only for existing protocol rules; drift is warning-only |

Automatic injection would cross at least two of these boundaries unless it is introduced as an explicit, opt-in adapter with its own reviewed contract.

## 3. Feasibility matrix

| Host surface | Feasible now | Dependency | Risk | Recommendation |
|---|---:|---|---|---|
| Codex desktop / current harness run | No | No stable repo-owned hook that can inject content before every turn without host support | Hidden context could diverge from `read_first:` and make review evidence unreproducible | Keep manual reads and advisory manifests |
| Claude Code style hooks | Maybe later | Host-specific hook lifecycle, installation path, opt-in config, audit log | New runtime surface can bypass workflow descriptor and single writer rules | Explore only in a separate host-adapter task |
| Generic PowerShell CLI preflight | Yes, limited | A command that prints suggested reads from `context-manifest.yaml` without injecting them | Low if output is advisory and not consumed by stage advancement | Best candidate for `adapt later` |
| Workflow descriptor integration | Technically possible, not safe now | Descriptor schema change and validator updates | Turns context manifest into `skills_whitelist` or loading policy second truth | Reject for this line of work |
| `.trellis/` runtime import | Not needed | New directory, scripts, hooks, state files | Competes with `docs/tasks` and `.assistant` truth sources | Reject |

## 4. Route classification

### adopt now

Use current artifacts as review evidence:

- PLAN_REVIEW checks whether `context-manifest.yaml` stays advisory-only.
- CODE_REVIEW checks for forbidden fields and second truth wording.
- TEST / Handoff records whether context artifacts were delivered and whether any drift appeared.

This is already implemented by `context-manifest-advisory` and should remain the default behavior.

### adapt later

The lowest-risk next experiment is a read-only preflight helper:

```text
context-preflight <task-id> <phase>
```

It would only print recommended files and reasons from `context-manifest.yaml`. It must not:

- modify `.assistant/运行时/*`
- call `advance-stage.ps1`
- update `skill-manifest.json`
- rewrite `read_first:`
- affect `skills_whitelist`
- inject text into the host conversation

This would preserve auditability because the agent still chooses what to read and can report it in Implementation Notes or TEST.

### defer

Defer phase-aware automatic injection. A safe version would need at least:

- host-specific hook capability documented for Codex / Claude separately
- explicit opt-in per workspace or per task
- clear transcript evidence showing what was injected
- no impact on `plan.md` frontmatter, `read_first:`, lazy loading, or workflow descriptor
- fallback behavior when host hooks are unavailable

Those requirements are larger than the current Trellis borrowing window.

### reject

Reject any design where:

- `context-manifest.yaml` becomes a stage, status, tool, current task, or active pointer source.
- `context-manifest.yaml` decides which skills load.
- workflow descriptor `skills_whitelist` is generated from a task artifact.
- a hook silently injects content without leaving reviewable evidence.
- `.trellis/` runtime is imported to solve this problem.

These all create second truth risk.

## 5. Recommended next task

If this direction is still worth pursuing after more dogfood, the next task should be narrow:

```text
context-preflight-advisory-command
```

Suggested scope:

- read `docs/tasks/<task-id>/context-manifest.yaml`
- accept a phase argument
- print matching file / reason / required entries
- skip cleanly when the file is missing
- never change exit code for normal advisory misses
- never integrate with `advance-stage.ps1`, lazy loading, `skills_whitelist`, or validator hard gate

That gives dev-harness a Trellis-inspired context convenience without adopting Trellis runtime semantics.

## 6. Final answer

Trellis context injection is valuable, but the reusable part for dev-harness today is not automatic injection. It is the discipline of making context needs explicit and auditable.

For now, keep `context-manifest.yaml` advisory-only and use it as a review / handoff aid. Revisit automation only as an explicit preflight command, not as hidden host injection.
