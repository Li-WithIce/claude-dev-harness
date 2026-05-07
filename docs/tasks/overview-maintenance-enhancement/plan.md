---
task_id: overview-maintenance-enhancement
stage: IMPLEMENT
tool: claudecode
updated: 2026-04-10
---
# getOverview 接口检修统计补充开发

## Clarification

- 验收标准:
  1. `getOverview` 接口返回的每个工序、每条产线新增 `maintenanceCount` 字段
  2. `maintenanceCount` = 已完成的月度维修计划数（`master_process_monthly_maintenance` 中 `end_date <= 当前日期`）+ 已完成的临时检修数（`master_process_maintenance_plan` 中 `maintenance_create_type = '1'` 且 `current_status = '2'`）
  3. 统计范围按请求参数 `year` 过滤
  4. 现有 `maintenanceHours` 等字段保持不变，新增字段为补充统计

- 非目标:
  - 不改动现有运行时长/维修时长计算逻辑
  - 不改动前端（仅后端 API 补充字段）
  - 不涉及日历、运行监控、运行曲线等其他接口

- 受影响目录:
  - `src/main/java/com/goldwind/ipark/base/masterbasic/vo/ProcessOverviewVO.java`
  - `src/main/java/com/goldwind/ipark/base/masterbasic/vo/ProcessOverviewLineVO.java`
  - `src/main/java/com/goldwind/ipark/base/masterbasic/service/impl/MasterProcessScheduleActualServiceImpl.java`

- 回滚策略: 纯新增字段，删除代码即可回滚，无数据库变更
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan

- `ProcessOverviewVO.java` 新增 `totalMaintenanceCount` 字段（工序年度检修次数）
- `ProcessOverviewLineVO.java` 新增 `maintenanceCount` 字段（产线检修次数）
- `MasterProcessScheduleActualServiceImpl.java` 注入 `MasterProcessMonthlyMaintenanceMapper`
- `queryOverview()` 方法在月度计划聚合之后、构建结果前，新增两段查询：
  - 查询 `master_process_monthly_maintenance`（`end_date <= now`, 年份匹配），按 `product_line_id` 聚合 COUNT
  - 查询 `master_process_maintenance_plan`（`maintenance_create_type='1'`, `current_status='2'`, 年份匹配），按 `product_line_id + process_id` 聚合 COUNT
- 月度维修无 processId，按 productLineId 统计后平铺到该产线下所有工序
- 产线 `maintenanceCount` = 月度维修 count + 临时检修 count
- 工序 `totalMaintenanceCount` = 各产线 `maintenanceCount` 之和
- 无数据时字段返回 "0"

## Verification

- `mvn compile -pl . -q` 编译通过
- `curl` 调用 `getOverview?year=2026` 返回结果包含 `totalMaintenanceCount` / `maintenanceCount`
- 月度维修表有已结束记录时，对应产线 count > 0
- 临时检修表有已完成记录时，对应产线+工序 count > 0
- 无数据时字段返回 "0"

## Risks

- `selectMaps` 返回的 column alias 在不同 MySQL 版本中大小写可能不一致，需注意 key 提取时兼容处理
- 月度维修无 processId，同一产线的检修次数会在该产线所有工序下重复计入——这是设计意图（月度维修是产线级停机），如需去重需另行讨论

## Plan Review

### Run 1 · 2026-04-10 17:02 · runner: claudecode
- verdict: pass
- findings:
  - P2: `selectMaps` 的 column alias 大小写兼容已在 Risks 中说明，实现时需统一用小写 key 或 `toString()` 提取
  - P3: `LineAggregate` 内部类需补一个 `maintenanceCount` 字段用于累加，计划未明确但可从上下文推导
- next: none

## Implementation Notes

## Code Review
