---
task_id: aa55f292
task: 整理任务板状态不同步的最小复现与收口建议
owner: quiet-runner-committer
updated: 2026-05-11
status: reported
scope: task-board-only
---

# Task Board Status Sync Closeout

## Minimal Reproduction

Observed sequence:

1. `team_task_list` showed `[aa55f292] ... (pending, owner: quiet-runner-committer)`.
2. `team_task_update` was called with `task_id=aa55f292` and `status=in_progress`.
3. The tool returned success: `Task aa55f292 updated. Status: in_progress.`
4. A follow-up `team_task_list` still showed `[aa55f292] ... (pending, owner: quiet-runner-committer)`.

The same pattern was previously observed for `8cf7305d`: update calls returned success for `in_progress` and `completed`, but the board list continued to show the task as `pending`.

## Evidence

- Current active team members are only `Leader` and `quiet-runner-committer`.
- The board still lists 88 tasks as `pending`.
- 84 of those pending tasks are owned by agents that are no longer active team members, for example `workflow-editor`, `workflow-reviewer`, `codex-only-editor`, `codex-config-cleaner`, `design-reviewer`, and `mdhtml-finalizer`.
- One pending task is unassigned: `a184b530`.
- Three pending tasks are owned by the current active teammate: `8467e438`, `8cf7305d`, and `aa55f292`.
- `8467e438` still appears pending even though the repository HEAD is `4c789af test(workflow): add quiet validation runner`, which landed the quiet validation runner work.
- Recent repository history includes completed work that maps to still-pending board entries, such as `70a0362 feat(workflow): refine md-html reading strategy`, `71c4668 feat(workflow): add md-html artifact boundary skill`, and `ea1f80e fix(codex): keep user config.toml immutable`.

## Boundary

This is a platform or task-board state synchronization issue. It is not caused by the `D:\data\claude-dev-harness` repository code.

The repository working tree was clean before this status note was created, and this task did not touch business code, validation scripts, runtime scripts, or workflow implementation files.

## Operational Guidance

- Treat commit hashes, review/test PASS reports, and a clean working tree as the source of truth for completed repository work.
- Still call `team_task_update status=completed` immediately after each completion report, because text such as "completed" or "已完成" does not automatically mutate board state.
- For commit tasks, mark complete only after the commit hash/title and clean working tree are confirmed.
- For review and test tasks, mark complete after a clear PASS/FAIL report; on FAIL, create or assign a follow-up repair task instead of leaving the review task ambiguous.
- Do not rely on owner lifecycle cleanup. If an agent is shut down or removed, its tasks can remain pending and should be reassigned, closed, or marked stale by the leader.
- Batch-close historical stale tasks after checking commit/artifact evidence. If the board supports archival, use archived for old coordination records; otherwise close them as completed with a stale-close note in the leader handoff.
- Before further large cleanup, investigate why `team_task_update` returns success while `team_task_list` does not reflect the new status. Without that fix, manual status hygiene will continue to drift.
