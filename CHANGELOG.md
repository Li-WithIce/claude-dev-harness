# Changelog

## Unreleased

- Make Requirement-Safe Thin Harness v2 the primary user path: install Core, open the workspace in Codex Desktop, and describe the requirement directly.
- Add Requirement Gate routing for Ask/Direct/Governed/Critical with version-bound task state, Evidence, Approval, protected actions, and fail-closed recovery.
- Add a transparent ordinary-user Codex `PreToolUse` guard for Windows environment-shell runners: preserve lossless third-party hook data (including exact BigInteger/decimal values) and enterprise/trust authority, transactionally retire only registry-proven legacy Harness managed policy, and fail closed on shell-form or direct `apply_patch` while the pinned host lacks a trustworthy execution-environment binding, without hiding or encoding the launcher.
- Preserve artifact-first v1 compatibility, explicit `HARNESS_PROTOCOL=v1` rollback, isolated linked-worktree bootstrap, and core/governed/full install-update-uninstall ownership.
- Add revision-bound model/host/rollout qualification, fail-closed canonical v2 discovery, and explicit offline promotion that preserves v1 artifact precedence and rollback; missing, stale, failed, simulated, blocked, or unavailable evidence keeps `auto` on v1.
- Add a read-only health/status view that distinguishes installed Hook registration from unknown trust/callability, verifies the pinned Host version when observable, reports Protected Action policy separately from unavailable Desktop enforcement, and validates the canonical rollout report without changing workspace state.
- Keep the Codex global entry as a minimal host overlay, give Claude and the workspace only the same short protocol bootstrap, and defer the complete v1 route/Ask/Inbox/Recovery contract to `entry-router` and `orchestrator` after v1 selection.
- Keep `.assistant/` as local user/workspace state and remove tracked vault/runtime files from the repository surface.
- Keep provider integrations optional/advisory and out of default install/validation paths.
- Remove the required Node.js command dependency from the harness installation path.
- Add Windows quick/core validation in GitHub Actions.
- Harden workflow descriptor validation for stage order, required fields, and provider-like stage/skill drift.
- Add governance documents for contribution, security reporting, and pull request review.
