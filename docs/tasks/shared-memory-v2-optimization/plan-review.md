# Shared Memory v2 Plan Review

Verdict: `revise`

## Findings

### P1 · 计划声称要收口 dual-vault / truth-source leakage，但真实的 vault 与脚本解析入口完全没进改动面，核心目标 2 仍然落不到运行态

- `plan.md:15-16` 与 `plan.md:24-25` 把“项目本地 `<workspace>/.assistant/` 是任务级运行时唯一真相源、user-level vault 仅承载跨项目偏好”写成了验收标准。
- 但 `affected_paths` 只覆盖协议文档、模板、一个新静态扫描器和 `check-shared-memory.ps1`，没有包含真实决定“这次命令到底打到哪个 vault、跑哪个实现”的入口：`plan.md:40-55` 与 `plan.md:74-89` 均缺少 `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`、`scripts/resolve-obsidian-memory-script.ps1`、`skills/obsidian-memory/scripts/runtime-inbox-common.ps1`。
- 现实实现仍然是多源解析：`resolve-shared-memory-paths.ps1:70-129` 依次接受显式 `-VaultRoot`、`CLAUDE_DEV_HARNESS_VAULT_PATH`、`OBSIDIAN_SHARED_VAULT`、`current-flow.shared_vault_root`、workspace `.assistant`、环境变量 workspace、`OrchestratorFlowPath` 父目录、当前目录向上搜索等多个候选，并直接返回第一个命中的 vault。
- shared-memory wrapper 也仍可回落到用户 home 下的 skill 实现：`scripts/resolve-obsidian-memory-script.ps1:13-41` 会在 repo 脚本之外继续枚举 `%USERPROFILE%\.claude` / `.codex` / `.gemini` 下的 `skills\obsidian-memory\scripts\*`。
- inbox 入口的“当前任务是谁”也仍优先信 `current-flow`：`runtime-inbox-common.ps1:243-269` 明确写了“优先 current-flow，再退回当前任务指针”，`append-runtime-inbox.ps1:1-40` 也把这条优先级固化在真实入口上。
- 这意味着即使新加了 `docs/shared-memory-layers.md` 和静态检查，命令仍可能命中非项目本地 vault、命中 user-home 实现、或继续把 `current-flow` 当更高优先级输入。计划现在是在“补说明”，不是在“收口真实解析面”。

### P1 · 新契约要求 `entry_host` / `derived_from` / best-effort 写回成为 authoritative 规则，但计划没有覆盖真实热 writer，反而会制造“文档已升级、运行时仍产旧 shape”的新漂移

- 计划把 `entry_host`、`derived_from`、单向写回阶梯和最小写入面写成硬契约：`plan.md:17-20`、`plan.md:37`、`plan.md:127-161`。
- 但 implementation surface 已经明确，真实会写这些运行时文件的不是模板和 checker，而是多组热 writer：`implementation-surface.md:29-37`、`implementation-surface.md:45-79`、`implementation-surface.md:111-137`。
- 其中最关键的 `advance-stage.ps1` 仍然直接写 `.assistant/运行时/tasks/<task-id>.md`、`当前任务.md`、`恢复索引.md`：`scripts/advance-stage.ps1:1202-1243`。它当前生成的 `当前任务.md` 只有 `writer: advance-stage`，没有 `entry_host`（`scripts/advance-stage.ps1:977-1033`）；生成的 `恢复索引.md` 仍是简单列表，也没有 `derived_from` frontmatter（`scripts/advance-stage.ps1:1069-1075`）。
- repair / hook writer 也还是旧 shape：`repair-shared-memory.ps1:72-119` 写出的 `当前任务.md` 同样只有 `writer: repair-shared-memory`，`posttooluse.js:202-223` 写出的 `恢复索引.md` 也没有 `derived_from`。
- 但这些 writer 都不在本计划的 `affected_paths` 里，且 `plan.md:37` 还把 `scripts/advance-stage.ps1` 主体逻辑列为非目标。结果就是：模板、协议和静态检查升级了，真实运行态输出却不会随之收敛；新 checker 最终只能验证 fixture / 文档，不能证明 live path 符合新 contract。

### P2 · Verification 面既过宽又过窄：重新拉进不相干的 Phase 1-4 回归，却漏掉现有 shared-memory 回归链，不能算“可执行且成比例”

- 计划的验证主轴写成“Phase 1/2/3/4 全套 verify-* + 少量新检查”：`plan.md:167-186`。
- 这会重新打开一大批与本任务无直接耦合的 workflow / tool-profile / skill / team 回归，但 implementation surface 指出的真实 shared-memory 风险点其实集中在 inbox / repair / hook / maintain / health 这条链：`implementation-surface.md:54-79`、`implementation-surface.md:81-190`。
- 仓库今天已经有对应的 shared-memory 回归脚本，但计划没有把它们纳入显式 gate：`tests/verify-repair-shared-memory.ps1:1`、`tests/verify-runtime-hooks.ps1:1`、`tests/verify-runtime-inbox.ps1:1`、`tests/verify-promote-runtime-inbox.ps1:1`、`tests/verify-memory-maintain.ps1:1`、`tests/verify-memory-health-report.ps1:1`、`tests/verify-archive-memory-candidates.ps1:1`、`tests/verify-triage-runtime-inbox.ps1:1`。
- 当前写法会出现两个问题：一是跑很多不相关回归，scope 不成比例；二是恰好漏掉最能证明 shared-memory 契约没有回归的现有测试链。对一个“共享记忆结构收紧”任务来说，这个验证面不够聚焦，也不够防回归。

## Open Questions / Assumptions

- 假设：本任务的目标不是“只补一套文档和静态 lint”，而是真正减少 dual-vault ambiguity、truth-source leakage 和 single-writer inconsistency。如果作者本意只是先做协议文档化，那么 `验收标准` 就需要显著收窄，不能继续把“唯一真相源”“dual-vault 收口”“单向写回阶梯落地”写成已经可验证的运行态结果。

## Change Summary

- 计划的方向是对的：把 4 层真相源收敛为单一映射文档、明确 team-board 只是 mirror、继续禁止 runtime hook 强制落地，都能避免本轮扩到无关 workflow 主路径。
- 但当前版本还没有对准真实 implementation surface。最大缺口不在协议文档，而在真实 resolver / writer / shared-memory regression chain 没被纳入本轮变更和验证。

## Evidence / Commands

- 文档与实现面检查：
  - `Get-Content docs/tasks/shared-memory-v2-optimization/plan.md`
  - `Get-Content docs/tasks/shared-memory-v2-optimization/implementation-surface.md`
  - `Get-Content docs/tasks/shared-memory-v2-optimization/validation-baseline.md`
  - 带行号检查：`plan.md`、`implementation-surface.md`、`validation-baseline.md`
  - `Get-Content scripts/resolve-obsidian-memory-script.ps1`
  - `Get-Content skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`
  - `Get-Content skills/obsidian-memory/scripts/runtime-inbox-common.ps1`
  - `Get-Content skills/obsidian-memory/scripts/append-runtime-inbox.ps1`
  - `Get-Content skills/obsidian-memory/scripts/repair-shared-memory.ps1`
  - `Get-Content skills/obsidian-memory/scripts/check-shared-memory.ps1`
  - `Get-Content runtime-hooks/claude/posttooluse.js`
  - `Get-Content scripts/advance-stage.ps1`
- 实际执行：
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`
  - `Get-ChildItem .\tests -Filter 'verify-*.ps1' | Sort-Object Name`

## Run 2

Verdict: `revise`

### Findings

#### P1 · `task-runtime/v1.1` 的 `entry_host` 契约仍未闭合到 live writers，Run 1 的 hot-writer conformance 只解决了一半

- 新版计划已经把 resolver / loader 热路径和 3 个主 writer 拉进 scope，这两点本身是实质收敛：`plan.md:61-67`、`plan.md:195-227` 已覆盖 `resolve-shared-memory-paths.ps1`、`resolve-obsidian-memory-script.ps1`、`runtime-inbox-common.ps1`、`advance-stage.ps1`、`repair-shared-memory.ps1`、`posttooluse.js`；Verification 也已收敛到 shared-memory 回归链：`plan.md:233-264`。
- 但同一版计划又把 `task-runtime/v1.1` 的最低字段表升级为包含 `entry_host`：`plan.md:27`、`plan.md:50`、`plan.md:152-157`。
- implementation surface 指出的 `tasks/<task-id>.md` live writers 仍然有 3 个：`implementation-surface.md:30`、`implementation-surface.md:48`、`implementation-surface.md:62`、`implementation-surface.md:120-123`。
- 当前代码里，`promote-runtime-inbox.ps1` 的 `New-TaskRuntimeDocument` 仍只写 `schema_version / task_id / task_name / workspace / primary_artifact`，没有 `entry_host`：`skills/obsidian-memory/scripts/promote-runtime-inbox.ps1:168-215`。
- `repair-shared-memory.ps1` 的 task-runtime builder 也同样没有 `entry_host`：`skills/obsidian-memory/scripts/repair-shared-memory.ps1:197-208`。
- 但新版计划对 live writer 的改动只写到了 `当前任务.md`、`恢复索引.md`、`runtime.lock.json` 和 advance-stage 的 best-effort 包裹：`plan.md:64-67`、`plan.md:208-227`；并没有把 `promote-runtime-inbox.ps1` 或 `repair-shared-memory.ps1` 的 `task-runtime` 输出纳入 conformance 改动。
- 对应验证也没有锁这条新 schema 要求。`plan.md:223-227` 明确说 `verify-promote-runtime-inbox.ps1` 等回归“不改 fixture / 断言”；而当前 `verify-promote-runtime-inbox.ps1` 只断言 `schema_version: task-runtime/v1.1` 和 `primary_artifact`，没有任何 `entry_host` 断言：`tests/verify-promote-runtime-inbox.ps1:195-201`。
- 结果是：Run 1 的第 2 条 finding 只对 `当前任务.md` / `恢复索引.md` / `runtime.lock.json` 闭合了，但写回阶梯中的 `tasks/<task-id>.md` 仍会被 live paths 产出为不含 `entry_host` 的旧 shape。既然本版计划已经把 `task-runtime/v1.1` 规范提升到包含 `entry_host`，这仍然是未闭合的 contract drift。

### Closure Summary

- Closure point 1：基本解决。真实 resolver / loader 热路径已进入 scope，canonical-vault claim 不再只是文档化声明。
- Closure point 3：基本解决。Verification 已改为 shared-memory regression surface 为主，只保留 `verify-workflow-contracts.ps1` 作为与 `advance-stage.ps1` 直接相关的窄 workflow guard。
- Closure point 2：仍需 revise。`entry_host` 合约没有覆盖 `tasks/<task-id>.md` 这条 live writer 面，也没有对应断言锁住。

### Evidence / Commands

- `Get-Content docs/tasks/shared-memory-v2-optimization/plan.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/implementation-surface.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/validation-baseline.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/plan-review.md`
- 带行号检查：
  - `plan.md`
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
  - `scripts/advance-stage.ps1`
  - `tests/verify-promote-runtime-inbox.ps1`
  - `tests/verify-repair-shared-memory.ps1`
  - `implementation-surface.md`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`
- `Get-ChildItem .\tests -Filter 'verify-*.ps1' | Sort-Object Name`

## Run 3

Verdict: `revise`

### Findings

#### P1 · `task-runtime/v1.1` 的 `entry_host` 最低契约仍没有被所有 live task-runtime writers 和对应回归锁住，尤其是 `promote-runtime-inbox.ps1`

- 新版计划保留了 Run 2 的 schema 口径：`task-runtime/v1.1` 最低字段表加 `entry_host`，见 `plan.md:50` 与 `plan.md:152-157`。
- 但 live task-runtime writers 里，`promote-runtime-inbox.ps1` 仍未真正进入这条契约的实现范围。它不在 `affected_paths` 里：`plan.md:45-67`、`plan.md:96-121`；对应 TODO 也没有任何一条要求修改 `New-TaskRuntimeDocument` 输出 `entry_host`。
- 这不是抽象担忧，而是现有实现的直接缺口：`skills/obsidian-memory/scripts/promote-runtime-inbox.ps1:168-215` 的 task-runtime 文档仍只写 `schema_version / task_id / task_name / workspace / primary_artifact`，没有 `entry_host`。
- `repair-shared-memory.ps1` 虽然在 `affected_paths` 里，但它的 conformance 范围也只覆盖 `当前任务.md`、`恢复索引.md` 和 `runtime.lock.json`。`plan.md:213-217` 没有要求修改 `New-TaskRuntimeContent`；而当前代码的 task-runtime builder 同样不写 `entry_host`：`skills/obsidian-memory/scripts/repair-shared-memory.ps1:170-208`。
- 回归锁定也没补上。计划明确写 `verify-promote-runtime-inbox.ps1`、`verify-runtime-inbox.ps1`、`verify-triage-runtime-inbox.ps1`、`verify-archive-memory-candidates.ps1`、`verify-memory-maintain.ps1`、`verify-memory-health-report.ps1` “不改 fixture / 断言”：`plan.md:223-227`。其中最关键的 `verify-promote-runtime-inbox.ps1` 当前只断言 `schema_version: task-runtime/v1.1` 和 `primary_artifact`，没有任何 `entry_host` 断言：`tests/verify-promote-runtime-inbox.ps1:195-201`。
- `verify-repair-shared-memory.ps1` 的新增范围也只锁 `当前任务.md` / `恢复索引.md` / `runtime.lock.json`，没有 task-runtime 最低字段的断言，和 `plan.md:223-225` 的写法一致。
- 所以这轮 scoped item 仍未闭合：计划已经把 `entry_host` 写进 `task-runtime/v1.1` 的最低契约，但还没有把 `promote-runtime-inbox.ps1`、`repair-shared-memory.ps1` 的 task-runtime 输出，以及对应的 `verify-promote-runtime-inbox.ps1` / repair task-runtime assertions 一起收紧。

### Closure Summary

- 已关闭项保持关闭：resolver / loader 热路径 scope 与 broad verification-surface 收敛没有被这次修订破坏。
- 本轮唯一剩余问题：`task-runtime/v1.1` 的 `entry_host` 契约还没有在所有 live task-runtime writers 和对应回归里真正落地。

### Evidence / Commands

- `Get-Content docs/tasks/shared-memory-v2-optimization/plan.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/implementation-surface.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/validation-baseline.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/plan-review.md`
- 带行号检查：
  - `plan.md`
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
- `tests/verify-promote-runtime-inbox.ps1`
- `tests/verify-repair-shared-memory.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`

## Run 4

Verdict: `revise`

### Findings

#### P2 · `promote-runtime-inbox` / `verify-promote-runtime-inbox` 已被拉进 scope，但 non-goal 仍把可修改的 exact-string 断言限定为 `verify-repair-shared-memory.ps1` / `verify-runtime-hooks.ps1`，计划内部口径还没完全自洽

- scoped item 的主体改动已经基本补齐：
  - live task-runtime writer scope 现在明确包含 `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1` 与 `skills/obsidian-memory/scripts/repair-shared-memory.ps1`，见 `plan.md:64-66`、`plan.md:117-119`。
  - `promote-runtime-inbox.ps1` 的 task-runtime `entry_host` conformance 也已写进 TODO：`plan.md:222-225`。
  - regression coverage 现在明确要求 `tests/verify-promote-runtime-inbox.ps1` 锁定 promoted `运行时/tasks/<task-id>.md` frontmatter 的 `entry_host:`，repair 侧也要求锁 repair-side 自动补建 task-runtime 的 `entry_host:`，见 `plan.md:227-231`。
- 但 non-goal 还保留着旧的限制口径：`plan.md:43` 仍写“本 Phase 仅允许更新与 hot writer 直接相关的 `verify-repair-shared-memory.ps1` / `verify-runtime-hooks.ps1` 中…固定字符串断言”。
- 这和当前 `affected_paths` 已显式纳入 `tests/verify-promote-runtime-inbox.ps1`（`plan.md:121`），以及 TODO 15 已要求更新该测试的事实直接冲突。
- 如果 implementer 按 non-goal 字面执行，就会回避 `verify-promote-runtime-inbox.ps1` 的断言更新；如果按 TODO/affected_paths 执行，又违反 non-goal。对这轮 scoped focus 来说，这是唯一剩余的不一致点。

### Closure Summary

- “所有 live task-runtime writers 是否已进 scope”这一点现在基本闭合。
- “回归是否锁住最小 contract”这一点也基本闭合，promote / repair 两侧的断言目标都已写进计划。
- 剩余问题只是一条计划内口径冲突：non-goal 还没同步放宽到 `verify-promote-runtime-inbox.ps1`。

### Evidence / Commands

- `Get-Content docs/tasks/shared-memory-v2-optimization/plan.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/plan-review.md`
- 带行号检查：
  - `plan.md`
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
- `tests/verify-promote-runtime-inbox.ps1`
- `tests/verify-repair-shared-memory.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`

## Run 5

Verdict: `pass`

### Findings

`no findings`

### Closure Summary

- 上一轮唯一剩余的不一致点已闭合：`plan.md:43` 的 non-goal 现在已明确允许更新 `verify-promote-runtime-inbox.ps1`，与 `affected_paths`（`plan.md:122`）和 TODO 15 的显式合同锁（`plan.md:234`）一致。
- scoped focus 内的 writer / test contract 现在是自洽的：
  - `promote-runtime-inbox.ps1` 已明确进 scope，且要求 `New-TaskRuntimeDocument` 写出 `entry_host:`：`plan.md:119`, `plan.md:226-229`
  - `repair-shared-memory.ps1` 已明确要求 repair-side 自动补建的 `运行时/tasks/<task-id>.md` 也写出 `entry_host:`：`plan.md:120`, `plan.md:217-220`
  - `verify-promote-runtime-inbox.ps1` 与 repair-side task-runtime assertions 都已被要求锁住这条最小合同：`plan.md:232-235`
- 在本轮 scoped review 范围内，没有剩余阻断项；计划可以进入 `IMPLEMENT`。

### Evidence / Commands

- `Get-Content docs/tasks/shared-memory-v2-optimization/plan.md`
- `Get-Content docs/tasks/shared-memory-v2-optimization/plan-review.md`
- 带行号检查：
  - `plan.md`
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
  - `tests/verify-promote-runtime-inbox.ps1`
  - `tests/verify-repair-shared-memory.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`
