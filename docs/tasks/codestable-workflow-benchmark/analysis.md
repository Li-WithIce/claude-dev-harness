# CodeStable 工作流架构分析

> 任务: 702f70ab — Analyze CodeStable workflow architecture
> 分析者: workflow-analyst
> 目标仓库: `D:\data\CodeStable-main` (只读)
> 完成日期: 2026-04-30
> 范围: 结构与机制图景；不做借鉴评估 (留给 workflow-comparer)

---

## 0. TL;DR

CodeStable 不是一个 agent 编排框架, 而是一套围绕"软件要素 (需求 / 架构 / 路线图 / 特性 / 问题 / 决策)"建模的 **Claude Code Skills 集合**。

- **形态**: 22 个独立安装的 Skill (`cs-*`) + 项目侧 `codestable/` 文档骨架。每个 skill = 一份 `SKILL.md` (带 YAML frontmatter) + 可选 `reference.md`。
- **入口**: `/cs` 路由器 + `/cs-onboard` 接入；其余 skill 由用户按事件触发或被路由器分诊。
- **执行模型**: 单 Agent (Claude 自己) 沿 Markdown playbook 串联，**没有** orchestrator / daemon / 消息总线 / 多 agent 协作。
- **状态**: 全部状态压在项目 `codestable/` 目录下的 Markdown + YAML 文件，git 友好，零 runtime daemon。
- **核心约束**: 严格 human-in-the-loop——每个阶段间硬性人工 checkpoint, 上一步 `status` 不到位下一步拒绝启动。
- **唯一脚本**: 两个零依赖 Python 工具 `search-yaml.py` (frontmatter 检索) 与 `validate-yaml.py` (frontmatter 校验)。
- **工程化深度**: 在"对抗 AI 默认失败模式"与"项目档案体系建模"两个方向极深；在 ops / 自动化 / 监控方向有意识地裸跑 (这是它的设计立场)。

---

## 1. 仓库结构与文件分布

```
CodeStable-main/
├── README.md / README.en.md         设计哲学 + 体系总览
├── AGENTS.md                        2 行硬规则 (skill 不耦合 / 单 md ≤ 300 行)
├── CLAUDE.md                        skill 隔离硬约束 (1 段)
├── what-is-skills.md                关于 Anthropic Skills 标准的导读
├── asset/                           README 用图
└── cs* (22 个 skill 目录)
    ├── cs/SKILL.md                  根入口路由器
    ├── cs-onboard/                  接入器
    │   ├── SKILL.md
    │   ├── reference.md             (skill 内部细节)
    │   ├── reference/               待释放到项目的共享 doc 模板 (6 份)
    │   └── tools/                   待释放到项目的共享脚本 (2 份)
    ├── cs-{feat,issue,refactor}/    流程入口 (3 大事件)
    ├── cs-feat-{design,impl,accept,ff}/    feature 子阶段
    ├── cs-issue-{report,analyze,fix}/      issue 子阶段
    ├── cs-refactor{,-ff}/                  refactor 入口 (beta)
    ├── cs-{req,arch,roadmap}/              长效档案 + 规划
    ├── cs-brainstorm/                      讨论分诊
    ├── cs-{learn,trick,decide,explore}/    沉淀类
    ├── cs-{guide,libdoc}/                  对外文档
    └── cs-note/                            一两行 AGENTS.md 提示
```

每个 `SKILL.md` 都是约 100–250 行的 Markdown playbook。**没有任何编译产物、配置文件、JSON schema、TypeScript 源码**——整套体系是 markdown + 2 份 Python 脚本。

---

## 2. 工作流入口、核心脚本、调度方式

### 2.1 入口

| 入口 | 角色 | 调用形式 |
|---|---|---|
| `/cs` | 路由器 (`cs/SKILL.md`)。开放式诉求或不知道用哪个时调用 | 用户直接打 `/cs` 或被 Claude 自动触发 (description 包含触发词) |
| `/cs-onboard` | 接入新仓库, 在 `codestable/` 释放骨架 + 共享资产 | 项目首次接入用一次 |
| `/cs-feat`, `/cs-issue`, `/cs-refactor` | 三个事件入口 (新增能力 / 修缺陷 / 重构) | 用户根据事件触发 |
| `/cs-brainstorm` | 想法模糊时讨论入口, 做分诊后路由 | 用户主动或被 `/cs` 推荐 |
| `/cs-{feat,issue}-*` | 每条流程内部各阶段子技能 | 由对应入口路由, 或用户直接调用 |
| `/cs-{req,arch,roadmap}` | 长效档案 / 规划层维护 | 用户按需触发 |
| `/cs-{learn,trick,decide,explore,guide,libdoc,note}` | 沉淀 / 对外文档 | feature / issue 收尾时由上游提示触发 |

### 2.2 核心配置 / 文档资产 (在 `cs-onboard/reference/`, 由 onboard 释放)

| 文件 | 作用 | 行数级 |
|---|---|---|
| `shared-conventions.md` | **跨技能权威协议**: 路径 / 命名 / checklist 生命周期 / 收尾流程 / 归档检索 / 反射检查七大节 | ~250 行 |
| `system-overview.md` | 体系总览 + 场景路由表 + 时间尺度三分 | ~110 行 |
| `code-dimensions.md` | 复杂度档位定义 (在 design 启动检查里被引用) | (未读, 文件存在) |
| `requirement-example.md` | 需求文档范例 | (未读, 文件存在) |
| `tools.md` | Python 工具的完整用法手册 | ~100 行 |
| `maintainer-notes.md` | 断点恢复 + 扩展点登记 | ~50 行 |

### 2.3 核心脚本 (在 `cs-onboard/tools/`)

| 脚本 | 行数 | 作用 |
|---|---|---|
| `search-yaml.py` | 322 | 通用 YAML frontmatter 搜索: `--filter key=val` / `key~=val`、`--query` 全文、`--sort-by FIELD --order asc|desc`、JSON 输出。零必需依赖 (PyYAML 可选, 不在则用 fallback parser)。 |
| `validate-yaml.py` | 315 | YAML 语法 + 必填字段校验。`--require FIELD` 可重复, `--yaml-only` 区分纯 yaml 和 markdown frontmatter, JSON 输出, exit code 反映 pass/fail。 |

两脚本都设计为"AI agent 友好": 结构化输出、无副作用、无外部依赖。是整个体系**唯一的代码层**。

### 2.4 调度方式

**没有外部调度器**。整体调度由 Claude 模型自己完成:

1. **触发**: 用户输入 `/cs-xxx` 或 Claude 根据 description NLU 自动选择 skill。
2. **载入**: Skill 的 metadata (name + description) 一直在上下文里, 触发时 SKILL.md 正文被注入会话。
3. **串联**: SKILL.md 在尾部都有"退出后"段落明确告诉 Claude/用户该触发下一个哪个 skill (例: cs-feat-impl 退出 → 提示 `cs-feat-accept`)。
4. **状态读取**: 每次进 skill 先 `Glob codestable/<对应目录>/`, 读已有产物, 决定是新建 / 续作 / 跳过。

整套调度纯基于 prompt 层和文件系统状态, 不依赖任何运行时进程。

---

## 3. 执行模型

**单 Agent + Markdown playbook 集 + 文件态状态机**。

不是 multi-agent, 不是 orchestrator-worker, 也不是 message-bus。具体形态:

- **唯一执行实体**: 当前 Claude 会话本身。
- **决策表**: 每个 `SKILL.md` 既是 playbook (操作步骤) 也是状态机定义 (启动检查 + 退出条件)。
- **角色"分工"**: 在 SKILL.md 表格里硬写 (谁主导: 用户 / AI / AI 起草用户 review), 不是真去 spawn 多个 agent。
- **触发**: description + when_to_use 字段中的自然语言触发词由模型本身判定。
- **跨 skill 协调**: 通过项目共享文件 (`codestable/<x>/...`) + frontmatter 状态字段。

最关键的**工程边界**, 来自 `CLAUDE.md` 的一行约束:

> "Skill 是独立安装单元, 运行时每个 skill 只能看到自己包内的文件。A 技能的 SKILL.md 里写 `B-skill/reference/xxx.md` 这种引用在运行时根本读不到——skill 之间没有共享的文件系统父目录。"

这条约束直接产生了 `cs-onboard` 的核心职责: **把跨 skill 的共享资产 (reference/ + tools/) 物理复制到目标项目**, 让所有 skill 用项目相对路径 (`codestable/reference/xxx.md`) 互相引用。这是一种"反向依赖颠倒"——skill 之间不能互引, 就把共享物提到项目层。

---

## 4. 实体模型

**6 个实体 + 3 个流程 + 1 个横切沉淀层**。

### 4.1 6 个实体

| 实体 | 目录 | 时间尺度 | 由谁产出 / 维护 |
|---|---|---|---|
| 需求 (requirements) | `requirements/{slug}.md` | 现状档案 | `cs-req`; accept 阶段触发 backfill |
| 架构 (architecture) | `architecture/ARCHITECTURE.md` + `{type}-{slug}.md` | 现状档案 | `cs-arch` (update / check / backfill); `cs-feat-accept` 归并 |
| 路线图 (roadmap) | `roadmap/{slug}/{slug}-roadmap.md` + `{slug}-items.yaml` | 规划档案 | `cs-roadmap` |
| 特性 (features) | `features/YYYY-MM-DD-{slug}/` | 单次动作 | `cs-feat-*` 子链 |
| 问题 (issues) | `issues/YYYY-MM-DD-{slug}/` | 单次动作 | `cs-issue-*` 子链 |
| 知识 / 沉淀 (compound) | `compound/YYYY-MM-DD-{doc_type}-{slug}.md` | 横切复利 | `cs-{learn,trick,decide,explore}` |

**时间尺度三分** (`system-overview.md` 显式建模):
- **现状档案** (req + arch): 只记 "是什么", 默认在 accept 时跟着代码同步。
- **规划档案** (roadmap): 只记 "打算怎么走", 跑完后 `status: completed` 进档案。
- **单次动作** (feature / issue / refactor): 一件具体事的 spec, 完成后相关沉淀提炼进档案。

### 4.2 3 个流程

#### 流程 A: feature (新增能力)

```
[cs-brainstorm]?  →  cs-feat-design  →  cs-feat-impl  →  cs-feat-accept
                  (status:approved)  (steps→done)   (checks→passed)
                                                    + 归并 architecture/req
                                                    + 回写 roadmap items.yaml
```

- 阶段间硬 checkpoint: `cs-feat-impl` 启动检查里强校验 design `status=approved`, 否则 reject。
- 快速通道: `cs-feat-ff` 跳过 design 直接写代码, 仅产出 `{slug}-ff-note.md`。判定权前置, 不允许中途改判。
- 阶段产物聚一目录 (`features/YYYY-MM-DD-{slug}/`), 一目录装齐 brainstorm / intent / design / checklist / acceptance。

#### 流程 B: issue (修复缺陷)

```
cs-issue-report  →  cs-issue-analyze  →  cs-issue-fix
(status:confirmed)  (status:confirmed)  + {slug}-fix-note.md (必出)
```

- 快速通道: 简单 bug 跳 analyze, 但必出 `fix-note.md`。
- 判定权与 feature 同款, 由 `cs-issue-report` 启动检查唯一拍板。

#### 流程 C: refactor (beta)

```
cs-refactor / cs-refactor-ff
```

未深读, 但目录结构 (`scan / refactor-design / checklist / apply-notes`) 与 feature 同构。

### 4.3 横切沉淀

`cs-{learn,trick,decide,explore}` 共享 `compound/` 目录, 通过 frontmatter `doc_type` 区分。**起草前强制 `search-yaml.py --query` 查重**, 命中已有 doc 时三选一: 更新已有 / supersede / 确认是不同主题。

---

## 5. plan / task / review / validation / 恢复机制详解

### 5.1 Plan (设计方案)

- **载体**: `{slug}-design.md` (feature) / `{slug}-roadmap.md` + `items.yaml` (roadmap) / `{slug}-analysis.md` (issue)。
- **产出协议** (cs-feat-design):
  - 整稿一次性给用户 review, **不分批** (cross-section consistency 才能看出来)。
  - frontmatter `status: draft → approved` 是 gate。
  - design 写"现状 → 变化"两段式, 不写改动文件清单 (那是 impl 的事)。
  - 内置"结构健康度评估" (§2.5): 每次 design 必须显式写"是否做微重构 / 拆文件 / 重组目录"——三选一, 不允许跳过。

### 5.2 Task / Checklist (执行清单)

- **载体**: `{slug}-checklist.yaml`, 是 feature 工作流唯一执行清单。
- **三阶段共写一份, 互不重写对方**:
  - design 一次性生成 `steps[]` (paradigm 维度切片, 4–8 步) + `checks[]` (从验收契约抽取)。
  - impl 只动 `steps[].status: pending → done`。
  - accept 只动 `checks[].status: pending → passed/failed`。
- **粒度规则**: steps 是"编排骨架 → 计算节点 → 持久化 → 测试"切片, **不下沉到 file:line / 函数级**——具体改哪个文件由 impl 现场决定。
- 校验: 每次写完用 `validate-yaml.py --file <path> --yaml-only` 强校验。

### 5.3 Review (评审)

CodeStable 的"review"分两层:

1. **用户 review (强制 checkpoint)**: 每个阶段退出条件最后一条都是"用户明确 review 通过"。AI 不能自顾自跑过。design 整稿 review、acceptance 终审、issue 分析方案确认都是这一类。
2. **`cs-arch check` 模式**: 三个子目标 (`design-internal` / `design-vs-code` / `architecture-folder-internal`) 各自独立成一次任务。**只检查不修复**——产出报告, 由用户决定下一步。

### 5.4 Validation (验证)

| 层次 | 机制 |
|---|---|
| 文件层 | `validate-yaml.py` 校验 frontmatter 语法 + 必填字段 + items.yaml 状态机 |
| spec 层 | 每个 SKILL.md 末尾的"退出条件" checklist (4–10 条勾选项), 不通过不退出 |
| 验收层 | `cs-feat-accept` 强制 9 节验收报告: 接口契约 / 行为决策 / 验收场景 / 术语一致 / 架构归并 / req 回写 / roadmap 回写 / AGENTS.md 候选 / 遗留 |
| 反向核对 | accept §2 挂载点反向 grep + "拔除沙盘推演"——清单外的引用 = 漏记, 必须补 |
| 浏览器验证 | 前端改动 `accept §3` 强制要求肉眼浏览器验证, 不能只 typecheck |

### 5.5 恢复机制 (断点续作)

- **真相源**: 项目 `codestable/` 文件本身。AI 中断后没有"会话恢复存档"——靠重新读项目文件还原。
- **协议** (`maintainer-notes.md` §1):
  - 每个阶段进入先 `Glob` 已有产物。
  - 按 frontmatter `status` 字段判断阶段。
  - 已 `done`/`passed` 的部分跳过, 从首个未完成处继续。
  - 简短汇报"上次到 X, 从 Y 继续"。
- 各 SKILL.md "启动检查"节都重复实现这一协议, 没有抽到一处 (轻度冗余但很显式)。

---

## 6. memory / context / runtime state 设计

### 6.1 状态全部文件化

CodeStable 没有 runtime memory store。"状态"= 项目里的 markdown + yaml 文件:

| 状态种类 | 载体 | 字段 |
|---|---|---|
| 阶段进度 | spec doc 的 frontmatter `status` | `draft` / `approved` / `confirmed` / `current` / `superseded` 等 |
| 步骤进度 | `{slug}-checklist.yaml` 的 `steps[].status` / `checks[].status` | `pending` / `done` / `passed` / `failed` |
| 路线图状态 | `{slug}-items.yaml` | `planned` / `in-progress` / `done` / `dropped` (有显式状态机) |
| 沉淀状态 | compound doc 的 `status` | `active` / `superseded` / `outdated` |
| 跨 spec 关联 | frontmatter 字段 (`requirement` / `roadmap` / `roadmap_item` / `feature` / `supersedes`) | 互引 |

### 6.2 没有上下文管理基础设施

- 没有 session 存档
- 没有 token 压缩 / 摘要机制
- 没有跨会话 memory store
- 没有 vector / embedding 索引
- 唯一的"检索"是 `search-yaml.py` 跑一次 grep 式扫描

CodeStable 假设 Claude Code 的会话上下文够大, 真要恢复就读项目文件。

### 6.3 跨 skill 共享

由于 skill 之间不能互访文件系统:
- 共享 doc 通过 `cs-onboard` 物理复制到项目 `codestable/reference/`。
- 共享 script 通过 `cs-onboard` 物理复制到项目 `codestable/tools/`。
- skill 升级后的口径变更需要再跑一次 onboard 才能刷新 (这是显式设计——见 `cs-onboard/SKILL.md` 步骤 4 "强制覆盖" 一节)。

### 6.4 跨阶段衔接协议

**roadmap ↔ feature** (`shared-conventions.md` §2.5) 是最显式的状态机:

```
items.yaml 状态:
planned ──cs-feat-design启动──> in-progress ──cs-feat-accept验收──> done
       └────cs-roadmap update────> dropped (终态)
```

三个 skill (cs-roadmap / cs-feat-design / cs-feat-accept) 各自负责特定状态转换, 互不踩对方。这是体系里**唯一定义清楚的多 skill 状态机**。

---

## 7. 自动化 / hook / 守护 / 监控

CodeStable **没有这一层**——这是它的设计立场而不是缺失。

| 项目 | 状态 |
|---|---|
| Skill `hooks` 字段 | 未使用 |
| 守护进程 | 无 |
| 监控 dashboard | 无 |
| CI / lint 集成 | 无 |
| 跨工作流状态视图 | 无 (`maintainer-notes.md` §2 自己列为待办: "目前查看项目当前有几个 feature 在进行中、几个 issue 未关闭仍需要手动查询") |
| 自动化阶段推进 | 无 (任何阶段必须用户明确 review) |

唯一的"自动化"动作:
- description 触发词 → Claude 自动选 skill。
- frontmatter 字段 `paths` / `disable-model-invocation` (skill 层 metadata, 但 CodeStable 各 skill 没用)。

所有"硬约束"都是 prompt 层的——靠 SKILL.md 写"必须停下来", Claude 模型遵守。**没有 code-level enforcement**。

---

## 8. 配置生成链 (onboard 释放路径)

唯一的"配置生成"是 `cs-onboard`:

```
cs-onboard/                         ← 技能包内权威源
├── reference/                      ← 共享文档模板
│   ├── shared-conventions.md
│   ├── system-overview.md
│   ├── code-dimensions.md
│   ├── requirement-example.md
│   ├── tools.md
│   └── maintainer-notes.md
└── tools/                          ← 共享脚本
    ├── search-yaml.py
    └── validate-yaml.py

         ↓ cs-onboard 跑一次, cp -rf 整目录覆盖

项目/codestable/
├── requirements/                   ← .gitkeep
├── architecture/ARCHITECTURE.md    ← 占位模板
├── roadmap/                        ← .gitkeep
├── features/                       ← .gitkeep
├── issues/                         ← .gitkeep
├── compound/                       ← .gitkeep
├── reference/                      ← 复制副本
└── tools/                          ← 复制副本
```

`cs-onboard/SKILL.md` 严禁用 `Read + Write` 手工搬运 (会截断 / 改缩进 / 吃空行), 强制 `cp -rf` 整目录覆盖。**升级路径**: 修改技能包 `cs-onboard/reference/` 模板 → 用户在已有项目重跑 onboard → 项目副本被新版强制覆盖。

---

## 9. 最有辨识度的 5–8 个机制

(这一节是任务交付的重点, 给后续 workflow-comparer 做对比的种子点。)

### M1. 围绕"软件要素"建模而非围绕 Agent

**位置**: `README.md` "与其他框架的核心区别"节、`system-overview.md`。

显式立场: "**编排的不是 Agent, 而是软件本身的生命周期**。围绕的实体是构成软件的要素——每一个需求、每一个架构决定、每一个特性、每一个 bug、每一条历史里留下来的约束。"

**反映在工程上**: 没有 agent 编排代码, 只有围绕 6 个实体的 spec 模板和阶段 playbook。状态都在文件里, 不在 agent session 里。

### M2. Skill 隔离 + onboard 释放共享资产 (反向依赖颠倒)

**位置**: `CLAUDE.md` (1 段硬约束) + `cs-onboard` 全套机制。

Anthropic Skills 在运行时是物理隔离的——每个 skill 只能看到自己包里的文件。CodeStable 把这一限制变成体系约束并提供解决方案: 把跨 skill 共享的文档和脚本通过 `cs-onboard` 显式 `cp -rf` 到目标项目, 所有 skill 走项目相对路径互相引用。

**这是体系的关键工程边界**——所有"为什么这么设计"的回答最终都引向这条。

### M3. 现状档案 vs 规划档案的硬切分

**位置**: `system-overview.md` "现状档案 vs 规划档案 vs 单次动作"节、`cs-arch` "只记现状不记计划"硬规则。

- `requirements/` + `architecture/` 只能写"系统现在长什么样"。
- `roadmap/` 写"接下来打算怎么做", 完成后转档案态。
- 三类时间尺度严格分离, 用户说"我想重构成 X 架构" → `cs-arch` 拒绝, 路由到 `cs-roadmap`。
- 一份 doc 的"前瞻方案"绝不允许混进 architecture——避免 "目标态污染当下系统地图"。

### M4. 阶段间硬 checkpoint + 三阶段闭环

**位置**: `cs-feat-{design,impl,accept}` 各自的"启动检查"和"退出条件"。

- 每阶段 frontmatter `status` 是上一阶段没通过的 hard gate (impl 启动检查 reject 没 approved 的 design)。
- 没有 hook 强制——靠 SKILL.md 在启动检查里读上一阶段产物状态, 不通过就 abort。
- 快速通道判定权前置: 走 ff 还是标准在第一阶段 (cs-issue-report / cs-feat) 拍板, 后续阶段不二次改判 (避免三阶段对路径各说各话)。
- accept 阶段 9 节验收报告 + 实写归并 (architecture / requirements / roadmap items.yaml), 三处档案在这一阶段同步。

### M5. 反射检查 (Reflective Guards)——按场景不按阈值

**位置**: `shared-conventions.md` §7 "写代码时的反射检查"。

七条触发场景:

1. 要往一个已经很长的文件追加代码时
2. 要给已经很多方法的类加方法时
3. 写的函数已超过一屏时
4. 要加 `if (特殊情况) { 特殊处理 }` 分支时
5. 要 copy-paste 一段代码时
6. 要给函数加第 4+ 个参数时
7. 要新写"万能工具类 / helper"时

**关键设计**: "**不是阈值, 是触发器**——硬数字会诱发为拆而拆把自然聚合的代码切碎。每条都是'遇到 X 情况就停下来问自己'"。

这是对 AI 编码默认失败模式 (在大文件里继续追加代码、补丁分支爆炸、过度抽象) 的一组清单化对抗。配套的还有 `cs-feat-impl` 三条姿态 (默认写最少代码 / 不顺手改邻居 / design 没说的不自己拍板) 和"补丁分支冲动 → 停"。

### M6. Checklist as 微型 build pipeline (三阶段共写一份 yaml)

**位置**: `shared-conventions.md` §2、`cs-feat-{design,impl,accept}`。

`{slug}-checklist.yaml` 是 git 跟踪的"运行时执行清单":

- design 一次生成 `steps[]` (4–8 步) + `checks[]`。
- impl 只动 `steps[].status` (pending → done), **不改 checks**。
- accept 只动 `checks[].status` (pending → passed/failed), **不改 steps**。
- 三方各负责一段不互相覆盖, 通过 `validate-yaml.py` 强校验。

这把 spec 和执行进度融合成单文件状态机, 让 git diff 能看出"这次工作做到第几步"。

### M7. 复利沉淀 (compound) + 强制再读

**位置**: `cs-{learn,trick,decide,explore}`、`shared-conventions.md` §5–6、`tools.md`。

- 4 种沉淀 doc_type 共一目录, 通过 frontmatter 区分。
- **强制再读**: feature-design / issue-analyze / issue-fix 启动检查里都有"按需归档检索" (`search-yaml.py --dir codestable/compound`), 命中已有 decision 冲突时**必须正面回应**而不是绕开。
- **起草前先查重叠**: 写新 doc 前 `--query` 搜语义相近的旧文档, 命中三选一: 更新已有 (默认) / supersede (旧 doc `status: superseded` + `superseded-by`) / 确认是不同主题。
- **只增不删**: 已归档除非被明确取代否则不删——理由丢失成本极高。

这把"经验复用"从习惯升级为工作流动作。

### M8. 可卸载性 (Removability) 作为 design 验收维度

**位置**: `cs-feat-design` "每个 feature 都要能被卸载"段、`cs-feat-accept` §2 反向核对。

- design 第 2.3 节强制列"挂载点清单": 删了它 feature 是否消失。3–5 条为正常区间 (太多 = 耦合扩散)。
- accept 阶段强制 grep 反向核查: 本 feature 在代码里的所有引用是否都落在清单内, 清单外引用 = 漏记, 必须补。
- 还有"拔除沙盘推演"——按清单逆向操作后是否还有残留。

把"feature 可被反向移除"作为 design 强制项, 这个反向思考维度是体系里很独特的一笔。

### M9 (奖励). "实写"语义对抗 AI 应付倾向

SKILL.md 里反复出现这种 wording:

- "归并是当下动作不是建议"
- "实际写文件的动作, 不是自评"
- "已知偏差暂不处理是反模式"
- "frontmatter 有 `roadmap` 却在第 7 节写'跳过'——有值就必须回写"

这种重复的、带否定句式的强调, 目的是对抗 AI"在报告里写一句应付过去"的倾向——让 acceptance 阶段不退化成填表。

---

## 10. 工程化深度 vs 包装层判断

### 10.1 真正工程化的部分

1. **`shared-conventions.md` (~250 行) 是真协议**: 路径 / 命名 / checklist 状态机 / scoped-commit 范围 / 归档检索 / 反射检查七大节互引扎实, 子技能引用它而非各自重复定义。
2. **两个 Python 脚本是真代码**: `search-yaml.py` 322 行带 fallback parser、PyYAML 可选、过滤 / 排序 / JSON 输出; `validate-yaml.py` 315 行带 mode 切换 / Windows UTF-8 stdout 修正 / `_check_required` 等。脚本可独立使用, 不绑定 CodeStable。
3. **每个 SKILL.md 的"启动检查 + 续作 + 主流程 + 退出条件 + 容易踩的坑"五件套**: 22 个 skill 格式高度一致, 可机械检查、可批量更新、读者预期稳定。
4. **roadmap items.yaml 的状态机**: 三方读写但通过明确状态转换互不破坏, 是体系里唯一定义清楚的多 skill 协调协议。
5. **反射检查 + 三条姿态**: 对 AI 编码失败模式的具体清单, 比一般"代码规范"落地得多。
6. **Skill 隔离对策**: `cs-onboard` 把 Anthropic Skills 物理限制变成体系约束并提供 `cp -rf` 释放方案, 是体系里最有"工程感"的设计。

### 10.2 偏向包装 / 文风 / prompt 劝告的部分

1. **大量"AI 思考方式"的劝告**: "AI 是思考伙伴不是记录员"、"宁缺毋滥"、"不替用户决定"——这些都是 prompt 层措辞, 没有 code-level enforcement。
2. **三种 case (1/2/3) 在 cs-brainstorm 的判定**: 表格清晰, 但 case 判定靠 Claude 主观判断, 没有客观信号 (用户说几个词、有几个目标——都是模糊条件)。
3. **frontmatter 字段口径分散**: 跨阶段共用字段在 `shared-conventions.md` §1 列出来, 但每个 skill 各自维护一份模板, 没有 schema 文件统一类型源。改字段需要在多个 SKILL.md 里同步搜索替换 (AGENTS.md 提了一句"增加、更新技能时注意更新其他相关技能中的表述")。
4. **"阶段间不能跳"是 prompt 层 enforcement**: 没有 hook 阻止用户绕开 design 直接调 impl, 靠 SKILL.md 启动检查发现并 abort。如果 Claude 模型 drift 了, 没有第二道防线。
5. **没有跨工作流状态视图**: `maintainer-notes.md` §2 自己承认这是缺失。"项目当前有几个 feature 在进行中" 仍需手动 `Glob` 配 `search-yaml.py`。
6. **沉淀类 4 个 skill 的差异化**: learning / trick / decision / explore 共目录、共大部分字段, 主要靠 `doc_type` 区分。判别口诀写在 `cs/SKILL.md`。逻辑上能做成一个 `cs-archive` 加 `--type` 参数, 拆成四个独立 skill 让用户多了"该用哪个"的选择负担——可能是设计上对 Skills 体系本身规模的让步 (每个 skill 一个独立触发词更好被 description NLU 命中)。
7. **refactor 子链 (beta)**: 目录结构与 feature 同构, 但本次未深读, 可能存在与 feature 复用代码 / 模板上的冗余。

### 10.3 整体倾向

CodeStable 在**对抗 AI 默认失败模式**和**项目档案体系建模**这两个方向上工程化非常深; 在**跨工作流自动化、监控、可观测**方向几乎裸跑——这是它的明示设计立场 (人在环, 不要 daemon)。

体系名称里的"严肃工程"是从**软件档案完整性**角度去定义"严肃"的, 不是从 ops 角度。这个定位决定了它能解决什么问题、不解决什么问题——具体的对比留给 workflow-comparer。

---

## 11. 实际查看过的关键文件 / 目录清单

### 全文读过

- `D:/data/CodeStable-main/README.md`
- `D:/data/CodeStable-main/AGENTS.md`
- `D:/data/CodeStable-main/CLAUDE.md`
- `D:/data/CodeStable-main/what-is-skills.md`
- `D:/data/CodeStable-main/cs/SKILL.md` (路由器)
- `D:/data/CodeStable-main/cs-onboard/SKILL.md`
- `D:/data/CodeStable-main/cs-feat/SKILL.md`
- `D:/data/CodeStable-main/cs-feat-design/SKILL.md`
- `D:/data/CodeStable-main/cs-feat-impl/SKILL.md`
- `D:/data/CodeStable-main/cs-feat-accept/SKILL.md`
- `D:/data/CodeStable-main/cs-issue/SKILL.md`
- `D:/data/CodeStable-main/cs-issue-analyze/SKILL.md`
- `D:/data/CodeStable-main/cs-issue-fix/SKILL.md`
- `D:/data/CodeStable-main/cs-roadmap/SKILL.md`
- `D:/data/CodeStable-main/cs-brainstorm/SKILL.md`
- `D:/data/CodeStable-main/cs-arch/SKILL.md`
- `D:/data/CodeStable-main/cs-onboard/reference/shared-conventions.md`
- `D:/data/CodeStable-main/cs-onboard/reference/system-overview.md`
- `D:/data/CodeStable-main/cs-onboard/reference/tools.md`
- `D:/data/CodeStable-main/cs-onboard/reference/maintainer-notes.md`
- `D:/data/CodeStable-main/cs-onboard/tools/search-yaml.py`
- `D:/data/CodeStable-main/cs-onboard/tools/validate-yaml.py`

### 仅 listing / 结构性扫过

- 所有 22 个 `cs-*` 目录的顶层 (SKILL.md 是否有 reference / reference.md / tools 子目录)
- `cs-onboard/reference/` 目录列表 (含 `code-dimensions.md`、`requirement-example.md` 仅看到文件名)
- `cs-onboard/tools/` 目录列表

### 未读 (留给 workflow-comparer 或后续追加)

- `cs-feat-ff/SKILL.md` (快速通道细节)
- `cs-issue-report/SKILL.md` (路径判定细节)
- `cs-req/SKILL.md`、`cs-explore/SKILL.md`、`cs-learn/SKILL.md`、`cs-trick/SKILL.md`、`cs-decide/SKILL.md`、`cs-note/SKILL.md`、`cs-guide/SKILL.md`、`cs-libdoc/SKILL.md`
- `cs-refactor/SKILL.md`、`cs-refactor-ff/SKILL.md` (beta 重构链)
- 各 skill 的 `reference.md` (二级细节)
- `code-dimensions.md`、`requirement-example.md` (reference 模板)

未读部分集中在沉淀类、对外文档类、refactor 链。已读部分覆盖了体系的入口、核心流程、状态机、协议、工具。

---

## 12. 给 workflow-comparer 的钩子 (供其使用)

如果要做 CodeStable vs 当前 harness 对比, 建议从这些维度切入:

1. **是否围绕实体建模** (CodeStable) vs 围绕 Agent / Workflow 建模。
2. **状态载体** (项目文件 vs runtime store / vault / memory)。
3. **跨阶段衔接协议** (CodeStable 的 items.yaml 状态机 vs 当前 harness 的 plan.md frontmatter / advance-stage)。
4. **自动化层次** (CodeStable 完全无 hook / daemon vs 当前 harness 的 advance-stage / verify-update-managed-assets / 等)。
5. **review 形态** (CodeStable 用户 review + cs-arch check 模式 vs 当前 harness 的 PLAN_REVIEW / CODE_REVIEW append-only 运行记)。
6. **复利知识库** (CodeStable compound + search-yaml 强制再读 vs 当前 harness 的 .assistant 共享 vault / Obsidian 记忆)。
7. **对 AI 失败模式的对抗** (CodeStable 反射检查七条 + 实写语义 vs 当前 harness 的 quality-score / hard constraints)。
8. **共享资产分发** (CodeStable cp -rf 释放 vs 当前 harness 的 managed-assets / verify-update-managed-assets)。
9. **入口形态** (CodeStable 的 22 个独立 slash skill vs 当前 harness 的 orchestrator + advance-stage + 各阶段 skill)。

这些钩子在我读过的 SKILL.md 里都有显式段落, comparer 可以直接引用。
