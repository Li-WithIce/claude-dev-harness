# Task ID Rules

为避免多模型协作时生成不同 `task_id`，orchestrator 应优先使用稳定、可复现的命名规则。

## 规则

`task_id` 建议采用：

```text
<domain>-<topic>-<qualifier?>
```

例如：

- `auth-login-v2`
- `billing-refund-flow`
- `search-query-cache`

## 约束

- 使用小写字母、数字和连字符
- 不使用空格、下划线、中文或时间戳
- 尽量控制在 2 到 5 个词段
- 同一任务在整个生命周期内保持不变

## 生成顺序

1. 若用户显式给出 `task_id`，直接使用
2. 否则从任务主题生成稳定 slug
3. 若已有同任务 canonical 目录，复用已有 `task_id`
4. 若仍不确定，写入 `decision-needed.md`

## 禁止做法

- 每次恢复时重新生成一个新 `task_id`
- 把日期、随机串或模型名拼进 `task_id`
- 对同一任务同时使用多个近似 `task_id`
