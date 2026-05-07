---
task_id: 85ff35b0
stage: PLAN
tool: codex
updated: 2026-04-30
---

# Codex Startup Smoke Test — 范围钉死

## Clarification

- **任务定位**：read-only planning。本 plan.md 只把 smoke test 的边界、判据、风险写清楚，不实际跑 smoke、不动代码、不动 config.toml。是否进入 IMPLEMENT 由 Leader 决定。
- 验收标准:
  1. plan.md 写清要验证的启动路径/命令、成功判据、已知风险（含 sandbox_mode / config.toml / teammate launch）、非目标
  2. 不需要新 SKILL、新 stage、新 validator gate、新 test 文件
  3. 如果范围已足够清晰可直接 smoke，明确写出"建议直接进入 smoke"的理由；否则保留观察项
- 非目标:
  - 不修复 codex CLI 自身的 CRLF 写入 bug（不在 harness 范围）
  - 不重写 install.ps1 / update-managed-assets.ps1 的 codex 配置逻辑
  - 不引入新的 codex backend
  - 不做性能或长任务回归
- 受影响目录: `docs/tasks/85ff35b0/`（仅 plan.md，本轮）
- 回滚策略: 删除 `docs/tasks/85ff35b0/plan.md` 即可（read-only artifact）
- ui: not-applicable

## 1. 要验证的启动路径 / 命令

Codex 在本仓库的"startup"有 **3 条独立入口**，smoke 至少需覆盖前两条：

### 入口 A — `skills/codex` 单次问询（ask_codex）

- 入口脚本：`skills/codex/scripts/ask_codex.ps1`（Windows）/ `ask_codex.sh`（POSIX）
- 启动行为：拉起一次性 codex CLI 进程，传入 task 文本 + 可选文件，返回输出后退出
- 依赖：`C:\Users\28796\.codex\config.toml`（含 harness managed block）+ codex CLI 可执行（PATH 上）
- 最小 smoke 命令（建议）：
  ```pwsh
  pwsh -File skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly
  ```

### 入口 B — `harness-default-codex` profile + advance-stage

- 入口脚本：`.assistant\entry\advance-stage.ps1 -TaskId <id> -Tool codex -Profile harness-default-codex -Model gpt-5.5/xhigh`
- 启动行为：基于 profile YAML 解析 backend = codex，触发 codex CLI 加载（仍走 config.toml）
- profile 文件：`agent-configs/profiles/harness-default-codex.yaml`
- 最小 smoke 命令（建议，对一个临时无害任务）：
  ```pwsh
  pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <probe-task> -Tool codex -Profile harness-default-codex -Model gpt-5.5/xhigh -DryRun
  ```
  （`-DryRun` 是建议名；若 advance-stage 当前不支持，则改用本地 review-probe-* 类型的现成 plan.md 为目标）

### 入口 C — workflow-team `team_spawn_agent`（不在 smoke 主范围）

- 入口脚本：`skills/workflow-team/scripts/spawn-team.ps1`
- 启动行为：通过 AionUi MCP 拉 codex 子进程作为 teammate
- **不纳入本 smoke**：依赖 live MCP 协议层，对应 gap-analysis G6（live AionUi end-to-end smoke），属另一条线，开新任务再做。

## 2. 成功判据

| # | 入口 | 成功判据 |
|---|---|---|
| A1 | ask_codex.ps1 -ReadOnly | 进程 exit code = 0；stdout 含模型回应非空文本；stderr 不含 `TOML parse error` / `failed to load config` |
| A2 | ask_codex.ps1 -Sandbox workspace-write | 同 A1，且不出现 `permission denied` |
| B1 | advance-stage with codex profile | profile 解析成功（不报 unknown backend / unknown profile）；下一阶段 frontmatter 正确写入；stderr 无 codex CLI 启动失败迹象 |

**任一判据 fail → 立即停下，记录到 finding，不要硬推**。

## 3. 已知风险（重点：sandbox_mode / config.toml / teammate launch）

引用：`docs/tasks/sandbox-mode-writeback-investigation/validation.md`（已 commit `22b40c3`）

### R1 — Codex CLI 自身污染 config.toml（高）

- 现象：codex CLI 在用户区域写入 `personality = "pragmatic"\r sandbox_mode = "workspace-write"\r\n`，缺少行尾 `\n`，TOML 不可解析
- 影响：codex 启动直接 fail，stderr 报 TOML parse error
- 缓解：smoke 前先 `Get-Content -Raw C:\Users\28796\.codex\config.toml | Format-Hex | Select-String '0D 20'` 检查是否有 lone CR；发现则手动修复后再 smoke
- **不在 harness 修复范围**：harness 已确认 install.ps1 只动 managed block，不改用户区

### R2 — Harness 跑 install.ps1 会把 R1 的污染往后保留（中）

- 现象：每次 install 把当前 user region verbatim 复制下来；如已被污染则继续被污染
- 影响：smoke 前如果跑过 install / update-managed-assets，污染依然在
- 缓解：smoke 前**不要**主动跑 install.ps1；如必须跑，先确认 user region 干净

### R3 — teammate launch 路径与 ask_codex 路径配置共享（中）

- 现象：workflow-team `team_spawn_agent` 拉起的 codex teammate 与 ask_codex.ps1 共享同一份 config.toml
- 影响：R1 同时影响入口 A、B、C
- 缓解：本 smoke 不覆盖入口 C，但若 A1/A2 fail，可推断 teammate 也不能起，无需额外验证

### R4 — 模型 ID `gpt-5.5/xhigh` 是否被 codex 当前版本接受（低-中）

- 现象：profile 写死了 `model: gpt-5.5/xhigh`，但 codex CLI 端可能不识别
- 影响：B1 fail
- 缓解：B1 fail 时不自动判 harness 问题，先单独 `codex --model gpt-5.5/xhigh` 验证 CLI 端是否接受该 model id

### R5 — Sandbox 模式不一致（低）

- 现象：profile 不显式设置 sandbox；ask_codex 通过 `-Sandbox` 参数运行时传；config.toml 用户区可能也写了 `sandbox_mode`
- 影响：runtime 行为可能与预期不一致（read-only 写入失败 / 写入未隔离）
- 缓解：smoke 时显式带 `-ReadOnly` 或 `-Sandbox`，不依赖 config.toml 默认

## 4. Smoke 推进建议

### 范围已足够清晰，建议直接进入 smoke 的理由

- 入口 A、B 命令已写明，依赖文件路径已确认存在
- R1-R5 已枚举，每条都有明确的 fail 判据和缓解动作
- 不需要新代码、新 SKILL、新 validator
- 失败时的处置路径清晰（分别归 codex CLI bug / harness 配置 / model id / sandbox 配置）

### 建议的 smoke 顺序（由 Leader 决定是否执行）

1. **Pre-flight**：检查 `C:\Users\28796\.codex\config.toml` 是否有 lone CR（防 R1）
2. **A1**：`ask_codex.ps1 -Task "echo hello" -ReadOnly` → 验证最小入口
3. **A2**：`ask_codex.ps1 -Task "...write a one-line file..." -Sandbox workspace-write` → 验证写入沙箱
4. **B1**：在已有 `review-probe-misordered` 之类的 read-only sample plan 上跑一次 `advance-stage -Tool codex -Profile harness-default-codex` → 验证 profile + advance-stage 联动
5. 入口 C 不在本 smoke 范围

每一步任一 fail 立即停下，写 finding 到本 plan 的 `## Implementation Notes` section（如果进入 IMPLEMENT 阶段），或单独开新任务。

## 5. 不在范围内（再次强调）

- 不修复 codex CLI 写入 bug（R1 根因不在 harness）
- 不动 install.ps1 / update-managed-assets.ps1
- 不动 advance-stage.ps1
- 不动 profile YAML（除非 B1 暴露 profile 自身错误）
- 不做长任务 / 多 stage / 跨会话场景
- 不覆盖入口 C（teammate launch via MCP）

## User Confirmation

- confirmed: pending（等待 Leader 决定是否进入 smoke 或暂缓）
