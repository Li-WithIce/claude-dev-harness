# 待澄清草稿规则：源码候选验证

日期：2026-11-03。任务：`continuity-clarification-draft-20261103`。

结论：本任务约定的源码规则、生成入口、说明及聚焦验证已完成。安装或部署不在本任务 Contract 范围内，工作台的已安装入口仍为旧版；真实宿主保存草稿的行为为 `not_run`。

## 用户依据与实现

用户在对话 `01a19f27-75d4-7981-b24a-7daefa8d5e5a` 于 2026-11-03 明确选择“允许保存待澄清草稿”。范围为已接入项目的改造请求：仅在既有变更记录中保存原话、已知来源日期和待确认问题，明确前不改代码、不创建机器任务状态。

- 规范源：`policies/entry-contract.md`。
- 生成入口：workspace、Claude 和保留的 vault 入口模板；Codex 用户级入口保持 host overlay。
- 说明：`docs/project-continuity.md`、`docs/requirement-gate.md`、`docs/architecture/entry-contract-policy-parity.md`。
- 当前有效的入口测试已更新；`verify-entry-routing-clarification.ps1` 经 `module-manifest-catalog.json` 确认为 archived v1 测试，保持原样，未运行且不计入通过数。
- Requirement 实现和数据库策略没有为草稿增加执行权限。草稿内容与位置的约束属于宿主入口文字，EC-08 标记为 `partially_enforced`，不声称机器已强制执行这项例外。

## 实际验证

工作目录：`D:\data\harness-integration-v2\work\maintenance-boundary`。下表为本轮实际命令输出的摘要；没有把未运行的安装或宿主验收计入结果。

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `pwsh -NoProfile -File tests\verify-codex-entry-autoload.ps1` | 0 | `Codex entry autoload and workspace routing templates verified.` |
| `pwsh -NoProfile -File tests\verify-v2-entry-contract.ps1` | 0 | `STATUS: PASS (56 checks)` |
| `pwsh -NoProfile -File tests\verify-v2-requirement-gate.ps1` | 0 | `STATUS: PASS (266 checks)` |
| `pwsh -NoProfile -File tests\verify-v2-readonly-zero-write.ps1` | 0 | `STATUS: PASS (10 checks)` |
| `pwsh -NoProfile -File tests\verify-v2-policy-contracts.ps1` | 0 | `STATUS: PASS (87 checks)` |
| `pwsh -NoProfile -File scripts\get-kernel-tcb-inventory.ps1 -Check` | 0 | `STATUS: PASS`，unresolved=0 |
| `pwsh -NoProfile -File scripts\get-module-manifest-catalog.ps1 -Check` | 0 | `STATUS: PASS`，modules=13，owners=92，unresolved=0 |
| `git diff --check` | 0 | 无空白错误 |

前一阶段入口测试曾因体积预算失败；已精简规范文案、重新生成入口并通过复验，未放宽原预算。上述本轮入口测试再次通过 56 项。

## Contract 覆盖

| 标准 | 本任务的证据与边界 |
| --- | --- |
| AC-1 | 规范源及三个生成模板明确限定 opted-in 项目的 pending clarification 草稿。入口一致性和删除关键条件的变异检查通过。此项是源码规则验证，实际宿主保存草稿尚未运行。 |
| AC-2 | 规范保留 Ask、其他写入阻断、受保护操作分流及只读零写。Requirement Gate、只读快照和策略检查通过；未修改 Runtime、Hook 或数据库执行权限。草稿范围仍由宿主遵循文字约定。 |
| AC-3 | 规范、生成模板、说明和当前有效测试一致；TCB 及模块目录检查通过。 |
| AC-4 | 本记录和方向计划均区分源码候选、已安装入口与真实宿主行为，明确安装和宿主测试为 `not_run`。 |

## 接续与保留

- 下一步是按正常更新流程交付入口，然后在真实需求中观察草稿范围；不得把这份源码 Evidence 当作已安装证明。
- 新对话读取 Obsidian、需求中途换对话、真实压缩恢复、每日及每周任务的首次实际运行仍未验收。其他项目和全部历史的整理与备份未完成。
- 方向计划：`docs/architecture/obsidian-continuity-plan.md`；工作台已在原改造记录追加本日检查点。
- 保留旧任务 `project-continuity-20261030`、shared pointer、既有已暂存文件及工作台业务改动。没有执行安装、Hook 修改、数据库写入、部署或服务启停。
- 本次源码、文档和任务资料为本地改动，尚未提交或推送。`docs/tasks/` 的新任务资料受现有 ignore 规则影响；文件存在不等于已有版本库或远端备份。
