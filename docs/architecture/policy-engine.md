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

`HARNESS_PROTOCOL=v2` and workspace `enable-v2` remain unconditional new-task opt-ins. `auto` is artifact-first and, after workspace config, consumes only a valid version-independent Runtime Default Decision; Qualification Reports are not Runtime inputs. `HARNESS_PROTOCOL=v1` remains the immediate rollback switch.

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
- A protected write cannot rely on natural-language intent alone. Ordinary file-mutation adapters send only target paths to core policy and keep file bodies out of `command_text`; direct `apply_patch` strictly extracts every Add/Update/Delete/Move target, while `Write`, `Edit`, `MultiEdit`, and `NotebookEdit` use target-path fields. Future equivalent adapters must preserve `target path -> Core Policy` and `file body -> not command policy`. Core still enforces Workspace containment, reparse boundaries, read-only sessions, protected paths, and workspace overlays; missing `cwd`, malformed or target-free patches, path escape, and actual Host/OS denial fail closed. Bash sends its real command text, and shell-form `apply_patch` / `applypatch` remains denied because the Hook lacks its effective tool workdir/environment binding. The `permission_mode` values (`default` and `bypassPermissions`) are approval-policy labels, not a Plan/read-only collaboration signal.
- An explicitly authorized database credential or external-service key may be persisted to the user's named Workspace configuration file, including production configuration. This ordinary Runtime capability is version-neutral and does not depend on Release Qualification, Vault, KMS, a Secret Provider, or exact model/Host names. A production-looking path, secret-shaped field, tracked/ignored state, or `HARNESS_ENVIRONMENT=production` does not by itself make the file write protected. Persistence is not disclosure: sensitive values stay out of replies, logs, task artifacts, Evidence, review receipts, PRs, CI artifacts, snapshots, documentation, and unrelated files.
- The ordinary user Hook is a guardrail, not a complete enforcement boundary. Its transparent Windows chain has deterministic coverage under `cmd.exe /C`, PowerShell 7, and Windows PowerShell, plus pinned absolute PowerShell executables. Exact Host qualification belongs to the release policy, not this runtime contract. Harness does not write trust or create/take ownership of managed policy; an upgrade may only retire an exact, registry-proven legacy Harness `managed_config.toml` by restoring its original baseline and then releasing ownership. The registry tombstone is accepted only when a real release manifest binds the target, covered history, and stable plan digest; it remains authoritative across workspace-owner handoff until the final registry is removed. Synthetic command-fixture tests do not establish active trust or endpoint-product allowlisting. If enterprise policy or endpoint isolation blocks the script, the Hook is unavailable and Critical production execution still requires the independent executor defined by release policy.
- Requested aliases may raise but cannot lower the computed profile.
- Critical capabilities are an exact minimum set. New task state persists `dry_run_required=true`; an older task document that predates the optional field derives the same invariant from `execution_profile=critical`, while an explicit false value is rejected. The successful dry-run itself must be carried by the bound `evidence/v1` `dry_run` object; Hook input is not completion Evidence. Unknown policy keys are rejected.
- Read-only inspection is zero-write even when optional providers, Memory, or policy infrastructure are unavailable.
- Execution results, actors, model ids, and tool ids belong to Event/Evidence metadata, not the Requirement Contract.

## Validation and rollback

`tests/verify-v2-policy-contracts.ps1`, `tests/verify-v2-requirement-gate.ps1`, `tests/verify-v2-direct-no-artifacts.ps1`, `tests/verify-v2-approval.ps1`, `tests/verify-v2-install-presets.ps1`, `tests/verify-runtime-qualification-decoupling.ps1`, and the scenario evals cover the policy boundary and installed command fixtures. The install preset test verifies allow/deny JSON under cmd, PowerShell 7, and Windows PowerShell parsers; it does not mark Host trust, Hook activation, enterprise endpoint policy, Release Qualification, or production execution as passed. A missing or invalid Runtime Default Decision keeps `auto` on v1; unrelated unavailable Host facts do not block explicit v2 or Direct.

Rollback sets `HARNESS_PROTOCOL=v1` or reverts the relevant v2 PR. Existing v1 five-stage tasks and their install, update, uninstall, recovery, and validation paths remain unchanged.
