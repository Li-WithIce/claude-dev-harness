# Thin Harness v2 policy engine

## Purpose and authority

The policy engine selects an execution profile after the Requirement Gate has classified product decisions. It does not infer missing product intent and does not grant authorization for a protected action.

The canonical machine sources are:

- `policies/decision-rights.json` for product, architecture, and agent ownership;
- `policies/risk-rules.json` for score bands and hard Critical triggers;
- `policies/execution-profiles.json` for Inspect, Direct, Governed, and Critical capabilities;
- `policies/protected-actions.json` for hard escalation rules;
- optional workspace `.assistant/policies/protected-actions.local.json` for project-specific protected paths, commands, and exact environment labels;
- `scripts/lib/Harness.Requirement.psm1` and `scripts/lib/Harness.Policy.psm1` for strict loading and resolution.

Documentation and prompts may explain these rules but cannot weaken them. Missing, malformed, unknown, or semantically weaker policy fails closed.

Core ships exactly two protected-action rules: production destructive database commands and authorization-path changes. This is not a claim that two rules cover every Critical trigger. Globstar prefixes such as `**/auth/**` match the protected directory at the workspace root as well as at nested depths. Projects extend the boundary with `protected-actions-overlay/v1`, validated by `schemas/protected-actions-overlay.schema.json`. Overlay rule ids must be unique and cannot replace core ids; each rule may match an exact environment label, command regex, path globs, or their intersection, and may only require Governed/Critical plus an existing Approval type, dry-run, and independent review. A malformed, duplicate, unreadable, or schema-invalid overlay rejects writes fail closed; reads remain available.

## Resolution flow

1. `Harness.Requirement` resolves source authority and emits a Requirement Contract or `requirement_state=blocked`.
2. Blocked requirements do not receive an execution profile. Read-only intent selects Inspect.
3. Mutation risk is scored across the canonical dimensions. Totals 0-4 select Direct, 5-8 Governed, and 9-21 Critical.
4. Durable artifact requests raise the minimum to Governed. File count alone never raises risk.
5. A known Critical trigger raises the profile to Critical. Unknown triggers are rejected rather than ignored.
6. Protected-action matches can only raise requirements. Scope expansion or a newly discovered product blocker reroutes before write.

`HARNESS_PROTOCOL=v2` is required for a new explicit v2 route before the gated default flip. `auto` is artifact-first and only selects v2 for a new task with a current all-pass rollout report. `HARNESS_PROTOCOL=v1` remains the immediate rollback switch.

## Profile contracts

| Profile | Persistence | Harness writes | Required behavior |
|---|---|---|---|
| Inspect | ephemeral | none | read-only inspection and appropriate verification |
| Direct | ephemeral | no task/runtime/current state or task artifact | focused verification, self-review, and honest gaps |
| Governed | durable | transactional v2 state and explicit artifacts only | verification and durable Evidence; planning/audit only when policy requires them |
| Critical | durable | same transaction boundary | plan, Approval, rollback, independent audit, verification, Evidence, and dry-run |

Ask is `requirement_state=blocked`, not a fifth profile. Legacy `quick` and `workflow` are compatibility aliases for Direct and Governed; they do not create a second policy source.

## Safety invariants

- Direct never loads lifecycle skills and never creates task state, runtime pointers, recovery entries, or durable task artifacts.
- A protected write cannot rely on natural-language intent alone. The Codex adapter sends Bash command text to core policy. Codex 0.144.4 does not bind the effective environment identity/cwd into PreToolUse, and a foreign primary may make the deprecated Hook cwd fall back to the local host cwd. Therefore shell-form and direct `apply_patch` are both rejected before core evaluation, even when the patch omits an Environment ID and looks local. Fine-grained patch-path allow decisions remain unavailable until the host supplies a trustworthy execution-environment binding. The pinned `permission_mode` values (`default` and `bypassPermissions`) are approval-policy labels, not a Plan/read-only collaboration signal.
- The ordinary user Hook is a guardrail, not a complete enforcement boundary. Its transparent Windows chain is qualified with the Codex 0.144.4 environment-shell invocation shape under `cmd.exe /C`, PowerShell 7, and Windows PowerShell, plus pinned absolute PowerShell executables. Harness does not write trust or create/take ownership of managed policy; an upgrade may only retire an exact, registry-proven legacy Harness `managed_config.toml` by restoring its original baseline and then releasing ownership. The registry tombstone is accepted only when a real release manifest binds the target, covered history, and stable plan digest; it remains authoritative across workspace-owner handoff until the final registry is removed. Synthetic command-fixture tests do not establish active trust or endpoint-product allowlisting. If enterprise policy or endpoint isolation blocks the script, the Hook is unavailable and Critical production execution still requires the independent executor defined by release policy.
- Requested aliases may raise but cannot lower the computed profile.
- Critical capabilities are an exact minimum set. Missing capability fields or unknown policy keys are rejected.
- Read-only inspection is zero-write even when optional providers, Memory, or policy infrastructure are unavailable.
- Execution results, actors, model ids, and tool ids belong to Event/Evidence metadata, not the Requirement Contract.

## Validation and rollback

`tests/verify-v2-policy-contracts.ps1`, `tests/verify-v2-requirement-gate.ps1`, `tests/verify-v2-direct-no-artifacts.ps1`, `tests/verify-v2-approval.ps1`, `tests/verify-v2-install-presets.ps1`, and the scenario evals cover the policy boundary and installed command fixtures. The install preset test verifies allow/deny JSON under cmd, PowerShell 7, and Windows PowerShell parsers; it does not mark Codex trust, Hook activation, or Flylink/endpoint policy as passed. Any unavailable required rollout evidence keeps `auto` on v1.

Rollback sets `HARNESS_PROTOCOL=v1` or reverts the relevant v2 PR. Existing v1 five-stage tasks and their install, update, uninstall, recovery, and validation paths remain unchanged.
