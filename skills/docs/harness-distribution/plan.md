# 开发 Harness 可分发项目整合 实施计划

> task_id: harness-distribution
> task_name: 开发 Harness 可分发项目整合
> 关联评审：`skills/docs/harness-distribution/plan-review.md`
> 创建日期：2026-04-01
> 状态：已确认
> review_status：已收敛
> delta-spec：无

## 1. 背景与目标

经过 `skill-consolidation` 和 `dev-stage-harness-refactor` 两轮迭代，当前 Harness 的核心流程已经稳定，但它仍然依赖一组分散在宿主目录、工作区目录和共享记忆仓库中的资产：

- `skills/` 本体与其文档
- 共享记忆脚本与 `vault-template`
- Claude / Codex 宿主入口配置
- 触发恢复/写回行为的 hooks 链
- 用户本地运行态、密钥和权限覆盖

当前计划不再把“可分发”定义为“新机器能加载 skills”即可，而是定义为：

1. 新机器 `git clone + install.ps1` 后，Claude / Codex 共享同一套 `skills/` 单源。
2. 共享记忆的关键行为可以被复现，包括：
   - resume 触发时优先读取恢复索引
   - 写共享运行时文件后自动刷新恢复索引
   - 停止会话前提醒未完成的运行时写回
3. Claude / Codex 两侧宿主入口配置、hooks 注册和共享脚本的部署路径明确、可渲染、可验证。
4. 用户本地密钥、权限白名单和运行时状态不进 Git，但安装后能与共享模板正确拼装。

## 2. 已消费输入

- `skills/docs/harness-distribution/plan-review.md`
- 当前 Harness 的真实资产分布与运行链路：
  - `%USERPROFILE%\.claude\skills\`
  - `%USERPROFILE%\.codex\skills\`
  - `%USERPROFILE%\.claude\CLAUDE.md`
  - `%USERPROFILE%\.claude\.claude\settings.local.json`
  - `%USERPROFILE%\.claude\hooks-memory\userpromptsubmit.js`
  - `%USERPROFILE%\.claude\hooks-memory\posttooluse.js`
  - `%USERPROFILE%\.claude\hooks-memory\stop.js`
  - `%USERPROFILE%\.codex\AGENTS.md`
  - `%USERPROFILE%\.codex\.claude\settings.local.json`
  - `%USERPROFILE%\.codex\config.toml`
  - `{WORKSPACE_ROOT}\AGENTS.md`
  - `{WORKSPACE_ROOT}\GEMINI.md`
  - `{WORKSPACE_ROOT}\.assistant\`

本计划不引入 `spec.md`，因为当前边界已经足够明确，缺口集中在资产建模与部署覆盖面，而不是需求本身。

## 3. 资产分层与占位符语义

### 3.1 三层资产边界

| 层 | 内容 | 是否入 Git | 部署方式 | 说明 |
|------|------|------|------|------|
| `shared assets` | `skills/`、canonical docs、共享 `.ps1` 脚本、`vault-template/`、验证脚本 | 是 | 直接存仓库 | Claude / Codex 共用单源 |
| `host-specific assets` | Claude 宿主模板、Codex 宿主模板、workspace 入口模板、`runtime-hooks/claude/*.js`、共享 hooks 注册模板、共享权限模板、Codex `config.toml` 的 managed block | 是 | `install.ps1` 渲染/复制/合并/补丁 | 决定宿主如何接入 shared assets |
| `user-local runtime` | 实际 `.assistant/运行时/*`、API 密钥、用户本地权限扩展、Codex provider/auth/project trust、本地 overlay、日志、备份 | 否 | 安装时保留或新建 | 机器相关、用户相关、敏感信息 |

### 3.2 占位符语义

| 占位符 | 语义 |
|------|------|
| `{REPO_ROOT}` | Harness 仓库根目录 |
| `{WORKSPACE_ROOT}` | 共享工作区根目录，包含 `AGENTS.md`、`GEMINI.md`、共享脚本入口和 `.assistant/` |
| `{VAULT_PATH}` | 实际 Obsidian Vault 路径，约定为 `{WORKSPACE_ROOT}\.assistant` |
| `{VAULT_ROOT}` | 兼容旧文档的迁移别名，语义等同 `{WORKSPACE_ROOT}`；新模板不再新增该占位符 |

结论：

- `AGENTS.md` / `GEMINI.md` 的目标位置是 `{WORKSPACE_ROOT}`，不是 `{VAULT_PATH}`。
- `CLAUDE.md` 的目标位置是 `%USERPROFILE%\.claude\CLAUDE.md`。
- Claude hooks 配置文件的目标位置是 `%USERPROFILE%\.claude\.claude\settings.local.json`。
- Claude hooks 脚本的目标位置是 `%USERPROFILE%\.claude\hooks-memory\*.js`。
- Codex 全局指令模板的目标位置是 `%USERPROFILE%\.codex\AGENTS.md`。
- Codex 本地设置模板的目标位置是 `%USERPROFILE%\.codex\.claude\settings.local.json`。
- Codex 配置模板/补丁的目标位置是 `%USERPROFILE%\.codex\config.toml`。

## 4. 技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| skills 单源 | 仓库 `skills/` 为唯一源，`%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` 均为 Junction | 解决镜像漂移，保持 Claude / Codex 使用同一份内容 |
| hooks 建模 | 新增 `runtime-hooks/claude/` 收纳 `userpromptsubmit.js`、`posttooluse.js`、`stop.js` | hooks 是运行行为链的一部分，必须纳入仓库与安装流程 |
| 宿主配置建模 | `agent-configs/claude/` 维护 `CLAUDE.md.template`、`settings.json.example`、`settings.local.shared.json.template`、`settings.local.user.example.json` | 显式区分“共享模板”与“用户本地敏感覆盖” |
| Codex 宿主配置建模 | `agent-configs/codex/` 维护 `AGENTS.md.template`、`settings.local.shared.json.template`、`settings.local.user.example.json`、`config.shared.toml.template`、`config.user.example.toml` | 把 Codex 宿主层从开放问题提升为本轮范围 |
| Codex `config.toml` 策略 | 安装脚本只管理共享的 skill/path 相关 block，保留用户本地 model/provider/auth/project trust | 避免覆盖用户私有配置，同时消除源机器 skill 绝对路径 |
| workspace 入口建模 | `agent-configs/workspace/` 维护 `AGENTS.md.template`、`GEMINI.md.template` | 避免再把目标位置写成模糊的“Vault 根目录” |
| 路径参数化范围 | 对 `skills/`、`scripts/`、`runtime-hooks/`、`agent-configs/`、`vault-template/` 的 `.md`、`.ps1`、`.json`、`.js`、`.mjs`、`.toml` 做统一扫描与替换 | review 指出当前遗漏了非 markdown / PowerShell 资产，包含 Codex `.toml` 配置模板 |
| 配置拆分策略 | `settings.local.shared.json.template` 只承载共享 hooks 注册、共享权限模板和占位符；用户特有敏感项进入本地 overlay | 安装后既有可复现行为，也不会把用户私有权限和密钥提交进仓库 |
| `vault-template/配置/` 去个性化策略 | `用户偏好.md`、`系统信息.md`、`工具与组件.md` 统一模板化或脱敏化后进入仓库，禁止直接复制当前实例 | 避免把用户名、机器路径、个人工具现状原样带入模板 |
| 共享脚本调用方式 | 共享脚本保留在仓库 `scripts/`，模板通过 `{REPO_ROOT}\scripts\...` 引用，不再要求复制到 `{WORKSPACE_ROOT}` | 保持单源，减少复制和分叉 |
| canonical docs 跟踪 | `skills/docs/*` 下的 `plan.md`、`review.md`、`test.md`、`handoff.md` 等保持纳管，不再一刀切忽略 | 这些是可分享的设计与验证证据，不属于每人本地运行态 |
| `.system` 处理 | 不纳入仓库；安装前备份原目录中的 `.system`，安装后验证宿主仍可访问 | 这部分由宿主工具自管，但需要兼容安装流程 |

## 5. 目标仓库结构

```text
claude-dev-harness/
├── README.md
├── install.ps1
├── uninstall.ps1
├── .gitignore
├── skills/
│   ├── using-superpowers/
│   ├── orchestrator/
│   ├── plan/
│   ├── implement/
│   ├── review/
│   ├── test/
│   ├── obsidian-memory/
│   ├── ...
│   └── docs/
│       ├── skill-consolidation/
│       ├── dev-stage-harness-refactor/
│       └── harness-distribution/
├── scripts/
│   ├── memory-health.ps1
│   ├── memory-health-report.ps1
│   ├── memory-maintain.ps1
│   ├── repair-shared-memory.ps1
│   ├── archive-memory-candidates.ps1
│   └── resolve-obsidian-memory-script.ps1
├── runtime-hooks/
│   └── claude/
│       ├── userpromptsubmit.js
│       ├── posttooluse.js
│       └── stop.js
├── vault-template/
│   ├── .obsidian/
│   ├── 首页.md
│   ├── MEMORY.md
│   ├── 配置/
│   │   ├── 用户偏好.md.template
│   │   ├── 系统信息.md.template
│   │   ├── 工具与组件.md.template
│   │   └── ...
│   ├── 工作流/
│   ├── 模板/
│   └── 运行时/
│       ├── tasks/.gitkeep
│       ├── 当前任务.md.template
│       ├── 中断任务.md.template
│       ├── 上次会话.md.template
│       ├── 恢复索引.md.template
│       ├── 收件箱.md.template
│       ├── 记忆候选.md.template
│       └── 记忆候选归档.md.template
├── agent-configs/
│   ├── claude/
│   │   ├── CLAUDE.md.template
│   │   ├── settings.json.example
│   │   ├── settings.local.shared.json.template
│   │   ├── settings.local.user.example.json
│   │   └── README.md
│   ├── codex/
│   │   ├── AGENTS.md.template
│   │   ├── settings.local.shared.json.template
│   │   ├── settings.local.user.example.json
│   │   ├── config.shared.toml.template
│   │   ├── config.user.example.toml
│   │   └── README.md
│   └── workspace/
│       ├── AGENTS.md.template
│       └── GEMINI.md.template
└── tests/
    ├── verify-installation.ps1
    └── forbidden-path-prefixes.txt
```

## 6. 安装目标映射

| 仓库资产 | 安装目标 | 方式 |
|------|------|------|
| `skills/` | `%USERPROFILE%\.claude\skills` | Junction |
| `skills/` | `%USERPROFILE%\.codex\skills` | Junction |
| `runtime-hooks/claude/*.js` | `%USERPROFILE%\.claude\hooks-memory\*.js` | 渲染后复制 |
| `agent-configs/claude/CLAUDE.md.template` | `%USERPROFILE%\.claude\CLAUDE.md` | 渲染写入 |
| `agent-configs/claude/settings.local.shared.json.template` + 用户本地 overlay | `%USERPROFILE%\.claude\.claude\settings.local.json` | merge-render |
| `agent-configs/codex/AGENTS.md.template` | `%USERPROFILE%\.codex\AGENTS.md` | 渲染写入 |
| `agent-configs/codex/settings.local.shared.json.template` + 用户本地 overlay | `%USERPROFILE%\.codex\.claude\settings.local.json` | merge-render |
| `agent-configs/codex/config.shared.toml.template` + 现有用户配置 | `%USERPROFILE%\.codex\config.toml` | managed-block patch |
| `agent-configs/workspace/AGENTS.md.template` | `{WORKSPACE_ROOT}\AGENTS.md` | 渲染写入 |
| `agent-configs/workspace/GEMINI.md.template` | `{WORKSPACE_ROOT}\GEMINI.md` | 渲染写入 |
| `vault-template/` | `{VAULT_PATH}` | 首次初始化/增量补齐 |
| `scripts/*.ps1` | 不复制；由模板引用 `{REPO_ROOT}\scripts\...` | 单源引用 |

## 7. 任务拆解

### Phase 1：资产建模与仓库骨架

- [ ] **TODO-1: 创建仓库骨架、迁移清单与 `.gitignore` 基线**
  - **描述**：初始化 `{REPO_ROOT}`，创建顶层目录，并产出一份迁移清单，逐项标注 shared assets / host-specific assets / user-local runtime 的归属、目标位置以及“源机器绝对路径前缀”黑名单。
  - **涉及目录**：
    - 新建：`{REPO_ROOT}\skills\`
    - 新建：`{REPO_ROOT}\scripts\`
    - 新建：`{REPO_ROOT}\runtime-hooks\claude\`
    - 新建：`{REPO_ROOT}\vault-template\`
    - 新建：`{REPO_ROOT}\agent-configs\claude\`
    - 新建：`{REPO_ROOT}\agent-configs\codex\`
    - 新建：`{REPO_ROOT}\agent-configs\workspace\`
    - 新建：`{REPO_ROOT}\tests\`
  - **依赖**：无
  - **验收标准**：
    - 仓库骨架可 `git status`
    - 迁移清单明确覆盖 `skills`、hooks、宿主配置、workspace 入口、共享脚本、运行态
    - `.gitignore` 只排除敏感配置、生成物和测试沙箱，不忽略 canonical docs
  - **验证命令**：
    ```powershell
    Set-Location {REPO_ROOT}
    git status
    ```

- [ ] **TODO-2: 搬迁 shared assets**
  - **描述**：将当前可共享的 skills、canonical docs 与共享 PowerShell 脚本搬入仓库；保持 `skills/docs/*` 为可追踪文档，不与运行态混淆。
  - **涉及文件/目录**：
    - 源：`%USERPROFILE%\.claude\skills\*`（排除 `.system/`、`.assistant/`、`.claude/`）
    - 源：当前共享记忆工作区根目录下的共享 `*.ps1`
    - 目标：`{REPO_ROOT}\skills\`
    - 目标：`{REPO_ROOT}\scripts\`
  - **依赖**：TODO-1
  - **验收标准**：
    - `skills/` 下包含全部自定义 skill 与文档
    - `scripts/` 下包含当前共享记忆维护脚本
    - `skills/docs/` 下的 `plan.md`、`review.md`、`test.md`、`handoff.md` 等 canonical docs 保持纳管
  - **验证命令**：
    ```powershell
    Get-ChildItem {REPO_ROOT}\skills | Select-Object Name
    Get-ChildItem {REPO_ROOT}\scripts\*.ps1 | Select-Object Name
    ```

- [ ] **TODO-3: 搬迁 hooks 与 Claude/Codex 宿主配置模板**
  - **描述**：把当前 hooks 链、Claude 宿主入口配置和 Codex 宿主入口配置显式建模进仓库。共享部分进入模板，用户本地敏感部分改为 overlay 示例或 managed block。
  - **涉及文件/目录**：
    - 源：`%USERPROFILE%\.claude\hooks-memory\*.js`
    - 源：`%USERPROFILE%\.claude\CLAUDE.md`
    - 源：`%USERPROFILE%\.claude\settings.json`
    - 源：`%USERPROFILE%\.claude\.claude\settings.local.json`
    - 源：`%USERPROFILE%\.codex\AGENTS.md`
    - 源：`%USERPROFILE%\.codex\.claude\settings.local.json`
    - 源：`%USERPROFILE%\.codex\config.toml`
    - 源：`{WORKSPACE_ROOT}\AGENTS.md`
    - 源：`{WORKSPACE_ROOT}\GEMINI.md`
    - 目标：`{REPO_ROOT}\runtime-hooks\claude\`
    - 目标：`{REPO_ROOT}\agent-configs\claude\`
    - 目标：`{REPO_ROOT}\agent-configs\codex\`
    - 目标：`{REPO_ROOT}\agent-configs\workspace\`
  - **依赖**：TODO-1
  - **验收标准**：
    - `runtime-hooks/claude/` 收纳 `userpromptsubmit.js`、`posttooluse.js`、`stop.js`
    - `settings.local.shared.json.template` 明确包含 hooks 注册、共享权限模板和路径占位符
    - `settings.local.user.example.json` 仅示例化用户本地扩展，不包含真实密钥或私有权限项
    - `agent-configs/codex/` 明确包含 `AGENTS.md.template`、`config.shared.toml.template` 与 Codex `settings.local` 处理策略
    - `config.shared.toml.template` 或对应 README 写清哪些字段由安装脚本托管，哪些字段仍保留为用户本地
    - `AGENTS.md.template` / `GEMINI.md.template` 的部署目标明确指向 `{WORKSPACE_ROOT}`
  - **验证命令**：
    ```powershell
    Get-ChildItem {REPO_ROOT}\runtime-hooks\claude | Select-Object Name
    Get-ChildItem {REPO_ROOT}\agent-configs\claude | Select-Object Name
    Get-ChildItem {REPO_ROOT}\agent-configs\codex | Select-Object Name
    Get-ChildItem {REPO_ROOT}\agent-configs\workspace | Select-Object Name
    ```

- [ ] **TODO-4: 构建 `vault-template/`**
  - **描述**：从当前 `.assistant/` 提取可共享的协议、模板和骨架；运行态目录只保留空骨架与 `.template` 文件，不把真实运行态数据带入仓库。`配置/` 中任何包含机器信息、用户偏好或工具路径的文件必须模板化、脱敏化或改为 `.template`，不得直接复制当前实例。
  - **涉及目录**：
    - 源：当前 `{VAULT_PATH}` 下的 `工作流/`、`模板/`、`配置/`、`.obsidian/`、`首页.md`、`MEMORY.md`
    - 目标：`{REPO_ROOT}\vault-template\`
  - **依赖**：TODO-1
  - **验收标准**：
    - `vault-template/` 可初始化一个空的共享记忆仓库
    - `运行时/` 中只有 `.template` 与 `.gitkeep`
    - `配置/用户偏好.md`、`配置/系统信息.md`、`配置/工具与组件.md` 以 `.template` 或脱敏模板形式存在
    - 不包含任何真实任务状态、密钥、用户名、源机器路径或用户私有偏好
  - **验证命令**：
    ```powershell
    Get-ChildItem {REPO_ROOT}\vault-template -Recurse | Select-Object FullName
    ```

### Phase 2：统一参数化与路径收敛

- [ ] **TODO-5: 对共享资产和宿主资产做统一参数化**
  - **描述**：对 `skills/`、`scripts/`、`runtime-hooks/`、`agent-configs/`、`vault-template/` 做 repo-wide 路径与占位符收敛。扫描范围必须覆盖 `.md`、`.ps1`、`.json`、`.js`、`.mjs`、`.toml`，其中 `agent-configs/codex/config.shared.toml.template` 与 `config.user.example.toml` 也视为 operational assets。
  - **目标替换**：
    - 当前机器的 workspace 根路径 → `{WORKSPACE_ROOT}`
    - 当前机器的 `.assistant` 路径 → `{VAULT_PATH}`
    - 当前机器的仓库根路径 → `{REPO_ROOT}`
    - 历史遗留的 `{VAULT_ROOT}` 新写入一律替换为 `{WORKSPACE_ROOT}`
  - **依赖**：TODO-2、TODO-3、TODO-4
  - **验收标准**：
    - operational assets 中不残留源机器绝对路径
    - hooks 脚本与 `settings.local.shared.json.template` 中的路径全部由占位符驱动
    - `agent-configs/codex/config.shared.toml.template` 不残留源机器的 `%USERPROFILE%\.codex\skills\...` 绝对路径
    - `AGENTS.md.template` / `GEMINI.md.template` 不再写成“Vault 根目录”
  - **验证命令**：
    ```powershell
    $patterns = Get-Content {REPO_ROOT}\tests\forbidden-path-prefixes.txt
    Get-ChildItem {REPO_ROOT} -Recurse -Include *.md,*.ps1,*.json,*.js,*.mjs,*.toml |
      Select-String -Pattern ($patterns | ForEach-Object { [regex]::Escape($_) })
    ```

### Phase 3：安装、卸载与验证

- [ ] **TODO-6: 编写 `install.ps1`**
  - **描述**：实现一键安装脚本，至少接受 `-WorkspaceRoot` 参数，并据此推导 `{VAULT_PATH}`。脚本步骤包括：
    1. 备份现有 `%USERPROFILE%\.claude\skills`、`%USERPROFILE%\.codex\skills`、`%USERPROFILE%\.claude\hooks-memory`、`%USERPROFILE%\.claude\CLAUDE.md`、`%USERPROFILE%\.claude\.claude\settings.local.json`、`%USERPROFILE%\.codex\AGENTS.md`、`%USERPROFILE%\.codex\.claude\settings.local.json`、`%USERPROFILE%\.codex\config.toml`
    2. 初始化或补齐 `{VAULT_PATH}`
    3. 渲染 `CLAUDE.md`、`AGENTS.md`、`GEMINI.md`
    4. 渲染 `%USERPROFILE%\.codex\AGENTS.md`
    5. 部署 `runtime-hooks/claude/*.js`
    6. 以“共享模板 + 用户本地 overlay/已有配置”的方式分别生成 Claude / Codex 的 `settings.local.json`
    7. 以 managed-block patch 的方式更新 `%USERPROFILE%\.codex\config.toml`，只处理共享 `skills` 路径和共享工作区相关字段，保留 model/provider/auth/project trust
    8. 创建 Claude / Codex 的 `skills` Junction
    9. 处理 `.system` 的保留与兼容
    10. 输出安装摘要与仍需手动完成的敏感配置步骤
  - **涉及文件**：
    - 新建：`{REPO_ROOT}\install.ps1`
  - **依赖**：TODO-5
  - **验收标准**：
    - 安装后 Claude / Codex 均指向同一份 `skills/`
    - Claude 宿主存在可执行的 hooks 配置与脚本
    - Codex 宿主存在正确渲染的 `AGENTS.md`、`settings.local.json` 和 `config.toml` managed block
    - workspace 根目录存在正确渲染的 `AGENTS.md` / `GEMINI.md`
    - 未覆盖用户本地敏感项
  - **验证命令**：
    ```powershell
    Set-Location {REPO_ROOT}
    .\install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}
    ```

- [ ] **TODO-7: 编写 `uninstall.ps1`**
  - **描述**：实现安全回滚，移除 Junction、恢复备份的 Claude/Codex hooks 与宿主配置，并明确哪些用户本地文件不自动删除。
  - **涉及文件**：
    - 新建：`{REPO_ROOT}\uninstall.ps1`
  - **依赖**：TODO-6
  - **验收标准**：
    - 卸载后 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` 恢复为普通目录或已知备份状态
    - hooks、Claude/Codex `settings.local.json`、Codex `config.toml` 可恢复到安装前
    - 不误删 `{VAULT_PATH}\运行时\` 用户数据

- [ ] **TODO-8: 编写安装验证脚本**
  - **描述**：补齐 `tests/verify-installation.ps1`，覆盖目录链接、模板渲染、hooks 部署、Claude/Codex settings 合成、Codex `config.toml` managed block、仓库内 `.toml` 模板路径检查、共享记忆健康检查和关键行为的静态/轻量验证。
  - **涉及文件**：
    - 新建：`{REPO_ROOT}\tests\verify-installation.ps1`
  - **依赖**：TODO-6
  - **验收标准**：
    - 检查 Junction 是否指向 `{REPO_ROOT}\skills`
    - 检查 `settings.local.json` 中存在 `UserPromptSubmit`、`PostToolUse`、`Stop` hooks 注册
    - 检查 hooks 脚本内的 `{VAULT_PATH}` 已正确渲染
    - 检查 `%USERPROFILE%\.codex\AGENTS.md` 已部署到预期位置
    - 检查 `%USERPROFILE%\.codex\config.toml` 不再包含源机器的 `%USERPROFILE%\.codex\skills\...` 绝对路径
    - 检查仓库内 `agent-configs/codex/*.toml` 模板本身不残留源机器路径
    - 检查 Codex 能读取共享 `skills/` 和共享工作区说明
    - 执行共享记忆健康检查时返回 `STATUS: PASS`
  - **验证命令**：
    ```powershell
    Set-Location {REPO_ROOT}
    .\tests\verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}
    ```

### Phase 4：文档、切换与收尾

- [ ] **TODO-9: 编写 `README.md`**
  - **描述**：补齐安装、升级、回滚、自定义和故障排查文档，重点解释三层资产边界、hooks 链、Claude/Codex `settings.local` 模板与用户 overlay 的关系，以及 Codex `config.toml` 的托管边界。
  - **涉及文件**：
    - 修改：`{REPO_ROOT}\README.md`
  - **依赖**：TODO-6、TODO-7、TODO-8
  - **验收标准**：
    - 新用户仅凭 README 可完成安装
    - README 明确哪些文件进 Git，哪些文件只保留在本地
    - README 说明 `AGENTS.md` / `GEMINI.md` / `CLAUDE.md` / Codex `AGENTS.md` / Codex `config.toml` 的实际部署位置与托管边界

- [ ] **TODO-10: 将自身环境切换到仓库模式**
  - **描述**：在当前机器执行安装脚本，把现有散布资产切换到“仓库单源 + 宿主模板 + hooks 部署 + workspace 入口”的目标形态。
  - **依赖**：TODO-8、TODO-9
  - **验收标准**：
    - Claude / Codex 均加载新仓库中的 `skills/`
    - resume / post-tool / stop hooks 行为正常
    - Codex 侧 `AGENTS.md` 与 `config.toml` 已切换到仓库管理的共享路径方案
    - `memory-health.ps1` 返回 `STATUS: PASS`
  - **验证命令**：
    ```powershell
    Set-Location {REPO_ROOT}
    .\install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}
    .\tests\verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}
    ```

- [ ] **TODO-11: 首次提交并推送**
  - **描述**：确认仓库内仅包含 shared assets 与 host-specific templates，不含用户本地运行态和敏感信息后，完成首次提交与推送。
  - **依赖**：TODO-10
  - **验收标准**：
    - 远程仓库可被其他机器克隆并执行安装
    - 不包含密钥、用户私有权限白名单和运行时任务数据

## 8. 依赖关系与执行顺序

```text
Phase 1（建模与骨架）:
  TODO-1
    ├─ TODO-2（shared assets）
    ├─ TODO-3（hooks + host configs）
    └─ TODO-4（vault-template）

Phase 2（统一参数化）:
  TODO-2 + TODO-3 + TODO-4 → TODO-5

Phase 3（安装与验证）:
  TODO-5 → TODO-6（install.ps1）
  TODO-6 → TODO-7（uninstall.ps1）
  TODO-6 → TODO-8（verify-installation.ps1）

Phase 4（文档与切换）:
  TODO-6 + TODO-7 + TODO-8 → TODO-9（README）
  TODO-8 + TODO-9 → TODO-10（自身切换）
  TODO-10 → TODO-11（首次提交）
```

**关键路径**：`TODO-1 → TODO-3 → TODO-4 → TODO-5 → TODO-6 → TODO-8 → TODO-10 → TODO-11`

## 9. Handoff 预期

进入 DEV 之前，计划需要为下游实现与验证阶段留下可直接消费的边界：

- `install.ps1` 的 handoff 必须明确：
  - skills Junction 目标
  - hooks 脚本部署目标
  - Claude / Codex `settings.local` 的 shared template / user overlay 合并规则
  - Codex `config.toml` 的 managed block 边界
  - `AGENTS.md` / `GEMINI.md` / `CLAUDE.md` / Codex `AGENTS.md` 的确定落点
- REVIEW / TEST 阶段的重点 watchouts 必须提前写清：
  - 不得把真实密钥、用户私有权限项和运行态任务文件纳入仓库
  - 不得只验证“能加载 skill”，必须验证 hooks 链和共享记忆健康检查
  - 不得遗漏 Codex 宿主侧的共享路径、全局指令和配置补丁
  - 不得把 canonical docs 当作本地态忽略掉
- 最终 `handoff.md` 至少要说明：
  - 哪些资产是 shared assets
  - 哪些资产由安装脚本渲染到宿主
  - Codex `config.toml` 中哪些字段被托管、哪些字段保留用户本地
  - 哪些资产仍然是 user-local runtime，必须由操作者自行保留

## 10. `.gitignore` 原则

`.gitignore` 只排除以下三类内容：

1. 用户本地敏感配置
   - 真实 `settings.json`
   - 用户本地 `settings.local` overlay
   - 密钥、`.env`、私有 token 文件
2. 安装与验证生成物
   - 备份目录
   - 测试沙箱
   - 临时渲染文件
3. 本地 UI/OS 噪音
   - `.obsidian/workspace.json`
   - `Thumbs.db`
   - `.DS_Store`

明确不忽略：

- `skills/docs/*/plan.md`
- `skills/docs/*/review.md`
- `skills/docs/*/test.md`
- `skills/docs/*/handoff.md`

这些文档属于仓库内 canonical 设计与验证证据，不属于用户本地运行态。

## 11. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| 只迁 skills，不迁 hooks 链 | 新环境能加载 skill，但无法复现恢复/写回行为 | TODO-3、TODO-6、TODO-8 把 hooks 作为一等资产处理 |
| 只覆盖 Claude 宿主，不覆盖 Codex 宿主 | 共享项目只能复现 Claude 侧，无法稳定复现 Codex 集成 | TODO-3、TODO-6、TODO-8 把 `%USERPROFILE%\.codex\AGENTS.md`、`settings.local.json`、`config.toml` 纳入当前范围 |
| `settings.local.json` 混入私有权限和敏感配置 | 安装模板不可分享，或误提交私有权限 | 拆分 shared template 与 user overlay；安装时 merge-render |
| Codex `config.toml` 被整文件覆盖 | 用户本地 model/provider/auth/project trust 丢失 | 仅管理 shared managed block，禁止全量覆盖 |
| `AGENTS.md` / `GEMINI.md` 部署目标继续模糊 | workspace 根目录缺少正确入口文件 | 在占位符语义和安装映射中显式固定到 `{WORKSPACE_ROOT}` |
| 参数化只覆盖 `.md` / `.ps1` | hooks、JSON 或 `.toml` 配置仍残留绝对路径 | TODO-5 扩大到 `.json` / `.js` / `.mjs` / `.toml` 的 repo-wide 扫描 |
| `vault-template/配置/` 直接复制当前实例 | 用户名、机器路径和当前工具现状泄漏到模板 | TODO-4 强制模板化/脱敏 `用户偏好.md`、`系统信息.md`、`工具与组件.md` |
| `.gitignore` 忽略过宽 | canonical review/test/handoff 文档丢失 | 仅忽略本地态和生成物，不再忽略仓库内证据文档 |
| `.system` 与 Junction 冲突 | 宿主工具失去系统 skill | 安装前备份、安装后验证 `.system` 可访问 |

## 12. 验收标准

| AC | 描述 | 验证方式 |
|----|------|----------|
| AC-1 | 仓库包含完整 shared assets、`runtime-hooks/claude/`、Claude/Codex 宿主模板和 `vault-template/` | 文件清单检查 |
| AC-2 | 对整个仓库的 `.md`、`.ps1`、`.json`、`.js`、`.mjs`、`.toml` 执行“基于迁移清单的源机器前缀”搜索时，不命中源机器绝对路径 | `Select-String` repo-wide 扫描 |
| AC-3 | `install.ps1` 在干净 Windows 环境下可成功部署 Junction、hooks、Claude/Codex 宿主模板和 workspace 入口文件 | 安装演练 |
| AC-4 | 安装后 Claude 与 Codex 实际指向同一份 `skills/` | Junction 检查 |
| AC-5 | 安装后 `settings.local.json` 已注册 `UserPromptSubmit`、`PostToolUse`、`Stop` hooks | JSON 检查 |
| AC-6 | 安装后 resume / post-tool / stop 三类 hooks 的依赖文件全部存在且路径已渲染 | 文件与配置检查 |
| AC-7 | 安装后共享记忆健康检查返回 `STATUS: PASS` | 运行 `{REPO_ROOT}\scripts\memory-health.ps1` |
| AC-8 | `AGENTS.md` / `GEMINI.md` / `CLAUDE.md` / Codex `AGENTS.md` / Claude-Codex 两侧 `settings.local.json` 分别出现在规定目标位置并完成渲染 | 路径检查 |
| AC-9 | `%USERPROFILE%\.codex\config.toml` 不再保留源机器 skill 绝对路径，且仓库内 `agent-configs/codex/*.toml` 模板同样不残留源机器路径，并仍保留用户本地 model/provider/auth/project trust | 配置检查 |
| AC-10 | `vault-template/配置/` 中的 `用户偏好` / `系统信息` / `工具与组件` 已模板化或脱敏，不包含用户名与源机器路径 | 模板走查 |
| AC-11 | 仓库内不包含密钥、真实用户 overlay 和运行时任务状态 | 手动审查 + `.gitignore` 检查 |
| AC-12 | 新用户仅凭 `README.md` 可完成安装、验证与回滚 | 文档走查 |

## 13. 开放问题

| # | 问题 | 当前结论 |
|---|------|--------|
| 1 | `.system` 在 Junction 模式下由宿主自动重建，还是需要安装脚本补拷？ | 待在 TODO-6 / TODO-8 中实测后收敛 |
| 2 | 第一轮是否支持 macOS / Linux？ | 第一轮仅支持 Windows；跨平台安装另行补 `install.sh` |
| 3 | Codex 后续是否需要独立 hooks，而不只是 `AGENTS.md` / `settings.local` / `config.toml`？ | 本轮先完成 Codex 宿主模板化与配置托管；若后续出现 Codex hook 需求，再单独扩展 `runtime-hooks/codex/` |
