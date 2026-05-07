---
task_id: eo-lite-enhancement
stage: DONE
tool: none
updated: 2026-04-24
---
# EO-Inspired Harness Lite 增强（Change Contract + Handoff 密度）

## Clarification
- 验收标准:
  - `plan.md` 模板支持可选 `## Change Contract` section，字段为 `change_type`（枚举 `task|feature|enhance|refactor`）+ `affected_paths`（至少一条）
  - `test.md` 模板的 `## Handoff` 支持新增 3 个字段：`current_state`、`key_decisions`（每条含 `decision` + `why`）、`next_actions`
  - `validate-lite-artifacts.ps1` 对存在 `## Change Contract` 的 plan.md 执行 opt-in 枚举校验；缺少 section 时跳过
  - 新增 `tests/verify-change-contract.ps1`：2 正例 + 2 反例
  - 现有 16 个 verify 测试继续通过
  - 老 plan.md（无 Change Contract）和老 test.md（只有 delivery/follow_up 的 Handoff）保持兼容
- 非目标:
  - 不引入 `docs/modules/<module>/spec.md` 活文档层
  - 不实现 Delta archive 脚本
  - 不新增 `change_type: bootstrap` 枚举
  - 不新增 stage、不改 `advance-stage.ps1`
  - 不新增 skill 目录
  - 不做 INDEX / doc-sync 能力
- 受影响目录:
  - `skills/plan/SKILL.md`
  - `skills/test/SKILL.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
  - `skills/orchestrator/references/state-templates.md`
  - `scripts/validate-lite-artifacts.ps1`
  - `tests/verify-change-contract.ps1`（新增）
- 回滚策略:
  - 所有字段 opt-in；未使用的旧任务无感
  - 如发现 validator 误报，回滚 `validate-lite-artifacts.ps1` 的枚举块即可恢复旧行为
  - 不需要迁移已有 plan.md / test.md
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- TODO 1: 更新 `skills/orchestrator/references/lite-writing-guide.md`，在 "plan.md 契约" 增补 `## Change Contract` 可选 section 的字段定义与枚举；在 "test.md 契约" 扩展 `## Handoff` 示例与字段说明，并注明旧格式兼容
- TODO 2: 更新 `skills/orchestrator/references/state-templates.md`，同步 plan.md 和 test.md 两个模板的新可选字段
- TODO 3: 更新 `skills/plan/SKILL.md`，在骨架示例中加入注释性的可选 `## Change Contract` 块（标注 optional）
- TODO 4: 更新 `skills/test/SKILL.md`，把扩展后的 Handoff 模板作为推荐示例，并说明旧格式兼容
- TODO 5: 修改 `scripts/validate-lite-artifacts.ps1`，新增 Change Contract 校验逻辑：
  - 若 plan.md 含 `## Change Contract`，检查 `change_type` 值在枚举 `task|feature|enhance|refactor` 内
  - 若 plan.md 含 `## Change Contract`，检查 `affected_paths` 至少一条非空
  - 若 plan.md 不含该 section，跳过校验（opt-in）
- TODO 6: 新增 `tests/verify-change-contract.ps1`：
  - 正例 1：含合法 Change Contract 的 plan.md → validator 通过
  - 正例 2：不含 Change Contract 的 plan.md → validator 通过
  - 反例 1：`change_type: bootstrap`（非法枚举）→ validator 失败
  - 反例 2：`affected_paths` 为空 → validator 失败
- TODO 7: 本地运行全量回归：`verify-change-contract.ps1` + `verify-lite-artifact-validator.ps1` + `verify-workflow-contracts.ps1` + `verify-lite-footprint.ps1`

## Verification
- `pwsh -File tests/verify-change-contract.ps1`
- `pwsh -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -File tests/verify-workflow-contracts.ps1`
- `pwsh -File tests/verify-lite-footprint.ps1`

## Risks
- validator 新增正则匹配可能与既有 plan.md 的自由文本冲突：通过只在存在 `## Change Contract` section 时才触发校验来规避
- test.md 的 Handoff 字段扩展可能影响 `verify-lite-artifact-validator.ps1` 的现有断言：实施时需先跑一遍该测试基线，再决定是否需要调整断言
- `skills/test/SKILL.md` 与 `lite-writing-guide.md` 的示例可能出现不一致：以 `lite-writing-guide.md` 为单一真相源，其他文件引用它

## Plan Review

### Run 1 · 2026-04-23 16:30 · runner: Claude
- verdict: pass
- findings:
  - P2: TODO 5 未明确 `## Change Contract` section 的解析策略。plan.md 示例用 bullet 格式（`- change_type: ...` / `- affected_paths:` + 嵌套 `  - <path>`），validator 需要：(a) 定位 `## Change Contract` section；(b) 匹配 `^- change_type:\s*(task|feature|enhance|refactor)\s*$`；(c) 匹配 `^- affected_paths:\s*$` 后跟至少一条 `^\s{2,}- \S+` 条目。IMPLEMENT 时需参照现有 `Assert-PlanContract` 的 section 解析模式（`Get-SectionContent` + 正则），保持与既有实现风格一致。
  - P2: TODO 6 的 verify-change-contract.ps1 未说明 fixture 策略。现有 `verify-lite-artifact-validator.ps1` 等测试使用临时 task 目录 + 调 `scripts/validate-lite-artifacts.ps1`。新测试应沿用该模式，避免引入新的 fixture 机制。IMPLEMENT 时先读该脚本再开工。
  - P2: TODO 1 提到"旧格式兼容"的注记，但验收标准第 6 条已覆盖该语义。为避免 `lite-writing-guide.md` 与 `skills/test/SKILL.md` 示例漂移，IMPLEMENT 时以 lite-writing-guide.md 为单一真相源，test/SKILL.md 只引用不复制完整模板。
  - P3: `affected_paths` 的"至少一条"需明确定义。建议 validator 将 `<path>`、空字符串、只含空白的条目都判失败。IMPLEMENT 时在 verify-change-contract.ps1 反例中覆盖"占位符 `<path>`"这一 edge case。
- next: 进入 IMPLEMENT，按 P2/P3 findings 在实现时细化；无需回修 plan。

## Implementation Notes

### Run 1 · 2026-04-23 17:00 · runner: Claude
- changed:
  - `skills/orchestrator/references/lite-writing-guide.md`: 新增"可选 section：Change Contract"小节（字段定义 + 枚举 + opt-in 规则）；`## test.md 契约` 的 Handoff 示例新增 `current_state` / `key_decisions` / `next_actions` 三字段并注明 opt-in，`delivery` 与 `follow_up` 仍为最低必填。
  - `skills/orchestrator/references/state-templates.md`: plan.md skeleton 在 `## User Confirmation` 与 `## Plan` 之间插入可选 `## Change Contract`；test.md skeleton Handoff 补三个可选字段。
  - `skills/plan/SKILL.md`: 骨架示例加入可选 Change Contract 块，并新增"可选 Change Contract"小节引用 lite-writing-guide。
  - `skills/test/SKILL.md`: 最小模板 Handoff 补三个可选字段，并注明以 lite-writing-guide.md 为单一真相源。
  - `scripts/validate-lite-artifacts.ps1`: 新增 `$script:OptionalPlanSections` 和 `$script:AllowedChangeTypes`；`Assert-PlanContract` 先把 `Change Contract` 从顺序检查中剥离再比较必备 section；新增 `Assert-ChangeContract` 函数，校验 `change_type` 枚举和 `affected_paths` 至少一条非占位 `<path>` 条目。
  - `tests/verify-change-contract.ps1`（新增）：2 正例（合法契约通过 / 无契约 opt-in 跳过）+ 2 反例（`change_type: bootstrap` 被拒 / `affected_paths` 只含 `<path>` 占位符被拒），fixture 沿用 `verify-lite-artifact-validator.ps1` 的临时 task 目录 + UTF-8 BOM 模式。
- tests:
  - `pwsh -File tests/verify-change-contract.ps1` → 4 checks pass
  - `pwsh -File tests/verify-lite-artifact-validator.ps1` → 7 checks pass
  - `pwsh -File tests/verify-workflow-contracts.ps1` → 12 checks pass
  - `pwsh -File tests/verify-lite-footprint.ps1` → no errors（含 `tests/verify-change-contract.ps1 uses UTF-8 BOM` 命中）
  - 全仓 17 个 verify 脚本逐个执行：16 通过；`verify-installation.ps1` 需要 `-WorkspaceRoot` 强制参数，非本 task regression。
- risks:
  - Plan Review P2 finding 1（Change Contract 解析策略）：已按现有 `Assert-PlanContract` 风格实现，正则锚定 `^-\s*change_type:` 与 `^\s{2,}-\s+<path>`，允许 affected_paths 条目缩进 >= 2。
  - Plan Review P2 finding 2（沿用 fixture 模式）：新测试直接复用 verify-lite-artifact-validator 的 fixture 模式，零新机制。
  - Plan Review P2 finding 3（单一真相源）：lite-writing-guide.md 仍是契约源，SKILL.md 只引用。
  - Plan Review P3（占位 `<path>` 判失败）：在 `Assert-ChangeContract` 中过滤 `-ne '<path>'` 并通过 verify-change-contract.ps1 反例 2 覆盖。
- next: CODE_REVIEW 复核 `Assert-ChangeContract` 正则健壮性、fixture 兼容性，以及 lite-writing-guide.md / SKILL.md 文字与 validator 行为的一致性。

### Run 2 · 2026-04-23 18:45 · runner: Codex
- changed:
  - `scripts/validate-lite-artifacts.ps1`: `Assert-ChangeContract` 改为只解析 `- affected_paths:` 字段块内部的缩进列表，遇到下一个顶层 `- 字段:` 即停止，避免把 `notes` 等其他字段的嵌套 bullet 误算成路径；`Assert-PlanContract` 新增 `Change Contract` 单例与位置校验，要求它只能位于 `## User Confirmation` 与 `## Plan` 之间。
  - `tests/verify-change-contract.ps1`: 夹具生成器新增可配置的 Change Contract 插入位置，并补上 2 个反例：空 `affected_paths` + 其他字段嵌套 bullet、以及 `Change Contract` section 错置到 `## Code Review` 之后。
  - `tests/verify-change-contract.ps1`、`tests/verify-lite-artifact-validator.ps1`、`tests/verify-workflow-contracts.ps1`: 清理临时任务目录时增加重试并降级为 warning，避免 finally 阶段的 Windows 文件句柄占用把断言通过的回归误判为失败。
- tests:
  - `pwsh -File tests/verify-change-contract.ps1` → 6 checks pass，0 failures（cleanup 仅 warning）
  - `pwsh -File tests/verify-lite-artifact-validator.ps1` → 7 checks pass，0 failures（cleanup 仅 warning）
  - `pwsh -File tests/verify-workflow-contracts.ps1` → 12 checks pass，0 failures（cleanup 仅 warning）
  - `pwsh -File tests/verify-lite-footprint.ps1` → STATUS: PASS
- risks:
  - cleanup warning 仍会暴露底层文件句柄释放偏慢的问题；当前已不再影响回归结果判定，但后续若要保持 `docs/tasks` 干净，仍值得单独追查 `powershell.exe` 子进程的占用来源。
  - `Change Contract` 解析仍假设顶层字段使用 `- key:` 语法，这与当前 lite 写作契约一致；若未来扩展 section 语法，需要同步更新 validator。
- next: 回 CODE_REVIEW 复核 `affected_paths` 字段块限界、`Change Contract` 位置 gate，以及 cleanup warning 是否接受或需另开后续任务。

## Code Review

### Run 1 · 2026-04-23 18:00 · runner: Codex
- verdict: revise
- findings:
  - P1: `scripts/validate-lite-artifacts.ps1:363-370` 的 `affected_paths` 校验抓取整个 `## Change Contract` section 内任意缩进列表项，而非只抓 `- affected_paths:` 之后的条目。最小复现 dataset `review-probe-note3`（Change Contract 含 `- notes:` 下缩进 bullet + 空 `- affected_paths:`）跑 validator 得到 `STATUS: PASS`，绕过核心契约。修复方向：把解析范围收窄到 `- affected_paths:` 行之后、下一个 `- 字段:` 之前的区块。
  - P2: `scripts/validate-lite-artifacts.ps1:437-442` 的 `Assert-PlanContract` 先把 `Change Contract` 从 section 列表中整体过滤再比较顺序，因此 `## Change Contract` 放错位置（例如在 `## Code Review` 后）也会通过。最小复现 dataset `review-probe-order2` 验证 `STATUS: PASS`。修复方向：显式校验 `## Change Contract` 只能位于 `## User Confirmation` 与 `## Plan` 之间。
- evidence:
  - 最小复现 dataset `review-probe-note3`（P1）→ validator STATUS: PASS（误通过）
  - 最小复现 dataset `review-probe-order2`（P2）→ validator STATUS: PASS（误通过）
  - 备注：`pwsh -File tests/verify-change-contract.ps1` 与 `pwsh -File tests/verify-lite-artifact-validator.ps1` 在 finally cleanup 阶段触发 `Access to the path ... is denied`，未作为通过证据。
- next: 回 IMPLEMENT，修复范围：
  1. 收窄 `Assert-ChangeContract` 中 `affected_paths` 的解析区间（仅限 `- affected_paths:` 字段块）
  2. `Assert-PlanContract` 显式校验 `Change Contract` 的 section 位置
  3. `tests/verify-change-contract.ps1` 增补反例 3（空 affected_paths + 其他嵌套 bullet）+ 反例 4（Change Contract 位置错置）

### Run 2 · 2026-04-24 08:47 · runner: Codex
- verdict: pass
- findings: none
- evidence:
  - `pwsh -File tests/verify-change-contract.ps1` → 6 checks pass，0 failures；反例 3（空 `affected_paths` + 其他字段嵌套 bullet）与反例 4（section 错置）均命中预期失败。
  - `pwsh -File tests/verify-lite-artifact-validator.ps1` → 7 checks pass，0 failures。
  - `pwsh -File tests/verify-workflow-contracts.ps1` → 12 checks pass，0 failures。
  - `pwsh -File tests/verify-lite-footprint.ps1` → `STATUS: PASS`。
  - 手工边界夹具复核：`review-case-affected-valid` → validator `STATUS: PASS`（`affected_paths` 为最后字段且有条目时通过）；`review-case-affected-empty` → validator `STATUS: FAIL`（`affected_paths` 为最后字段且无条目时拒绝）；`review-case-duplicate-change` → validator `STATUS: FAIL`（重复 `Change Contract` section 被拒绝）。
  - cleanup helper 复核：`tests/verify-change-contract.ps1`、`tests/verify-lite-artifact-validator.ps1`、`tests/verify-workflow-contracts.ps1` 的 `Remove-DirectoryWithRetry` 函数实现一致（SHA-256 相同），finally 块均切到该 helper；tracked diff 仅涉及 cleanup 路径，未改断言逻辑。
- next: 可推进到 TEST；若后续仍要追根 Windows 文件句柄释放偏慢，可另开 cleanup 专项任务。
