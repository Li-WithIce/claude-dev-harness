# 开发阶段 Harness 化工作流改造 实施计划

> task_id: dev-stage-harness-refactor
> 关联 Spec：`docs/dev-stage-harness-refactor/spec.md`
> 创建日期：2026-03-31
> 状态：已确认
> review_status：已收敛

## 1. 技术方案概述

本次改造不再把现有 skill workflow 视为“完整研发生命周期流”，而是明确收敛为“开发阶段执行 harness”。其核心思想是：上游评审结果被视为开发输入，其中需求评审是默认必需输入；若任务涉及用户可见 UI 变更，则 UI 评审也是必需输入；技术方案评审是可选增强输入。workflow 从消费这些输入开始，围绕开发计划、实现、代码审查、测试和交付 handoff 构建可验证的状态机。

实施上采用“主路径先轻、分支后补；先收敛语义，再收敛契约，最后统一镜像”的顺序推进。第一步先重定义入口、stage machine 和 artifact 语义，并明确第一轮兼容决策；第二步让各 stage skill 与 contracts/gates/runbook 一致，并补上在途运行态迁移；第三步在 `.claude` 主稿收敛后统一完成 `.codex` 镜像同步，避免镜像反向影响主线决策。

## 2. 技术决策

### 2.1 方案选型

| 决策 | 选择 | 理由 |
|------|------|------|
| workflow 定位 | 只覆盖开发阶段 | 你的真实使用边界就是开发阶段，继续承担全生命周期语义只会制造歧义 |
| 默认主流程 | `INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF` | 与“已评审输入 -> 开发执行 -> 向下游交付”更匹配 |
| 上游输入权重 | 需求评审为默认必需输入；UI 评审仅在涉及用户可见 UI 变更时必需；技术方案评审为可选增强输入 | 贴合真实开发流程，避免把技术评审错误建模成大多数需求的默认硬前置 |
| `spec` 角色 | 收敛为可选 `delta-spec` 制品 | 避免在开发阶段重复承担完整需求评审文档职责，且第一轮不把它做成默认独立 stage |
| 开发主文档 | `plan.md` | 计划、影响面、验证和 handoff 信息都更适合成为开发主制品 |
| 交付 artifact | 第一轮复用 `handoff.md` | 避免本轮额外引入 `delivery.md`，减少契约和镜像同步成本 |
| 结束语义 | 新写入统一使用 `HANDOFF`，读取层保留 `DONE` 一轮兼容别名 | 对开发人员更贴近真实职责边界，同时避免在途任务和历史状态被立即打断 |
| 主稿与镜像 | `.claude` 单源，`.codex` 镜像 | 维持单源治理，降低规则漂移 |
| 镜像执行策略 | `.claude` 单源完成主线改造，`.codex` 只在收尾阶段统一同步 | 降低实施中途的镜像复杂度，避免镜像目录反向干扰计划主线 |

### 2.2 第一轮轻量化与兼容约束

- 默认 `approved inputs` 齐全时直接进入 `PLAN`，其中需求评审是默认必需输入；UI 评审只在 UI 变更任务中要求存在，否则显式记为 `not-applicable`；不要求全量 `spec.md`
- 技术方案评审若存在则直接消费；若不存在，不阻塞主路径进入 `PLAN`
- `DELTA_SPEC` 仅在输入不足时生成，第一轮按可选制品或分支条件处理，不额外新增默认 stage
- 开发阶段只保留一个主文档 `plan.md`；交付继续复用 `handoff.md`
- 第一轮不新增顶层 skill；核心 `SKILL.md` 只保留原则，细则优先下沉 `references/`
- `review / test / shared runtime health gate / 结构校验` 继续保持硬约束，不因轻量化而降低强度
- 历史状态兼容只保留一轮：读取层兼容 `DONE`，新文档与新写回一律使用 `HANDOFF`
- 在 `.claude` 主稿完成前，所有核心改造 TODO 默认在主稿侧实施，不通过 `.codex` 镜像做中途委派

### 2.3 外部依赖

无新增外部依赖。主要依赖现有 skill 文档、orchestrator references、以及双目录镜像机制。

### 2.4 内部依赖

- `%USERPROFILE%\.claude\skills\using-superpowers\SKILL.md`
- `%USERPROFILE%\.claude\skills\orchestrator\SKILL.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\artifact-contracts.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\gates.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\tool-profile-template.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\model-invocation.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\examples.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md`
- `%USERPROFILE%\.claude\skills\spec\SKILL.md`
- `%USERPROFILE%\.claude\skills\plan\SKILL.md`
- `%USERPROFILE%\.claude\skills\implement\SKILL.md`
- `%USERPROFILE%\.claude\skills\review\SKILL.md`
- `%USERPROFILE%\.claude\skills\test\SKILL.md`

### 2.5 影响面地图

#### 2.5.1 受影响目录 / 模块
- `%USERPROFILE%\.claude\skills\using-superpowers\`
- `%USERPROFILE%\.claude\skills\orchestrator\`
- `%USERPROFILE%\.claude\skills\spec\`
- `%USERPROFILE%\.claude\skills\plan\`
- `%USERPROFILE%\.claude\skills\implement\`
- `%USERPROFILE%\.claude\skills\review\`
- `%USERPROFILE%\.claude\skills\test\`
- `%USERPROFILE%\.codex\skills\` 对应镜像目录

#### 2.5.2 上游 / 下游依赖
- 上游依赖：需求评审的已批准结果；若任务涉及用户可见 UI 变更，则还依赖 UI 评审的已批准结果；技术方案评审结果若存在则一并消费
- 下游依赖：验收、上线、交付方需要消费开发阶段 handoff

#### 2.5.3 接口影响
- stage machine 定义
- artifact contract 定义
- tool profile 绑定方式
- state / handoff / validation scenario 的字段语义

#### 2.5.4 潜在回归点
- 仍按旧语义理解 `spec` 的现有 skill 文档
- 仍把 `DONE` 当成“全流程结束”的 references / examples
- `.codex` 镜像未同步，导致不同 agent 理解不同
- validation scenarios 没覆盖新的 `INTAKE / HANDOFF / DELTA_SPEC` 语义

## 3. 任务拆解

### 3.1 入口与总控层

- [x] **TODO-A1: 重定义 using-superpowers 的开发阶段入口语义**
  - **描述**：把“开发任务优先导向 orchestrator”的规则保留，但明确说明该 workflow 只服务开发阶段，默认输入来自已批准的需求结果；若任务涉及用户可见 UI 变更，则还消费已批准的 UI 评审结果，否则显式记为 `not-applicable`；技术方案评审若存在则消费，若不存在也不阻塞进入主路径，而不是重新发明上游审批流。
  - **涉及模块**：入口路由层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\using-superpowers\SKILL.md`
  - **依赖**：无
  - **验收标准**：文档明确区分“传统研发全流程”与“开发阶段执行 harness”；不会再把上游评审描述成当前 workflow 内部 stage
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\using-superpowers\SKILL.md' -Pattern '开发阶段|已批准输入|orchestrator'
    ```
  - **TDD 提醒**：先定义期望路由语义，再修改正文
  - **Codex handoff**：
    - 输入上下文：`using-superpowers/SKILL.md`、本次 spec
    - 预期输出：更新后的入口纪律和开发任务说明
    - 注意事项：不要削弱“开发任务先进 orchestrator”的总规则

- [x] **TODO-A2: 重定义 orchestrator 的 stage machine**
  - **描述**：将当前偏全流程的 stage machine 改为开发阶段版本，默认主流程为 `INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`；其中需求/UI 输入满足时即可进入主路径，技术方案评审仅作为可选增强输入，`DELTA_SPEC` 在缺口存在时作为可选制品或分支条件而不是默认独立 stage
  - **涉及模块**：总控层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\SKILL.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\tool-profile-template.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\model-invocation.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\examples.md`
  - **依赖**：TODO-A1
  - **验收标准**：stage machine、binding、示例和 profile 模板都围绕开发阶段执行流收敛
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\orchestrator\SKILL.md','%USERPROFILE%\.claude\skills\orchestrator\references\tool-profile-template.md','%USERPROFILE%\.claude\skills\orchestrator\references\examples.md' -Pattern 'INTAKE|DELTA_SPEC|HANDOFF'
    ```
  - **TDD 提醒**：先定义目标阶段图和合法迁移，再改正文和示例
  - **Codex handoff**：
    - 输入上下文：`orchestrator/SKILL.md`、`references/*.md`、本次 spec
    - 预期输出：收敛后的开发阶段 stage model
    - 注意事项：不要破坏 review/test 的硬 gate 语义

### 3.2 契约与状态层

- [x] **TODO-B1: 重构 artifact contract 与 gate 定义**
  - **描述**：将 contract 从“完整开发主流程”改为“开发阶段 harness”，明确 `plan.md` 为主文档、`spec.md` 为可选 delta-spec，并在第一轮复用 `handoff.md` 作为交付 artifact，同时定义 `DONE -> HANDOFF` 的兼容读取策略
  - **涉及模块**：契约层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\artifact-contracts.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\gates.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\review-templates.md`
  - **依赖**：TODO-A2
  - **验收标准**：contract、gate、review template 对新的 stage machine 和 artifact 语义一致
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\orchestrator\references\artifact-contracts.md','%USERPROFILE%\.claude\skills\orchestrator\references\gates.md','%USERPROFILE%\.claude\skills\orchestrator\references\review-templates.md' -Pattern 'plan.md|delta-spec|handoff.md|HANDOFF|DONE'
    ```
  - **TDD 提醒**：先列出新 artifact 清单和 gate 条件，再落文档
  - **Codex handoff**：
    - 输入上下文：artifact-contracts、gates、review-templates
    - 预期输出：一致的 contract / gate / template 定义
    - 注意事项：不要让 review/test 结论语义变松

- [x] **TODO-B2: 重构 runbook、state templates 和 validation scenarios**
  - **描述**：让恢复、推进、loop-back、blocked、handoff 都基于新开发阶段模型；补齐 `INTAKE`、`DELTA_SPEC`、`HANDOFF` 场景
  - **涉及模块**：运行时协议层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md`
  - **依赖**：TODO-B1
  - **验收标准**：runbook、state、validation 三者不再按旧流程假设运行
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md','%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md','%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md' -Pattern 'INTAKE|DELTA_SPEC|HANDOFF|current-flow'
    ```
  - **TDD 提醒**：先写验证场景，再反推 runbook 和 state
  - **Codex handoff**：
    - 输入上下文：runbook、state-templates、validation-scenarios
    - 预期输出：可被后续回归检查消费的运行时协议
    - 注意事项：shared runtime hard gate 仍需保留

- [x] **TODO-B3: 新增在途 orchestrator 运行态迁移与兼容方案**
  - **描述**：为仍按旧模型运行的 `current-flow.md`、`handoff.md`、`stage-history.md` 和恢复链提供兼容读取与切换策略，覆盖旧状态映射、切换窗口、历史状态清理和失败回退
  - **涉及模块**：运行态迁移层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\examples.md`
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\troubleshooting.md`
  - **依赖**：TODO-B1, TODO-B2
  - **验收标准**：旧 `DONE` / 旧 stage 语义可以被识别并安全映射到新模型；切换期间恢复链不断裂
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md','%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md','%USERPROFILE%\.claude\skills\orchestrator\references\examples.md','%USERPROFILE%\.claude\skills\orchestrator\references\troubleshooting.md' -Pattern 'legacy|兼容|迁移|DONE|HANDOFF|current-flow'
    ```
  - **TDD 提醒**：先定义旧状态到新状态的映射表和切换窗口，再补 runbook、示例和故障处理
  - **Codex handoff**：
    - 输入上下文：runbook、state-templates、examples、troubleshooting，以及当前 workspace 的旧 `current-flow.md` 样例
    - 预期输出：可执行的迁移与兼容说明
    - 注意事项：兼容读取是临时策略，新写回不得继续产出旧语义状态

### 3.3 阶段 skill 收敛

- [x] **TODO-C1: 收敛 spec 为可选 delta-spec**
  - **描述**：将 `spec` 的职责从“完整需求规格说明”收敛为“开发边界说明 / delta-spec”，只在默认输入不足时启用；不能把“缺少技术方案评审”直接等价成必须回到重需求流程
  - **涉及模块**：阶段 skill
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\spec\SKILL.md`
  - **依赖**：TODO-A2, TODO-B1
  - **验收标准**：文档清楚说明何时需要 spec，何时不需要；不再默认要求开发任务先写全量需求 spec
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\spec\SKILL.md' -Pattern 'delta-spec|开发边界|已批准输入'
    ```
  - **TDD 提醒**：先定义启用条件，再改模板和正文
  - **Codex handoff**：
    - 输入上下文：`spec/SKILL.md`、本次 spec、artifact contract
    - 预期输出：收敛后的 spec skill
    - 注意事项：本轮默认不启用 Codex 中途委派；此 TODO 在 `.claude` 主稿侧执行，并保留“不猜测”的纪律

- [x] **TODO-C2: 强化 plan 为开发主文档**
  - **描述**：让 `plan` 直接消费默认 approved inputs（需求/UI）以及可选的技术方案评审 / delta-spec，并成为开发阶段最核心的执行制品
  - **涉及模块**：阶段 skill
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\plan\SKILL.md`
  - **依赖**：TODO-C1, TODO-B1, TODO-B2
  - **验收标准**：计划模板和正文明确其主文档角色，包含交付 handoff 所需信息
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\plan\SKILL.md' -Pattern '已批准输入|主文档|handoff|DELTA_SPEC'
    ```
  - **TDD 提醒**：先明确 plan 输入和输出，再改模板
  - **Codex handoff**：
    - 输入上下文：`plan/SKILL.md`、本次 spec、artifact contract
    - 预期输出：强化后的开发阶段 plan
    - 注意事项：本轮默认不启用 Codex 中途委派；仍要保留精确文件路径和验证命令要求

- [x] **TODO-C3: 对 implement/review/test 做开发阶段语义对齐**
  - **描述**：让三者围绕“开发执行 harness”语义一致，尤其是 review/test 输出到 handoff 的衔接
  - **涉及模块**：阶段 skill
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\implement\SKILL.md`
    - 修改：`%USERPROFILE%\.claude\skills\review\SKILL.md`
    - 修改：`%USERPROFILE%\.claude\skills\test\SKILL.md`
  - **依赖**：TODO-B1, TODO-B2
  - **验收标准**：三个 skill 都不再暗示自己承担上游评审或全流程完结语义
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\implement\SKILL.md','%USERPROFILE%\.claude\skills\review\SKILL.md','%USERPROFILE%\.claude\skills\test\SKILL.md' -Pattern 'HANDOFF|handoff|开发阶段'
    ```
  - **TDD 提醒**：先统一输入/输出边界，再调整正文
  - **Codex handoff**：
    - 输入上下文：implement/review/test 三个 skill
    - 预期输出：对齐后的阶段职责说明
    - 注意事项：本轮默认不启用 Codex 中途委派；不要削弱 review/test 的证据和 gate 强度

### 3.4 镜像与回归验证

- [x] **TODO-D1: 追加一轮以开发阶段为中心的回归场景并冻结镜像范围**
  - **描述**：把当前文档化场景升级为开发阶段回归矩阵，覆盖默认 approved inputs、可选技术方案评审、optional delta-spec、test fail loop-back、handoff completion、legacy compatibility，以及最终镜像同步所需的范围冻结；D1 完成后，`.claude` 主稿在镜像范围内不再继续新增改动，给 D2 提供稳定输入
  - **涉及模块**：验证层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md`
    - 新建/修改：`%USERPROFILE%\.claude\skills\docs\dev-stage-harness-refactor\review.md`（后续 review 产物）
    - 新建/修改：`%USERPROFILE%\.claude\skills\docs\dev-stage-harness-refactor\test.md`（后续 test 产物）
  - **依赖**：TODO-B3, TODO-C2, TODO-C3
  - **验收标准**：至少能人工回归验证新的开发阶段模型没有回退成旧流程，并显式冻结 D2 将要同步的镜像范围与检查分组
  - **验证命令**：
    ```powershell
    Select-String -Path '%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md' -Pattern 'approved inputs|技术方案评审|DELTA_SPEC|HANDOFF|mirror|legacy'
    ```
  - **TDD 提醒**：先写场景并冻结镜像范围，再回看文档是否满足
  - **Codex handoff**：
    - 输入上下文：新 stage model、validation-scenarios
    - 预期输出：更新后的回归场景矩阵与冻结后的镜像检查范围
    - 注意事项：场景必须覆盖真实开发阶段，而不是重新模拟全流程研发

- [x] **TODO-D2: 收尾全量同步 `.codex` 镜像并校验单源一致性**
  - **描述**：在 D1 已冻结主稿与镜像范围后，将本次所有受影响文件一次性全量同步到 `.codex`，避免双份 workflow 继续语义分叉
  - **涉及模块**：镜像层
  - **精确文件路径**：
    - 修改：`%USERPROFILE%\.codex\skills\using-superpowers\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\orchestrator\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\orchestrator\references\*.md`
    - 修改：`%USERPROFILE%\.codex\skills\spec\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\plan\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\implement\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\review\SKILL.md`
    - 修改：`%USERPROFILE%\.codex\skills\test\SKILL.md`
  - **依赖**：TODO-D1
  - **验收标准**：`.claude` 与 `.codex` 必须按完整镜像矩阵逐项校验通过，至少覆盖 `using-superpowers`、`orchestrator + references`、`spec/plan`、`implement/review/test` 四组对象，不接受单文件 spot check 代替全量校验
  - **验证命令**：
    ```powershell
    $claude = '%USERPROFILE%\.claude'
    $codex = '%USERPROFILE%\.codex'
    $matrix = [ordered]@{
      'using-superpowers' = @('skills\using-superpowers\SKILL.md')
      'orchestrator-core' = @('skills\orchestrator\SKILL.md')
      'orchestrator-references' = Get-ChildItem "$claude\skills\orchestrator\references\*.md" | ForEach-Object { "skills\orchestrator\references\$($_.Name)" }
      'spec-plan' = @('skills\spec\SKILL.md','skills\plan\SKILL.md')
      'stage-skills' = @('skills\implement\SKILL.md','skills\review\SKILL.md','skills\test\SKILL.md')
    }
    $result = $matrix.GetEnumerator() | ForEach-Object {
      $group = $_.Key
      foreach ($rel in $_.Value) {
        $left = Join-Path $claude $rel
        $right = Join-Path $codex $rel
        [pscustomobject]@{
          Group = $group
          Path = $rel
          Match = (Test-Path $right) -and ((Get-FileHash $left).Hash -eq (Get-FileHash $right).Hash)
        }
      }
    }
    $result | Format-Table -AutoSize
    $result | Where-Object { -not $_.Match }
    ```
  - **TDD 提醒**：先冻结主稿和回归范围，再做镜像
  - **Codex handoff**：
    - 输入上下文：所有本次变更后的 `.claude/skills` 文件，以及 D1 冻结后的镜像范围
    - 预期输出：同步后的 `.codex/skills`
    - 注意事项：`.codex` 不参与中途决策，只做主稿收敛后的最终镜像同步

## 4. 依赖关系与执行顺序

### 4.1 依赖图

```text
主干：TODO-A1 → TODO-A2 → TODO-B1 → TODO-B2
支线 A：TODO-B2 → TODO-B3
支线 B：TODO-B1 → TODO-C1；TODO-C1 + TODO-B2 → TODO-C2
支线 C：TODO-B2 → TODO-C3
收敛：TODO-B3 + TODO-C2 + TODO-C3 → TODO-D1 → TODO-D2
```

### 4.2 并行分组

| 阶段 | 可并行执行的 TODO | 前置条件 |
|------|-------------------|----------|
| Phase 1 | TODO-A1 | 无 |
| Phase 2 | TODO-A2 | TODO-A1 |
| Phase 3 | TODO-B1 | TODO-A2 |
| Phase 4 | TODO-B2, TODO-C1 | TODO-B1 |
| Phase 5 | TODO-B3, TODO-C2, TODO-C3 | TODO-B2 完成，且满足各自前置依赖 |
| Phase 6 | TODO-D1 | TODO-B3, TODO-C2, TODO-C3 |
| Phase 7 | TODO-D2 | TODO-D1 |

说明：`TODO-B2` 与 `TODO-B3` 不可并行，因为二者共享 `runbook.md` 与 `state-templates.md` 的写集，必须按单 owner 顺序执行。`TODO-C1` 只需满足 `TODO-B1`；`TODO-C2` 需要满足 `TODO-C1 + TODO-B2`；`TODO-C3` 需要满足 `TODO-B1 + TODO-B2`，因此它可以与 `TODO-B3`、`TODO-C2` 同批推进；D2 之前不通过 `.codex` 参与中途实施。

### 4.3 关键路径

- 关键收敛路径分两段：前段固定为 `TODO-A1 → TODO-A2 → TODO-B1 → TODO-B2`；后段不是单支串行，而是 `TODO-B3`、`TODO-C1 → TODO-C2`、`TODO-C3` 三条支线在 `TODO-D1` 汇合，最后进入 `TODO-D2`

## 5. 测试标准

### 5.1 单元测试标准
- 文档层面用结构校验替代代码单测，重点验证 metadata、heading、stage 名称和 artifact 命名是否一致
- 双目录镜像一致性必须覆盖完整同步矩阵，而不是单文件 spot check：至少按 `using-superpowers`、`orchestrator + references`、`spec/plan`、`implement/review/test` 四组逐项校验，对应文件必须全部通过 hash 对比
- 轻量化结构校验必须覆盖：默认 `approved inputs` 路径不强制生成全量 `spec.md`、第一轮继续复用 `handoff.md`、不新增顶层 skill、核心规则优先下沉 `references/`
- 输入模型校验必须覆盖：需求评审是默认必需输入；UI 评审仅在涉及用户可见 UI 变更时必需，否则显式记为 `not-applicable`；技术方案评审是可选增强输入，缺少技术评审不会单独阻塞主路径
- 主稿优先校验必须覆盖：`.claude` 主稿可单独闭环推进；`.codex` 镜像只在 D2 收尾同步，不参与中途 gate 判断
- 兼容性校验必须覆盖：新写入统一使用 `HANDOFF`，读取链仍能识别一轮 `DONE` 旧状态

### 5.2 集成 / 场景验证标准
- 场景 0：存在旧 `current-flow.md` / `handoff.md` 时，恢复链仍可识别旧语义并映射到新模型
- 场景 1：需求评审齐全，且任务为非 UI 变更或 UI 评审已齐全、但没有技术方案评审时，workflow 仍可直接进入 `INTAKE/PLAN`
- 场景 2：技术方案评审存在时，workflow 会把它作为增强输入消费，但不改变主路径结构
- 场景 3：输入不足时，触发可选 `DELTA_SPEC`
- 场景 4：`review.md` 仅有 P2 时，可进入 TEST
- 场景 5：`test.md = fail` 时，稳定回 DEV
- 场景 6：TEST 通过后进入 `HANDOFF`，而不是宣称全生命周期 `DONE`
- 场景 7：D2 完成后，`.claude` 与 `.codex` 的受影响文档一致
- 场景 8：第一轮不新增 `delivery.md`，交付信息继续由 `handoff.md` 承接

## 6. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 旧文档仍按全流程语义编写 | 改造后仍会出现角色边界混乱 | 在 orchestrator 和 stage skill 中先统一术语，再做 references 收敛 |
| `.codex` 过早介入主线实施 | 镜像目录反向干扰 `.claude` 主稿收敛 | 将 `.codex` 降为 D2 收尾同步步骤，主线实施只以 `.claude` 为准 |
| 共享 runtime 仍残留旧任务状态 | 影响恢复和 gate 判断 | 新增 B3，为旧 `current-flow.md` 和相关恢复链提供兼容读取、切换窗口与清理策略 |
| `spec` 语义收敛不彻底 | 开发任务仍会被迫走重需求流程 | 在 spec/plan/orchestrator 三处同时修改，而不是只改一处 |
| 轻量化目标在执行中被重新做重 | 第一轮改造面扩大、文档和镜像成本失控 | 将“主路径先轻、默认制品更少、硬 gate 不减弱”写入技术决策和测试标准，作为验收项执行 |

## 7. 开放问题

无。本轮关键语义、轻量化边界、镜像时序和运行态兼容策略已与 `spec.md` 同步：

- `DELTA_SPEC` 第一轮按可选制品处理
- 交付继续复用 `handoff.md`
- 新写入统一使用 `HANDOFF`，读取层兼容 `DONE` 一轮
- 旧 `current-flow.md` 的迁移与清理由 `TODO-B3` 单独承接
- `.codex` 不参与中途实施，统一在 D2 做主稿收敛后的镜像同步
