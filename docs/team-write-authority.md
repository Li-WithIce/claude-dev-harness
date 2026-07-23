# Team Write Authority

## Member read-only path prefixes

- `.assistant/`
- `docs/tasks/{task_id}/`

## Team preset contract

`scripts/export-team-preset.ps1` exports the harness-side preset consumed by AiTeamCode/team hosts:

```yaml
name: harness-lite
version: 1
single_writer:
  owner: leader
  members_read_only_path_prefixes:
    - .assistant/
    - docs/tasks/{task_id}/
members:
  - role: plan-author
    backend: codex
    model: inherit
    skills_whitelist: [plan, entry-router]
    role_prompt_ref: agent-configs/role-prompts/plan-author.md
```

Consumers may add host-local fields when spawning agents, but must not write those fields back into the static preset.

## Leader sole-writer scope

- 在以上两组前缀下的所有写入路径，都只允许 leader 或 leader 间接调用的 repo 脚本落盘
- 包括但不限于：
  - `docs/tasks/{task_id}/plan.md`
  - `docs/tasks/{task_id}/test.md`
  - `docs/tasks/{task_id}/skill-manifest.json`
  - `docs/tasks/{task_id}/skills-index.md`
  - 任意 `.assistant/` 文件

## Member authority

- spawned member 在上述前缀下全部只读
- member 的结果通过 `team_send_message` 回 leader
- 是否写入真相源、是否推进 stage、是否提交代码，都由 leader 决定
- `team_task_update` 是 host task board mirror，不回写 vault 真相字段

## Forbidden member operations

- 对 `.assistant/` 或 `docs/tasks/{task_id}/` 前缀内路径直接执行 `Set-Content`
- 对上述前缀内路径直接执行 `Out-File`
- 对上述前缀内路径直接执行 `git commit -m ... -- <prefix>/...`
- 直接调用 `advance-stage.ps1`
- 通过 `team_task_update` 改写 task state

## Enforcement

- 本 Phase 只做静态拦截，不做 runtime hook 强制
- `tests/verify-team-orchestration.ps1` 的 `O5` 负责前缀级静态扫描
- preset、role-prompt、测试都复用这两条前缀，不再维护单文件例外表
