# Skills 核心流程重构改造文档

> 建议维护方式：先在 `%USERPROFILE%\.claude\skills` 完成重构，再镜像到 `%USERPROFILE%\.codex\skills`
>
> 文档状态：Draft
>
> 目标版本：v1

## 1. 背景与目标

当前技能体系存在以下问题：

1. 开发流程技能分散，存在多条相互竞争的入口。
2. `.claude/skills` 与 `.codex/skills` 两套目录长期漂移，同名 skill 行为不一致。
3. `orchestrator` 已具备任务编排能力，但尚未成为全局开发主流程的唯一调度中心。
4. `spec`、`plan`、`review`、`test` 四个核心技能的契约不一致，部分仍停留在旧模板风格，未统一到 task-scoped artifact 和 gate 模型。
5. 多个流程型 skill 沉淀了有价值的规则，但分散在边缘技能中，导致使用门槛高、触发不稳定、维护成本大。

本次改造的目标是：

- 建立唯一的开发主流程：`using-superpowers -> orchestrator -> spec -> plan -> implement -> review -> test`
- 明确 `orchestrator` 为开发任务 stage governor
- 明确 `using-superpowers` 为开发任务入口纪律控制器
- 将开发相关 skill 中可复用的高价值规则吸收进核心技能
- 对旧的流程型 skill 做硬退役处理，避免继续争抢主流程
- 建立 `.claude -> .codex` 的单向镜像机制，消除双目录漂移

## 2. 决策摘要

本次改造采用以下明确决策：

- 维护源目录：`%USERPROFILE%\.claude\skills`
- 同步策略：以 `.claude` 为唯一主稿，完成后镜像到 `.codex`
- 开发主导：`orchestrator` + `using-superpowers`
- 核心阶段：`spec`、`plan`、`implement`、`review`、`test`
- DEV 定位：保留为一等阶段，不弱化为隐式过程
- 整合力度：强收口，尽量把开发规则吸收到核心技能
- 旧 skill 去向：硬退役，不再保留为并列主流程入口
- TEST runner 策略：保留 `Gemini -> Claude /test -> Codex` fallback 顺序
- artifact 模型：统一到 `docs/<task-id>/...`
- orchestration state：统一到 `.assistant/orchestration/*`

## 3. 当前现状盘点

### 3.1 目录现状

已确认：

- `.claude/skills`：42 个 skill 目录
- `.codex/skills`：37 个 skill 目录

仅存在于 `.claude/skills` 的目录：

- `claude-to-im`
- `codex`
- `gemini-designer-main`
- `openclaw-token-optimizer`
- `orchestrator`

`.codex/skills` 当前缺失 `orchestrator`，这意味着如果不补齐镜像，双目录无法共享统一主流程。

### 3.2 核心 skill 现状

#### `using-superpowers`

现状：

- 已具备“任何动作前先判断 skill”的强约束
- 已明确 process skill 优先于 implementation skill
- 仍是通用 skill 路由，不是开发主流程入口总线

问题：

- 未明确“开发任务默认先进入 orchestrator”
- 未区分开发主流程与 specialist skill 的调用层级
- 与 `orchestrator` 的关系没有写死

#### `orchestrator`

现状：

- 已具备 `SPEC -> PLAN -> DEV -> REVIEW -> TEST -> DONE`
- 已定义 gate、handoff、fallback、current-flow、task-scoped artifact
- 已有 artifact contract、runbook、model invocation、state template

问题：

- 还没有接管所有开发类入口
- 需要与 `spec`、`plan`、`review`、`test`、`implement` 的正文契约强绑定
- 尚未同步到 `.codex/skills`

#### `spec`

现状：

- 强调澄清需求、边界、AC
- 输出结构清晰

问题：

- 未显式兼容 `task_id`
- 未显式满足 orchestrator 的 artifact contract
- 未吸收 brainstorming 中“先发散再收敛”的探索方法

#### `plan`

现状：

- 已有 TODO 拆解、依赖关系、测试标准
- 已要求基于已确认 spec

问题：

- 任务颗粒度仍偏粗
- 缺少对“零上下文执行者”的更强约束
- 未正式吸收 `writing-plans`、`executing-plans`、并行任务治理经验
- 未显式与 Codex handoff 契约对齐

#### `implement`

现状：

- 已是正式实现技能
- 支持按 plan 实现与按 review/test 修复两种模式

问题：

- 尚未内置 TDD 纪律
- 尚未内置 systematic-debugging 纪律
- 尚未内置 receiving-code-review 的反馈处理规则
- 尚未内置 verification-before-completion 的完成前验证规则

#### `review`

现状：

- 已支持基于 spec + plan 的结构化审查
- 已有 P0/P1/P2 分级

问题：

- 未显式要求结合 `implementation-notes.md`
- 未显式对接 orchestrator 的 REVIEW gate
- 未吸收 spec compliance review 的方法

#### `test`

现状：

- 已经高度接近 orchestrator 体系
- 已支持 task-scoped artifact
- 已支持 `pass / fail / blocked`
- 已明确不能改业务代码

问题：

- 仍需强化证据优先
- 仍需进一步明确 specialist test skill 的 subordinate 角色

## 4. 目标体系设计

### 4.1 目标流程

以后开发任务统一采用以下流程：

```text
using-superpowers
  -> orchestrator
    -> SPEC
    -> PLAN
    -> DEV
    -> REVIEW
    -> TEST
    -> DONE
```

### 4.2 角色分工

#### `using-superpowers`

职责：

- 会话入口纪律控制
- 先判断技能，再回复用户
- 当检测到开发任务时，优先把任务导向 orchestrator
- 对非开发任务继续承担正常 skill 路由职责

#### `orchestrator`

职责：

- 任务身份解析
- stage 选择与推进
- gate 审核
- loop-back 控制
- handoff 维护
- runner/fallback 管理
- state 文件维护
- 核心流程唯一调度中心

#### 核心 stage skills

职责：

- `spec`：定义需求，不写代码
- `plan`：定义实现与验证方案，不写实现代码
- `implement`：唯一业务代码实现阶段
- `review`：只做审查，不改代码
- `test`：只做验证，不改业务代码

### 4.3 artifact 统一模型

所有开发任务统一采用：

```text
docs/<task-id>/spec.md
docs/<task-id>/plan.md
docs/<task-id>/review.md
docs/<task-id>/test.md
docs/<task-id>/implementation-notes.md
.assistant/orchestration/current-flow.md
.assistant/orchestration/stage-history.md
.assistant/orchestration/handoff.md
.assistant/orchestration/decision-needed.md
```

固定文件名 `spec.md`、`plan.md`、`review.md`、`test.md` 仅作为 legacy fallback。

## 5. 核心技能改造方案

### 5.1 `using-superpowers` 改造

#### 改造目标

让它从“通用 skill 路由纪律”升级为“开发任务统一入口”。

#### 需要新增的规则

- 明确区分开发任务与非开发任务
- 明确当用户意图落在开发、修 bug、做重构、写文档驱动开发、代码 review、测试验证时，优先进入 `orchestrator`
- 明确对 `spec`、`plan`、`implement`、`review`、`test` 的触发不再直接绕过 orchestrator，除非：
  - 用户明确要求进入某一 stage
  - 当前任务已有明确 `task_id` 与 current-flow
  - orchestrator 明确判定可恢复到该阶段
- 增加开发流程优先级说明：
  - 开发主流程 skill 高于 specialist skill
  - specialist skill 只在具体 stage 内二次调用
- 新增 red flags：
  - “这个改动很小，不需要 orchestrator”
  - “先直接 implement，再补文档”
  - “review/test 太慢，先提交”
  - “这个是 bug fix，不用 spec/plan”

#### 结果要求

`using-superpowers` 必须写死如下关系：

- 开发入口先找 `orchestrator`
- 非开发任务按现有 skill 发现流程处理
- 任何 specialist skill 不得抢占开发主流程入口

### 5.2 `orchestrator` 改造

#### 改造目标

成为唯一开发编排中心，并与核心 skills 的正文契约彻底对齐。

#### 需要保留

- stage map
- gate rules
- artifact contract
- state templates
- handoff contract
- TEST fallback chain

#### 需要增强

- 在正文中明确它是“开发任务默认入口后的唯一 governor”
- 明确如果用户直接点名 `spec`、`plan`、`implement`、`review`、`test`，也必须通过 orchestrator 恢复任务身份与 stage
- 明确与 `using-superpowers` 的关系
- 明确 `.claude` 与 `.codex` 镜像时 references、scripts、fallback 的路径解析规则
- 明确 `.codex` 当前缺失目录补齐要求

#### references 需要同步修订

- `artifact-contracts.md`
- `gates.md`
- `runbook.md`
- `state-templates.md`
- `model-invocation.md`

#### 关键对齐点

- `spec.md`、`plan.md`、`review.md`、`test.md` 都要显式可映射当前 task
- `implementation-notes.md` 要成为 DEV -> REVIEW 的固定交付物
- 所有 runner 说明不能写死某个目录树

### 5.3 `spec` 改造

#### 吸收来源

- `brainstorming`

#### 需要吸收的内容

- 在正式写 spec 前先做“意图探索 + 约束澄清”
- 优先澄清目标、受众、成功标准、边界、权衡
- 必要时提出 2-3 个方向供用户选择，但最后必须收敛成单一、明确的需求规格
- 保持“不写代码、不猜测”的硬约束

#### 模板需要新增

- `task_id`
- `task_name`
- 当前任务映射信息
- 显式 `in scope / out of scope`
- 明确 `acceptance criteria`
- `risks / assumptions / open questions`
- 可供 orchestrator 判定收敛状态的字段

#### 需要去掉的风险

- 不能因为吸收 brainstorming 就变成开放式头脑风暴文档
- 不能削弱 spec 的边界约束与确认动作

### 5.4 `plan` 改造

#### 吸收来源

- `writing-plans`
- `executing-plans`
- `dispatching-parallel-agents`

#### 需要吸收的内容

- 面向“零上下文执行者”的计划写法
- 每项任务必须写清：
  - 目标
  - 影响范围
  - 文件
  - 前置依赖
  - 验收方式
  - 验证命令或验证路径
- 标出哪些 TODO 可并行，哪些必须串行
- 任务粒度进一步收紧到实现者能稳定执行的工作单元
- 加入 handoff-ready 视角：
  - 给 Codex 的输入文件
  - 预期输出
  - watchouts
  - 回滚点或检查点

#### 保持不变

- 不写实现代码
- 基于已确认 spec
- 必须包含测试标准

#### 需要新增的约束

- 必须兼容 orchestrator 的 `plan` artifact contract
- 必须对实现和验证路径做显式映射
- 如有并行执行可能，必须给出拆分原则与合流点

### 5.5 `implement` 改造

#### 吸收来源

- `test-driven-development`
- `systematic-debugging`
- `receiving-code-review`
- `verification-before-completion`

#### 需要吸收的内容

##### 从 TDD 吸收

- 默认 RED -> GREEN -> REFACTOR
- 新功能、bugfix、行为变更都优先要求先写失败测试
- 不允许“先写代码后补测试”作为默认路径
- 若无法先写测试，必须明确说明原因和替代验证方式

##### 从 systematic-debugging 吸收

- 修 bug 前先做 root cause investigation
- 不允许随机试修
- 出现连续失败修复时必须回到问题分析
- 修复问题前先确认现象、复现路径、证据

##### 从 receiving-code-review 吸收

- 收到 review/test 反馈后，先验证问题是否成立，再决定修改
- 不做表演式认同
- 不对不明确的 feedback 直接实施
- 对外部 reviewer 建议保留技术性怀疑能力

##### 从 verification-before-completion 吸收

- 任何“已完成/已修复/已通过”声明前必须有 fresh verification evidence
- 完成前必须运行相应命令并核对结果
- 不允许凭主观判断宣称成功

#### 需要新增的实现物

- `implementation-notes.md`

内容至少包括：

- 改了什么
- 没改什么
- 风险点
- reviewer watchouts

#### 结果要求

`implement` 必须成为唯一业务代码修改入口，且内置开发纪律，不再依赖用户主动额外点名这些流程型 skill。

### 5.6 `review` 改造

#### 吸收来源

- `subagent-driven-development` 中的 spec compliance review 思路
- `receiving-code-review` 的反馈分类视角

#### 需要吸收的内容

- Review 不只对照代码质量，还要对照：
  - `spec.md`
  - `plan.md`
  - `implementation-notes.md`
  - 当前 diff
- 增加“是否少做、多做、做错”的核查
- 明确 `P0` 是唯一阻塞 TEST 的等级
- `P1/P2` 必须进入 watchouts 和 TEST handoff
- 若当前任务证据不足，允许指出 `blocked review input`

#### 输出要求

- 继续保留 `P0/P1/P2`
- 必须精确到文件/行号
- 必须能被 orchestrator gate 直接消费

### 5.7 `test` 改造

#### 吸收来源

- `verification-before-completion`
- `webapp-testing` 的 stage 内 specialist 用法
- `gemini-designer-main` 的主测链路约束

#### 需要吸收的内容

- 强化“证据先于结论”
- 明确 `pass / fail / blocked` 三态的判定方法
- 明确没有证据时优先 `blocked`
- specialist test skill 只作为 test stage 内二级调用
- 如果是 Web UI 验证，优先在 `test` 中调用 `webapp-testing`，而不是让后者抢主流程入口

#### 保持不变

- 不允许修改业务代码
- 支持 task-scoped `test.md`
- TEST fallback 顺序不变

## 6. specialist skill 保留策略

以下 skill 保留，但被重新定位为“核心流程下的二级能力”：

- `frontend-design`
- `mcp-builder`
- `claude-api`
- `webapp-testing`
- `docx`
- `pdf`
- `pptx`
- `xlsx`
- 其他明确属于领域工具型或产物型的 skill

这些 skill 的正文需要补一条原则：

- 它们是 stage 内调用的 specialist skill
- 不是开发主流程入口
- 如任务属于标准开发活动，应先由 `orchestrator` 决定当前 stage，再在 stage 内调用 specialist skill

## 7. 硬退役 skill 列表与处理方式

以下流程型 skill 进入硬退役：

- `writing-plans`
- `executing-plans`
- `dispatching-parallel-agents`
- `systematic-debugging`
- `test-driven-development`
- `verification-before-completion`
- `receiving-code-review`
- `subagent-driven-development`
- `finishing-a-development-branch`

### 退役方式

每个被退役 skill 做以下处理：

1. frontmatter 描述改为窄触发
2. 明确标注自己已被核心流程吸收
3. 正文改为短说明：
   - 现在由哪个核心 skill 承担其职责
   - 仅保留 legacy 或参考用途
4. 不再写宽泛描述，避免被发现系统优先命中
5. 如存在仍有独立参考价值的内容，将正文缩成索引或引用入口

### 退役原则

- 不删除目录，避免断链
- 不保留并列主流程地位
- 不继续维护完整正文逻辑
- 必须降低触发概率

## 8. 双目录镜像方案

### 8.1 总原则

- `.claude/skills` 为唯一主稿
- `.codex/skills` 为镜像副本
- 不允许 `.codex` 独立演化

### 8.2 需要补齐的目录

在 `.codex/skills` 中新增并同步：

- `orchestrator`
- `codex`
- `gemini-designer-main`

必要时也同步其 references 和 scripts。

### 8.3 同步范围

每次同步至少包含：

- `SKILL.md`
- `references/`
- `scripts/`
- `assets/`（如存在且确实被 skill 使用）

### 8.4 路径治理

需要修正任何写死如下路径的说明：

- `~/.claude/skills/...`
- `%USERPROFILE%\.claude\skills\...`

改造后应采用以下策略：

- 当前 skill 所在目录优先
- 镜像目录可作为 fallback
- 文档中避免硬编码只有一边存在的路径
- 脚本路径写法需同时兼容 `.claude` 与 `.codex`

### 8.5 一致性要求

镜像后以下内容必须一致：

- 同名核心 skill 的 frontmatter
- 正文核心规则
- references 语义
- TEST fallback 描述
- artifact contract 描述
- orchestrator gate 规则

## 9. 文档与目录调整范围

本次改造建议至少涉及以下目录：

### 核心目录

- `%USERPROFILE%\.claude\skills\using-superpowers`
- `%USERPROFILE%\.claude\skills\orchestrator`
- `%USERPROFILE%\.claude\skills\spec`
- `%USERPROFILE%\.claude\skills\plan`
- `%USERPROFILE%\.claude\skills\implement`
- `%USERPROFILE%\.claude\skills\review`
- `%USERPROFILE%\.claude\skills\test`

### 需要退役的流程型目录

- `%USERPROFILE%\.claude\skills\writing-plans`
- `%USERPROFILE%\.claude\skills\executing-plans`
- `%USERPROFILE%\.claude\skills\dispatching-parallel-agents`
- `%USERPROFILE%\.claude\skills\systematic-debugging`
- `%USERPROFILE%\.claude\skills\test-driven-development`
- `%USERPROFILE%\.claude\skills\verification-before-completion`
- `%USERPROFILE%\.claude\skills\receiving-code-review`
- `%USERPROFILE%\.claude\skills\subagent-driven-development`
- `%USERPROFILE%\.claude\skills\finishing-a-development-branch`

### 需要同步到 `.codex` 的目录

- `%USERPROFILE%\.codex\skills\using-superpowers`
- `%USERPROFILE%\.codex\skills\spec`
- `%USERPROFILE%\.codex\skills\plan`
- `%USERPROFILE%\.codex\skills\implement`
- `%USERPROFILE%\.codex\skills\review`
- `%USERPROFILE%\.codex\skills\test`
- 新增：
  - `%USERPROFILE%\.codex\skills\orchestrator`
  - `%USERPROFILE%\.codex\skills\codex`
  - `%USERPROFILE%\.codex\skills\gemini-designer-main`

## 10. 实施顺序

### Phase 1：盘点与映射

输出一份技能清单矩阵，标记：

- 核心保留
- specialist 保留
- 流程吸收
- 硬退役
- 双目录缺失补齐

产物：

- `skills-inventory.md`
- `skills-migration-matrix.md`

### Phase 2：核心技能正文改造

优先改：

1. `using-superpowers`
2. `orchestrator`
3. `spec`
4. `plan`
5. `implement`
6. `review`
7. `test`

要求：

- 先完成 `.claude`
- references 与正文同步改
- 所有核心技能契约对齐

### Phase 3：旧 skill 硬退役

对退役清单逐个改 frontmatter 和正文，降低触发范围。

### Phase 4：镜像到 `.codex`

把 `.claude` 主稿同步到 `.codex`，补齐缺失目录。

### Phase 5：路由与契约验收

用典型开发请求验证路由、stage、gate、fallback 和 legacy redirect。

## 11. 验收标准

### 11.1 路由验收

给出以下请求时，必须符合预期：

- “做一个新功能”
- “修一个 bug”
- “写 plan”
- “review 代码”
- “跑测试”
- “fix review 里的问题”

预期：

- 先由 `using-superpowers` 做入口判断
- 标准开发任务优先进入 `orchestrator`
- 由 `orchestrator` 决定 stage 与 handoff
- 不再被旧流程型 skill 抢先命中

### 11.2 artifact 验收

- `spec`、`plan`、`review`、`test` 均满足 orchestrator artifact contract
- 当前任务信息可映射到 `task_id`
- 任务输出落到 `docs/<task-id>/...`

### 11.3 gate 验收

- `review` 出现 `P0` 时必须回 DEV
- 只有 `P1/P2` 时可进入 TEST，但要记录风险
- `test` 证据不足时必须输出 `blocked`
- 不允许绕过 REVIEW 或 TEST

### 11.4 fallback 验收

- Gemini 输出无效时，按 `Gemini -> Claude /test -> Codex` 回退
- `current-flow.md` 与 `handoff.md` 记录真实 runner 与原因

### 11.5 镜像验收

- `.claude` 与 `.codex` 的核心 skills 一致
- `.codex` 中新增目录可被正常加载
- 文档不再写死单边路径

### 11.6 退役验收

- 被硬退役的流程 skill 不再作为普通开发请求的优先命中项
- 显式点名它们时，会重定向到新的核心流程或说明已被吸收

## 12. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| `using-superpowers` 仍保留过宽描述 | 开发请求仍可能绕过 orchestrator | 缩紧开发触发文案，明确开发任务默认先找 orchestrator |
| 旧 skill frontmatter 不够窄 | 被发现系统继续优先命中旧 skill | 对退役 skill 全量收窄描述并改正文 |
| `.codex` 缺失 orchestrator 相关目录 | 双目录行为继续漂移 | 先补齐目录，再做镜像 |
| references 与正文不一致 | gate 或 contract 执行错乱 | 核心 skill 与 references 同步改造 |
| specialist skill 抢主流程入口 | 路由不稳定 | 所有 specialist skill 加入 subordinate 声明 |
| `implement` 吸收规则过多 | 正文变臃肿、触发不清 | 主文保留纪律，细节放引用或短附录 |
| TEST 证据约束不够硬 | 仍可能出现无证据宣称通过 | 强化 verdict 与 evidence 的绑定 |

## 13. 非目标

本次改造不包括：

- 删除旧目录或重命名大量 skill 目录
- 重做非开发类 specialist skill 的整体体系
- 改变 Gemini 主测策略
- 建立新的跨仓库发布系统

## 14. 后续产物建议

本次文档确定后，建议继续补三类配套文档：

1. `skills-inventory.md`
   - 全量 skill 清单
   - 分类标签
   - 维护状态
   - 主流程归属
2. `skills-migration-matrix.md`
   - 每个旧 skill 的能力迁入到哪个核心 skill
   - 哪些内容保留为 specialist
   - 哪些内容退役
3. `skills-acceptance-cases.md`
   - 标准开发请求样例
   - 预期路由
   - 预期 stage
   - 预期 artifact 输出

## 15. Assumptions

- 你认可 `orchestrator + using-superpowers + spec/plan/implement/review/test` 作为唯一开发主链路。
- `implement` 继续保留为正式 DEV 阶段，不会被弱化或删除。
- 退役 skill 只做硬退役，不做物理删除。
- `.claude/skills` 是唯一主稿源。
- `.codex/skills` 不再允许独立改动。
- specialist skill 继续存在，但只作为主流程中的二级能力。
- 如果未来要做实际改造落地，应优先从 `.claude` 开始，再统一镜像到 `.codex`。
