# Per-Stage Tool Selection

lite workflow 不维护自动推导矩阵；`tool` 仍是当前 stage 的显式 backend 字段。Phase 1 增加 opt-in `tool_profile` 描述符，用来记录 backend/model/skill 预设；Phase 2 再增加可选 `agent-configs/workflows/harness-lite.yaml`，只作为下一 stage 的最后一级 fallback。

## 合法 tool

- `claudecode`
- `codex`
- `none`：只允许用于 `DONE`

## 默认 profile

默认 profile 描述符位于 `agent-configs/profiles/`：

- `harness-default-claude`：`backend: claudecode`、`model: inherit`
- `harness-default-codex`：`backend: codex`、`model: inherit`

可选 workflow descriptor 位于 `agent-configs/workflows/harness-lite.yaml`，每个 stage 只声明：

- `role`
- `default_profile`
- `skills_whitelist`

当前 `harness-lite` descriptor 是 Codex-only：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST` 默认使用 `harness-default-codex`。`harness-default-claude` 保留为显式切换选项。

规则：

- `plan.md` 可选写 `tool_profile: <name>` 和 `model: inherit | <full-model-id>`
- 存在 `tool_profile` 时，`tool` 必须等于 profile 描述符里的 `backend`
- 当前 stage 的 `tool_profile/model` 只是活跃记录，不会作为下一 stage 的黏性 fallback
- `model` 可为 `inherit`；显式覆盖必须是完整模型 ID，不写 `opus`、`pro`、`latest` 这类短别名

## 规则

- `plan.md` frontmatter 的 `tool` 表示“当前 stage 由哪个工具继续”
- 新任务进入首个 stage 前，未显式指定时默认使用 `tool: codex` 与 `harness-default-codex`
- 非 `DONE` 推进的 fallback 顺序固定为：显式 `-Tool` → 显式 `-Profile` → workflow descriptor `default_profile`
- `cli-profile`：`-Tool` 为空、`-Profile` 非空时，先从 `profile.backend` 解析 tool，再沿用 Phase 1 profile/model 写回
- `cli-tool + explicit -Profile/-Model`：继续沿用 Phase 1 语义与 mismatch rejection
- `pure cli-tool`：显式传 `-Tool`、未传 `-Profile/-Model` 时，下一 stage 会清空继承的 `tool_profile/model`
- 当 `-Tool` / `-Profile` / workflow-default 都缺失时，非 `DONE` 推进才会报 `requires -Tool`
- `TEST -> DONE` 固定写 `tool: none`
- 用户可以在任意 stage 边界切换 tool

## skills_dirs 消费面

- Phase 3 里，`skills_dirs` 只服务于 `scripts/invoke-harness-skill.ps1` 的 skill 查找语义
- 解析顺序是：task-level `skills_dir`（保留字段，当前忽略） -> project-level `.assistant/skills` -> user-level active profile/backend 对应的 `skills_dirs`（例如 `%USERPROFILE%\.claude\skills`、`%USERPROFILE%\.codex\skills`）
- `install.ps1` / `uninstall.ps1` 不读取 `skills_dirs`，也不受 active profile 影响
- `scripts/generate-skills-index.ps1` 和 `docs/tasks/{task_id}/skill-manifest.json` 只消费 workflow whitelist + repo 内 `skills/<id>/SKILL.md` 描述，不反向改 profile

## profile 在 team preset 中的角色

- Phase 4 的 `scripts/export-team-preset.ps1` 仍以 `agent-configs/workflows/harness-lite.yaml` 为 stage 真相源
- 每个 stage 的 `default_profile` 决定导出 preset 时的 `backend` 与 `model`
- `role_prompt_ref` 来自 `agent-configs/role-prompts/<role>.md`
- 单写者保护集合不从 profile 派生；统一固定为 `.assistant/` 与 `docs/tasks/{task_id}/`

## 不再存在的概念

- 不再写历史默认矩阵名称
- 不再写独立的“下一执行者”字段
- 不再从 `(stage, profile)` 反推执行者
