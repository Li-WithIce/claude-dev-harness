# Claude Dev Harness

Windows 优先的单仓库 Harness 分发仓库。

## 先说结论

这个仓库最重要的不是 `install.ps1` 本身，而是把同一套 Harness 开发工作流稳定地安装到 Claude / Codex / workspace 上。

- `install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1` 是分发与收敛机制
- `skills/using-superpowers/`、`skills/orchestrator/`、workspace 入口模板、`.assistant` 工作流协议，才是你真正日常在用的开发流程

如果只把它理解成“统一放几个脚本和配置文件的仓库”，那是不完整的。更准确地说，它是在统一管理一套可恢复、可阶段推进、可 review、可 test、可 handoff 的开发执行流。

## 这是什么

这个仓库不是业务应用，也不是单个 skill。它的职责是把一套可运行的 Claude / Codex 开发 Harness 收敛成一个可安装、可验证、可回滚的工作流分发仓库。

安装完成后，它会把以下能力接到宿主环境上：

- `skills/` 作为 Claude / Codex 共用单源
- `runtime-hooks/claude/` 托管 Claude 运行时 hooks
- `agent-configs/` 托管 Claude / Codex / workspace 模板
- `vault-template/` 提供共享记忆仓库初始化骨架
- `install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1` 形成安装、验证、回滚闭环

如果你要解决的是“如何在一台新机器上把整套 Harness 装起来，并让 Claude / Codex 共用同一份 skills、同一套工作区入口和共享记忆骨架”，这个仓库就是为此准备的。

## Harness 架构

可以把这套 Harness 理解成 5 层：

| 层 | 作用 | 仓库落点 |
|---|---|---|
| 入口路由层 | 对话开始先判断任务类型，开发任务优先进入主流程 | `skills/using-superpowers/` |
| 阶段治理层 | 用固定 stage machine 推进开发任务 | `skills/orchestrator/` |
| 任务制品层 | 为每个任务沉淀 plan / review / test / handoff 等 artifact | `<workspace-root>/docs/<task-id>/` |
| 共享运行时层 | 记录当前任务、恢复索引、中断任务、上次会话 | `<workspace-root>/.assistant/运行时/` |
| 分发收敛层 | 把上述能力安装到宿主，并验证安装结果 | `install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1` |

这里最关键的边界是：

- 工作流本体不等于安装脚本
- 安装脚本只是把工作流入口、状态协议、skills、hooks 和模板落到宿主
- 你的日常开发，主要发生在工作区 `docs/<task-id>/` 和 `.assistant/运行时/`，不是这个仓库根目录

## 运行组合

当前仓库对不同本机组合的支持边界可以直接理解为：

| 本机组合 | 能否跑完整工作流 | 当前结论 |
|---|---|---|
| Claude + Codex + 可选 Gemini | 可以 | 推荐组合，支持最好 |
| 只有 Codex | 可以，但有约束 | 可用，需改用 Codex 作为主入口/主 runner |
| Codex + Gemini | 可以，但有约束 | 可用，推荐 Codex 主流程 + Gemini 测试 |
| 只有 Gemini | 不建议，当前不算完整支持 | 只能作为 TEST runner，不是完整 workflow host |

### 推荐预置 Profile

为了避免每次手工脑补 stage bindings，当前建议直接选仓库预置档案：

| 场景 | 推荐 `tool_profile_id` |
|---|---|
| Claude + Codex + Gemini | `claude-codex-gemini-default` |
| 只有 Codex | `codex-only` |
| Codex + Gemini | `codex-gemini` |

这些 profile 的正式定义在：

- `skills/orchestrator/references/default-tool-profiles.md`

它们的意义不是“偷偷存在的默认值”，而是：

- 先把常用组合显式固化
- 让 `current-flow.md`、`handoff.md`、恢复逻辑和 runner 选择都引用同一个名字
- 减少“这台机器现在到底该怎么绑 stage”这种重复决策

### 1. 只有 Codex

可以跑，但不要把它理解成“当前默认配置原封不动照搬”。

可用的原因：

- repo 会把核心 skills 同步到 `%USERPROFILE%\.codex\skills`
- workspace 会有 `AGENTS.md`、`.assistant/` 等共享入口
- `plan` / `implement` / `review` / `test` / `orchestrator` 这些核心 skill 本身并不要求必须由 Claude 执行

约束在于：

- 当前默认示例仍是 Claude-first，不是 Codex-first
- 如果你只有 Codex，应该显式采用 Codex 作为 `entry_tool`，并优先使用 `codex-only`
- 当前仓库仍会创建并维护 `%USERPROFILE%\.claude` 兼容目录；即便机器上不装 Claude，也不要把它当作“完全无用”手动删掉
- 某些兼容性例外路径仍保留了对 `.claude` 目录的依赖，因此“没有 Claude 应用”可以，“完全不存在 `.claude` 兼容目录”不建议

实操上，只有 Codex 时更稳妥的理解是：

- `INTAKE/PLAN/DEV/REVIEW/HANDOFF` 由 Codex 主跑
- `TEST` 也可以先用本地 `test` skill 跑
- 如果没有 Gemini，就不要把 TEST binding 设成 Gemini-first

### 2. 只有 Gemini

当前不建议把它当成完整 workflow host。

原因不是 stage machine 理论上不能绑定 Gemini，而是这套分发仓库目前没有把 Gemini 做成和 Claude/Codex 对等的宿主层：

- 没有 `agent-configs/gemini/`
- 安装脚本不会像处理 `.claude` / `.codex` 那样去托管 `.gemini` 的 skills、settings、全局入口
- 当前 `GEMINI.md` 是 workspace 入口补充，不等于完整的 Gemini 宿主分发
- `gemini-designer-main` 的定位是 TEST runner，不是整个 workflow 的 governor

所以，只有 Gemini 时你最多能做的是：

- 把 Gemini 当 TEST 阶段的只读审证 runner
- 或手工消费 `GEMINI.md` 和工作区 artifacts

但要让它单独承担 `using-superpowers -> orchestrator -> PLAN -> DEV -> REVIEW -> TEST -> HANDOFF` 的完整宿主职责，当前仓库还没做到开箱即用。

### 3. Codex + Gemini

这是当前不依赖 Claude 应用时最现实的一种组合，但仍建议你把 Codex 视为主入口，而不是 Gemini。

推荐分工是：

- `INTAKE/PLAN/DEV/REVIEW/HANDOFF`：Codex
- `TEST`：Gemini 优先，必要时回退本地 `test` / Codex

原因是：

- Codex 这边已经有宿主模板、skills 同步、`config.toml` managed block
- Gemini 在当前架构里更像“专职测试 runner”，而不是“全流程 orchestrator 宿主”

也就是说，`Codex + Gemini` 是能工作的，但模式应当是“Codex 驱动主流程，Gemini 负责 TEST”，而不是双主入口对等治理。

### 如何实际选择 Profile

一个新任务开始时，最稳妥的做法是先把 profile 定下来，再推进 stage：

1. 确认本机组合
2. 选择对应的 `tool_profile_id`
3. 在 `current-flow.md` 中记录：
   - `entry_tool`
   - `tool_profile_id`
   - `tool_profile_source`
   - `tool_bindings`
   - `fallback_bindings`
4. 再进入 `PLAN` 或恢复现有 stage

如果当前环境只匹配一个 repo 预置 profile，可以直接记录为：

- `tool_profile_source: repo-preset`

如果有多个 profile 都可能成立，应该停下来选清楚，而不是让 orchestrator 临时猜。

### 轻量化状态规则

为了避免 workflow 越跑越重，当前 orchestration 状态采用：

- `current-flow.md` 作为唯一真相源
- `handoff.md` 作为派生的用户可见快照
- `stage-history.md` 作为派生的阶段审计日志

这意味着：

- 同一 stage 内的小变更，优先只更新 `current-flow.md`
- 只有真实 stage 变化、恢复锚点重建、对外交接或终态 `HANDOFF` 时，才强制刷新 `handoff.md`
- `stage-history.md` 只在 stage 真正切换时追加，不为每次微调都记一笔

这样保留了 gate 纪律，但把多点写回的负担压低了。

### Artifact 自动校验

为了减少“看起来写了文档，但其实 contract 不完整”的人工判断，仓库现在提供：

```powershell
.\scripts\validate-harness-artifacts.ps1 -CurrentFlowPath <absolute-path-to-current-flow.md>
```

它会做几类检查：

- `current-flow.md` 的基础字段是否完整
- 当前任务 artifact 的 `task_id` 是否和 `current-flow.md` 一致
- `plan.md` / `implementation-notes.md` / `review.md` / `test.md` / `handoff.md` 是否满足最小 contract
- 当 `stage = HANDOFF` 时，是否真的具备 `test.md` 等交付前置证据

它不是安装校验的一部分，而是开发阶段的 gate 辅助脚本。

## 你的开发流程

日常开发真正跑的是下面这条主线：

```text
用户请求
  -> using-superpowers 路由
  -> 开发任务进入 orchestrator
  -> INTAKE
  -> PLAN
  -> DEV
  -> REVIEW(implementation)
  -> TEST
  -> HANDOFF
```

各阶段的职责是：

| 阶段 | 产物 | 含义 |
|---|---|---|
| `INTAKE` | `.assistant/orchestration/current-flow.md`，必要时 `spec.md` | 确认任务身份、输入是否足够、是否要补 delta-spec |
| `PLAN` | `docs/<task-id>/plan.md` | 形成开发主文档，并等用户确认 |
| `DEV` | 代码 diff + `docs/<task-id>/implementation-notes.md` | 真正实现改动并留下实现证据 |
| `REVIEW(implementation)` | `docs/<task-id>/review.md` | 发现 P0/P1/P2 风险，决定是否回修 |
| `TEST` | `docs/<task-id>/test.md` | 给出 `pass` / `fail` / `blocked` 结论 |
| `HANDOFF` | `docs/<task-id>/handoff.md` | 汇总当前交付状态、风险、后续动作 |

### 一个完整示例

下面用一个真实类型的任务举例：

> 用户请求：`verify-installation.ps1` 没有检查宿主 `skills/docs` 中 repo 已不存在的额外陈旧文件，请修复并验证。

#### 1. INTAKE

入口层先把它识别为开发任务，而不是普通问答：

- `using-superpowers` 判断这是 bug fix，导向 `orchestrator`
- `orchestrator` 创建或恢复当前流转状态
- 先更新 `current-flow.md` 与共享运行时：
  - `<workspace-root>/.assistant/运行时/当前任务.md`
  - `<workspace-root>/.assistant/运行时/tasks/fix-preserved-docs-extra-warning.md`
- 如果输入已经足够，就不生成 `spec.md`，直接进入 `PLAN`

这一步的核心不是写代码，而是先把“当前任务是谁、当前在哪个 stage、谁负责写共享状态”钉住。

#### 2. PLAN

然后生成开发主文档：

- `docs/fix-preserved-docs-extra-warning/plan.md`

里面至少会写清楚：

- 问题是什么：当前 verify 只从 repo 侧枚举，没有检查宿主多余文件
- 预期行为是什么：宿主存在 `obsolete-task/review.md` 之类的额外文件时，应返回 `WARN`
- 实现思路是什么：在 `Assert-PreservedDirectoryMatchesRepo` 中增加宿主侧枚举与 `extraCount`
- 风险是什么：不能把 sidecar 或非 docs 范围误报进去
- 怎么验证：构造 sandbox，预置 extra docs，验证 `WARN`；再运行同步脚本，验证恢复为 `PASS`

这份 `plan.md` 经过确认后，才进入 `DEV`。

#### 3. DEV

实现阶段会做两类事情：

- 改代码：
  - 修改 `tests/verify-installation.ps1`
- 写实现证据：
  - 更新 `docs/fix-preserved-docs-extra-warning/implementation-notes.md`

这里的实现动作通常是：

- 增加宿主目录扫描
- 用 repo 相对路径集合对比宿主文件
- 统计 `extraCount`
- 当 `missingCount`、`changedCount`、`extraCount` 任一大于 0 时返回 `WARN`
- 告警里明确提示可运行 `scripts/sync-preserved-docs.ps1`

如果实现过程中用户打断，说一句“继续”，恢复逻辑会从 `.assistant/运行时/恢复索引.md` 往下读，不需要重新靠人工解释上下文。

#### 4. REVIEW(implementation)

实现完成后，不直接结束，而是进入实现 review：

- 产物：`docs/fix-preserved-docs-extra-warning/review.md`

review 会重点检查：

- 是否真的覆盖了宿主额外文件场景
- 是否只检查 `skills/docs`，没有误伤别的保留目录
- warning 文案是否给出正确修复路径
- 有没有引入新的误报或漏报

如果 review 发现 `P0` 或 `P1`，流程会回到 `DEV` 修正；不是“review 走个形式”。

#### 5. TEST

测试阶段再把结论写成独立证据：

- 产物：`docs/fix-preserved-docs-extra-warning/test.md`

一个典型测试脚本流程会是：

```powershell
# 1. 准备 sandbox，并预置与 repo 一致的 skills/docs
# 2. 额外加入 obsolete-task/review.md
# 3. 执行 install
# 4. 执行 verify，预期 STATUS: WARN，且告警包含 extra=1
# 5. 执行 sync-preserved-docs.ps1
# 6. 再次执行 verify，预期 STATUS: PASS
```

`test.md` 的结论只能写三种之一：

- `pass`
- `fail`
- `blocked`

#### 6. HANDOFF

最后才进入交付阶段：

- 产物：`docs/fix-preserved-docs-extra-warning/handoff.md`

这里会汇总：

- 改了什么
- 现在行为是什么
- 用户需要知道的操作，比如 docs-only 变更后如何同步
- 还有没有残余风险

如果这是一次完整收尾，Claude 还会更新：

- `.assistant/运行时/上次会话.md`
- `.assistant/运行时/恢复索引.md`

而在这之前，同一 stage 内的局部实现或小回修，并不要求每次都刷新 `handoff.md`。

#### 7. 这套示例在本仓库里怎么对应

对消费 Harness 的普通工作区，上述 artifact 默认落在：

- `<workspace-root>/docs/<task-id>/`

而这个分发仓库在改造自己时，历史上把任务 artifact 放在：

- `skills/docs/<task-id>/`

这两者不要混淆：

- 前者是你日常开发时的工作流落点
- 后者是这个仓库自己作为被开发对象时留下的 canonical docs 证据

换句话说，工作流本身没有问题；之前让人困惑的，是 README 没先把这两个上下文拆开讲。

恢复与状态管理走的是共享运行时协议：

- 新任务 / 切换任务 / 恢复任务：更新 `<workspace-root>/.assistant/运行时/当前任务.md` 与 `运行时/tasks/<task-id>.md`
- 任务暂停或待续：同步更新 `中断任务.md`
- 阶段收尾：更新 `上次会话.md` 并刷新 `恢复索引.md`
- 用户说“继续”“恢复”时，按 `恢复索引 -> 当前任务 -> tasks/<task-id> -> 中断任务 -> 上次会话` 的顺序恢复

多 agent 分工边界是：

- Claude Code 是共享运行时单写者
- Codex / Gemini 只写任务 artifact 和 `运行时/tasks/<task-id>.md`
- specialist skill 只能在某个 stage 内被调用，不能绕过主流程直接替代 orchestrator

所以，你平时真正使用的不是“安装命令”，而是“路由 + stage machine + artifact contract + shared runtime”这整套纪律。

## 解决什么问题

在改造成这个仓库之前，Harness 依赖的是散落在宿主目录和工作区目录里的资产，例如：

- `%USERPROFILE%\.claude\skills`
- `%USERPROFILE%\.codex\skills`
- `%USERPROFILE%\.claude\hooks-memory`
- `%USERPROFILE%\.claude\CLAUDE.md`
- `%USERPROFILE%\.codex\AGENTS.md`
- `%USERPROFILE%\.codex\config.toml`
- `<workspace-root>\AGENTS.md`
- `<workspace-root>\GEMINI.md`
- `<workspace-root>\.assistant`

这个仓库把它们拆成三层：

| 层 | 进入 Git | 内容 |
|---|---|---|
| shared assets | 是 | `skills/`、canonical docs、共享脚本、验证脚本 |
| host-specific assets | 是 | Claude/Codex/workspace 模板、hooks、Codex managed block |
| user-local runtime | 否 | 真实密钥、用户 overlay、运行时任务状态、宿主本地信任配置 |

核心边界是：

- repo 负责共享资产与宿主模板
- 安装脚本负责把模板渲染到宿主
- 用户本地敏感配置和运行态不进入 Git
- 开发过程本身由 `using-superpowers` + `orchestrator` + `.assistant` 协议统一，不靠人工记忆维持

## 适合谁用

- 你已经在 Windows 上使用 Claude / Codex，并希望它们共用同一套 skills
- 你希望把 `.assistant` 共享记忆骨架、workspace 入口文件、hooks 一起分发
- 你希望安装结果可以被验证，而不是“能跑就算成功”
- 你希望出问题时能基于 manifest 回滚，而不是手动删目录

不适合的场景：

- 只想单独装某一个 skill
- 只需要 README 级别的使用说明，不需要宿主模板和 hooks
- 非 Windows 环境

## 仓库里有什么

| 路径 | 作用 |
|---|---|
| `skills/` | Claude / Codex 共用 skills 单源 |
| `skills/docs/` | 这个仓库自身开发任务的 canonical docs 证据目录；不是你日常开发时的运行态 artifact |
| `scripts/` | 共享记忆维护脚本与辅助同步脚本 |
| `scripts/sync-preserved-docs.ps1` | 把热切换保留的宿主 `skills/docs` 重同步到 repo 当前版本 |
| `runtime-hooks/claude/` | Claude hooks 源文件，安装时渲染到宿主 |
| `agent-configs/` | Claude / Codex / workspace 模板 |
| `vault-template/` | `.assistant` 初始化/补齐模板 |
| `install.ps1` | 安装入口 |
| `uninstall.ps1` | 回滚入口 |
| `tests/verify-installation.ps1` | 安装验证入口 |

## 前置条件

- Windows PowerShell
- 可用的 `node`
- 已存在或准备创建的工作区根目录
- Claude / Codex 宿主目录默认位于 `%USERPROFILE%\.claude` 与 `%USERPROFILE%\.codex`

## 快速开始

### 1. 准备工作区

选一个工作区根目录，例如：

```powershell
<workspace-root>
```

安装后，这里会承载：

- `AGENTS.md`
- `GEMINI.md`
- `.assistant`

### 2. 克隆仓库

```powershell
git clone <your-repo-url> <repo-root>
Set-Location <repo-root>
```

### 3. 按需查看本地 overlay 示例

如果你需要自定义宿主本地配置，先看这些示例文件：

- `agent-configs/claude/settings.local.user.example.json`
- `agent-configs/codex/settings.local.user.example.json`
- `agent-configs/codex/config.user.example.toml`

这些示例只是说明如何扩展本地配置，不应该把真实密钥或私有权限直接提交回仓库。

### 4. 执行安装

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
```

安装脚本会：

- 初始化或补齐 `<workspace-root>\.assistant`
- 渲染并写入：
  - `%USERPROFILE%\.claude\CLAUDE.md`
  - `%USERPROFILE%\.codex\AGENTS.md`
  - `<workspace-root>\AGENTS.md`
  - `<workspace-root>\GEMINI.md`
- 渲染并部署 Claude hooks 到 `%USERPROFILE%\.claude\hooks-memory`
- 合并生成 Claude / Codex 的 `settings.local.json`
- 以 managed block 更新 `%USERPROFILE%\.codex\config.toml`，只托管 Harness 自己的 `[[skills.config]]` 条目
- 保留 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` 根目录为普通目录，并将 repo `skills/` 下的 managed 条目逐项链接进去
- 保留宿主 `skills/` 下的隐藏 sidecar 目录，例如 `.assistant`、`.claude`、`.qoder`
- 将现有 Claude / Codex `.system` 内容合并到 repo-local `skills/.system`
- 写入 install manifest 到 `backups/install-*/install-manifest.json`

### 5. 执行验证

```powershell
Set-Location <repo-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

`verify-installation.ps1` 的结论语义：

| 状态 | 含义 | 退出码 |
|---|---|---|
| `PASS` | 安装结果符合预期 | `0` |
| `WARN` | 安装仍可用，但存在需要人工处理的偏差，例如 preserved docs 漂移 | `1` |
| `FAIL` | 关键安装链路不符合预期 | `2` |

当前验证覆盖：

- `skills` 根目录保持为普通目录
- repo `skills/` 下的 managed 条目逐项链接状态
- sidecar 兼容所需的 `.system` 可见性
- Claude hooks 渲染
- Claude / Codex `settings.local.json` 结构
- Codex `config.toml` managed block 内容与 Harness 托管 skill path 泄漏检查
- 热切换保留的 `skills/docs` 内容漂移检查
- `agent-configs/codex/*.toml` forbidden prefix 检查
- `scripts/memory-health.ps1 -VaultRoot <workspace-root>\.assistant` 返回 `STATUS: PASS`

## 仓库运维流程

### 场景 1：首次安装

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

目标结果：`STATUS: PASS`

### 场景 2：仓库更新后重新收敛宿主

当你拉取了新的 repo 变更，并且这些变更涉及 `skills/`、模板、hooks、安装脚本时，直接重新执行：

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

### 场景 3：只改了 `skills/docs`，宿主 live session 还在运行

为了避免 live session 锁住 `skills/docs`，安装阶段会保留宿主上的 `skills/docs` 普通目录，而不是强制替换成 Junction。  
这意味着 repo 里的 canonical docs 一旦变化，宿主 preserved docs 可能漂移，`verify` 会返回 `WARN`。

此时不要重装，直接同步 docs：

```powershell
Set-Location <repo-root>
.\scripts\sync-preserved-docs.ps1
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

默认会同时同步 `%USERPROFILE%\.claude\skills\docs` 与 `%USERPROFILE%\.codex\skills\docs`。如果只想处理单侧：

```powershell
.\scripts\sync-preserved-docs.ps1 -TargetHost Claude
.\scripts\sync-preserved-docs.ps1 -TargetHost Codex
```

这个脚本会：

- 覆盖已漂移的 docs 文件
- 补齐缺失文件
- 删除 repo 中已不存在的陈旧 docs

### 场景 4：需要回滚

```powershell
Set-Location <repo-root>
.\uninstall.ps1
```

默认会读取 `backups/active-install.json` 指向的 manifest。

如果 install 中途失败，或你要指定某次历史安装的 manifest，可以显式传参：

```powershell
.\uninstall.ps1 -ManifestPath <repo-root>\backups\install-YYYYMMDD-HHMMSS\install-manifest.json
```

## 宿主落点一览

| 仓库资产 | 落点 |
|---|---|
| `skills/` | `%USERPROFILE%\.claude\skills\*` / `%USERPROFILE%\.codex\skills\*` |
| `runtime-hooks/claude/*.js` | `%USERPROFILE%\.claude\hooks-memory\*.js` |
| `agent-configs/claude/CLAUDE.md.template` | `%USERPROFILE%\.claude\CLAUDE.md` |
| `agent-configs/codex/AGENTS.md.template` | `%USERPROFILE%\.codex\AGENTS.md` |
| `agent-configs/codex/config.shared.toml.template` | `%USERPROFILE%\.codex\config.toml` 的 managed block |
| `agent-configs/workspace/AGENTS.md.template` | `<workspace-root>\AGENTS.md` |
| `agent-configs/workspace/GEMINI.md.template` | `<workspace-root>\GEMINI.md` |
| `vault-template/` | `<workspace-root>\.assistant` |

## 什么会进 Git，什么不会

进入 Git：

- `skills/`
- `runtime-hooks/claude/`
- `agent-configs/`
- `vault-template/`
- `skills/docs/*` 下的 canonical docs

不进入 Git：

- 真实密钥
- 用户私有 overlay
- 真实运行时任务状态
- 本机生成的 `skills/.system/`
- `backups/`

## 常见问题

### `verify-installation.ps1` 返回 `WARN`

先看告警内容：

- 如果是 `skills/docs` 漂移或存在陈旧文件，运行 `.\scripts\sync-preserved-docs.ps1`
- 如果是宿主配置或 managed block 漂移，重新执行 `.\install.ps1 -WorkspaceRoot <workspace-root>`

### 为什么 `skills/docs` 不是 Junction

这是当前有意保守的热切换策略。为了避免 live session 锁冲突，若宿主上已经存在普通目录形式的 `skills/docs`，安装不会强制把它改回 Junction。

### `uninstall.ps1` 会不会删掉我的运行时数据

不会。当前策略明确不清理：

- `<workspace-root>\.assistant\运行时\*`
- 工作区 `.assistant` 本身
- 未纳入 manifest 的用户后续新增文件

### install 失败后怎么处理

优先看 `backups/install-*/install-manifest.json` 是否已生成。当前安装脚本会尽早写出 recovery manifest snapshot；如果它存在，就可以用：

```powershell
.\uninstall.ps1 -ManifestPath <that-manifest>
```

## 当前限制

- 只支持 Windows
- `settings.local.json` 合并阶段依赖 `node`
- `vault-template/` 当前采用“缺失即补齐、存在则保留”的保守策略，不主动刷新已存在文档
- 为避免 live session 锁住 `skills/docs`，docs-only 变更后的宿主收敛依赖 `.\scripts\sync-preserved-docs.ps1`
- 历史设计文档目录仍保留少量旧时代证据文件；当前不阻塞安装链路

## 推荐命令清单

```powershell
# 安装
.\install.ps1 -WorkspaceRoot <workspace-root>

# 验证
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>

# 同步保留的 docs
.\scripts\sync-preserved-docs.ps1

# 校验当前任务 artifacts
.\scripts\validate-harness-artifacts.ps1 -CurrentFlowPath <absolute-path-to-current-flow.md>

# 指定只同步 Claude 或 Codex
.\scripts\sync-preserved-docs.ps1 -TargetHost Claude
.\scripts\sync-preserved-docs.ps1 -TargetHost Codex

# 回滚
.\uninstall.ps1

# 指定 manifest 回滚
.\uninstall.ps1 -ManifestPath <manifest-path>
```
