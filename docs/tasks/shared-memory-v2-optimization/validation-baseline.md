# Validation Baseline: Shared Memory v2 Optimization

## 1. Existing Scripts and Checks

Currently, the workspace relies on the following operational scripts to manage and verify shared memory integrity. There is a distinct lack of automated *tests* validating the shared memory invariants; the reliance is primarily on utility scripts.

*   **`scripts/memory-health.ps1`**:
    *   **Purpose**: Validates the structural integrity and configuration of the shared Obsidian memory vault.
    *   **Covered Checks**:
        *   Existence of the `D:\data\claude-dev-harness\.assistant` directory.
        *   Absence of redundant `.obsidian` configurations (checks against `<root>/.assistant/.obsidian` vs `<root>/.assistant/.obsidian/.obsidian`).
        *   Absence of scattered `app.json` or `appearance.json` files in the root `.assistant` directory.
        *   Presence of critical configuration files (`.obsidian/app.json`, `.obsidian/appearance.json`).
        *   Verification that `app.json` does not enforce strict line breaks (a known rendering issue).
    *   **Behavior**: Outputs `[PASS]` or `[FAIL]` status for each check and exits with a non-zero code if structural issues are found.

*   **`scripts/repair-shared-memory.ps1`**:
    *   **Purpose**: Attempts to automatically remediate structural and configuration issues identified by `memory-health.ps1`.
    *   **Actions**:
        *   Creates missing core `.obsidian` configuration files from a known good template.
        *   Removes duplicate/nested `.obsidian` folders.
        *   Cleans up improperly placed configuration files (`app.json`, `appearance.json`) from the root `.assistant` directory.

*   **`scripts/memory-maintain.ps1`**: Provides maintenance operations (specific implementation details not fully analyzed for this baseline, but structurally present).
*   **`scripts/resolve-obsidian-memory-script.ps1`**: Path resolution script for locating the Obsidian memory script.
*   **`scripts/archive-memory-candidates.ps1`**: Archival utility for memory management.

## 2. Covered Invariants

Based on the existing scripts, the following invariants are currently enforced (primarily structurally, via `memory-health.ps1`):

1.  **Vault Structural Integrity**: The vault directory (`.assistant`) must exist.
2.  **Configuration Canonicalization**: There must be exactly one `.obsidian` configuration directory, located at `<vault-root>/.obsidian`.
3.  **No Nesting/Duplication**: Redundant configuration structures (like `.assistant/.obsidian/.obsidian`) are explicitly prohibited and checked for.
4.  **No Configuration Bleed**: Core Obsidian config files (`app.json`, `appearance.json`) must not exist outside the designated `.obsidian` folder.
5.  **Specific Setting Validation**: The `strictLineBreaks` setting in `app.json` is validated to prevent markdown rendering issues.

## 3. Identified Gaps

The current validation baseline reveals significant gaps, particularly regarding operational safety, synchronization, and formal testing. The system lacks automated validation (`tests/*.ps1`) for shared memory behavior during active CLI operations.

*   **Runtime-State Drift**:
    *   **Gap**: There is no mechanism or test to detect if the local workspace state (e.g., modified configuration files, active environment variables) has drifted out of sync with the canonical representation stored in the shared memory vault. The CLI tools might operate on stale local state if the memory vault is updated asynchronously.

*   **Lock/Writeback Enforcement**:
    *   **Gap**: There is no validated lock mechanism for concurrent access to the shared memory vault.
    *   **Gap**: There is no formalized or tested writeback contract ensuring that modifications made during a session are safely and atomically persisted back to the canonical shared memory without risking corruption or race conditions.

*   **Recovery Freshness**:
    *   **Gap**: When a task is interrupted or fails, there is no validation to ensure that the recovery context pulled from shared memory is the *most recent* valid state. There is a risk of recovering to an outdated snapshot if writebacks fail silently or are delayed.

*   **Canonical-Vault Enforcement**:
    *   **Gap**: While `memory-health.ps1` checks for structural issues within the intended `.assistant` vault, there is no system-level enforcement preventing agents or tools from creating *parallel* or *unmanaged* memory structures outside of `D:\data\claude-dev-harness\.assistant`. The strict reliance on this single path needs stronger isolation and validation.

*   **Test Coverage**:
    *   **Gap**: Zero automated tests (`tests/verify-*.ps1`) exist that specifically target the shared memory invariants. The current reliance is entirely on ad-hoc execution of health scripts.

## Summary

The current baseline establishes a strong structural foundation for the Obsidian memory vault but lacks the necessary operational guardrails (locking, synchronization, writeback contracts) and formal automated testing to ensure safety and consistency in a multi-agent or concurrent workflow environment. Phase 2 optimizations must address these synchronization and contract validation gaps.