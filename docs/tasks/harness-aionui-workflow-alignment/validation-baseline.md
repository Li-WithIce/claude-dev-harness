# Validation Baseline: Harness AionUi Workflow Alignment

This document establishes the current validation state of the `claude-dev-harness` as of 2026-04-24, focusing on workflow, orchestrator, team, and skill behavior in preparation for AionUi alignment.

## Current Validation Inventory

### 1. Core Harness & Lifecycle
Verified through:
- `tests/verify-harness-entry.ps1`: Ensures `harness.ps1` and `harness.cmd` correctly delegate and handle parameters.
- `tests/verify-installation.ps1`: Validates the installation process, including skill copying and backup mechanisms.
- `tests/verify-install-isolation.ps1`: Ensures installation doesn't leak into parent directories.
- `tests/verify-uninstall-isolation.ps1`: Ensures uninstallation only removes managed assets.
- `tests/verify-update-managed-assets.ps1`: Tests the script responsible for syncing assets from templates.

### 2. Memory Management (Obsidian Vault)
Verified through:
- `tests/verify-memory-maintain.ps1`: Checks the health of the Obsidian vault and fixes common issues.
- `tests/verify-memory-health-report.ps1`: Validates the generation of health reports for the memory vault.
- `tests/verify-repair-shared-memory.ps1`: Tests the ability to recover from corrupted memory states.
- `tests/verify-archive-memory-candidates.ps1`: Validates the logic for moving old runtime logs to archives.

### 3. Workflow & Orchestration
Verified through:
- `tests/verify-workflow-contracts.ps1`: The primary validator for workflow state transitions and file structure integrity.
- `tests/verify-runtime-inbox.ps1`: Validates the `append-runtime-inbox.ps1` mechanism for capturing external feedback.
- `tests/verify-triage-runtime-inbox.ps1`: Tests the logic for triaging raw inbox items into actionable tasks.
- `tests/verify-promote-runtime-inbox.ps1`: Validates moving triaged items into the runtime execution pipeline.
- `tests/verify-runtime-hooks.ps1`: Ensures pre/post-execution hooks are correctly triggered.

### 4. Artifact & Footprint Integrity
Verified through:
- `tests/verify-lite-artifact-validator.ps1`: Ensures that "lite" distributions contain only the necessary runtime files.
- `tests/verify-lite-footprint.ps1`: Validates that the harness doesn't exceed its intended disk/file-count footprint.

## Identified Gaps for AionUi Alignment

The following areas lack automated validation and are critical for successful AionUi integration:

1.  **Skill Schema Validation:** No tests currently verify that `SKILL.md` or associated metadata files conform to AionUi's expected JSON schemas for tool definitions.
2.  **Multi-Agent Coordination:** Current tests focus on single-agent workflows. There is no validation for the "Team" mechanics (e.g., `team_send_message`, `team_task_update`) in a simulated AionUi environment.
3.  **Platform Agnosticism:** The harness is heavily dependent on PowerShell (`.ps1`). AionUi alignment may require validating that core logic remains functional or accessible in non-Windows environments or via non-PS triggers.
4.  **State Synchronization:** Lack of validation for syncing AionUi's "native" memory/state with the harness's Obsidian-based memory vault.
5.  **AionUi Skill Registry Integration:** No regression checks for `aionui-skills` activation and resource usage.

## Proposed New Regression Checks

To support the AionUi alignment, the following tests should be added:
- `tests/verify-aionui-skill-contract.ps1`: Validates that all skills under `skills/` match the AionUi-standard interface.
- `tests/verify-team-orchestration.ps1`: A mock test-bed for verifying that orchestrators can correctly assign and track tasks across multiple agents.
- `tests/verify-memory-bridge.ps1`: Ensures that updates in the Obsidian vault are correctly reflected in a format compatible with AionUi state persistence.
