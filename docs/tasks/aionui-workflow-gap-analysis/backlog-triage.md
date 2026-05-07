---
task_id: 8c8a1e5f
review_type: backlog-triage
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: read-only-triage
---

# AionUi 对齐 Backlog Triage

## 范围

只对 team_task_list 中归属 AionUi 对齐主线的旧 pending 任务做 read-only 分诊（continue / pause / retire），并尽量把 retire 项映射到落地 commit 或替代机制。不实现、不开新任务。范围**不包含**与对齐主线无关的独立任务（294bf604 / 68bd1fbf / 85ff35b0 / onboarding 系列 / README & superpowers doc sync），它们由各自优先级处理。

依据：`docs/tasks/aionui-workflow-gap-analysis/analysis.md` + git log + `agent-configs/` / `skills/workflow-team/` / shared-memory v2 实际产物。

## TL;DR

AionUi 对齐主线已经事实上完成 — Phase 0-7 + shared-memory v2 全部 commit 落地。team_task_list 上挂着的约 **80 条** 对齐相关 pending 任务，全部可 retire（每条都有对应 commit 或落地产物）。**无需保留任何 continue 项**；G5（SKILL schema 形式化）与 G6（live MCP smoke）作为可选观察项 pause，不要写成必须实施。

最小可行下一步：批量把下表 retire 任务 status 置 `deleted` 或 `completed`；继续保留只会让 backlog 优先级失真。

## Retire 列表（按主题归并）

### 主题 A — 入口对齐（Phase 0）

| task_id | 主题 | 落地证据 |
|---|---|---|
| ee7aec19 | Map implementation surfaces | 已被 architecture.md gap matrix + 各 phase validation 覆盖 |
| 63c847d5 | Establish validation baseline | 各 phase validation 文件均 PASS（架构文档内追踪） |

### 主题 B — Phase 1 Tool Profile

| task_id | 主题 | 落地证据 |
|---|---|---|
| 82158830 / 3b9eefb8 / 91f1bb06 / 6574ad3a / 46ea425b | Phase 1 实现 / 评审 / 修复 / 验证 | `agent-configs/profiles/harness-default-{claude,codex,gemini}.yaml`；commit `309f0ee` |

### 主题 C — Phase 2 Workflow Descriptor

| task_id | 主题 | 落地证据 |
|---|---|---|
| ba772278 / 2ef144ce / aff33d63 / 503e27ac / 0e25f119 / be491e1b / 9ab1c528 / e63e4b5b / 529cf558 / a075e78b / c2ea27dd / 20517bec / bff6d431 | Phase 2 plan / review / impl / fix / validate | `agent-configs/workflows/harness-lite.yaml`；commit `309f0ee` |

### 主题 D — Phase 3 ACP Skill Alignment

| task_id | 主题 | 落地证据 |
|---|---|---|
| 01de7ea4 / 22ba462e / fdd81c39 / 6bdace85 / 1dcaf6ac / 586f3271 / bf693e06 / ee7123d6 / 61001a61 / 18b38522 | Phase 3 plan / review / impl / fix / validate | `skill-manifest.json` 生成路径；commit `309f0ee` |

### 主题 E — Phase 4 Team Preset Bridge

| task_id | 主题 | 落地证据 |
|---|---|---|
| 4872d1e3 / 33d8c263 / bbf34357 / 4ca292ce / 5332c3f2 / dc4ffe10 / b993e575 / 0cd2a8a9 / ff2eaea9 | Phase 4 plan / review / impl / fix / validate / commit | `skills/workflow-team/scripts/spawn-team.ps1`；commit `309f0ee` |

### 主题 F — Shared Memory v2

| task_id | 主题 | 落地证据 |
|---|---|---|
| bfa71235 / 843d0d42 / cbd2101c / 9e82d1a8 / b3feabd8 / c68f7c6a / d6adad25 / 1b3848c6 / 954e3ddf / d7a6cf13 / 0b24503a / 0fcc500b / 1f4b50e7 | shared memory v2 plan / review / impl / fix / validate | commit `d1bae21` |
| 62026153 / 0285a51b / f5b52d0a / 41129c85 / 4abf4a2b / 6400f8a4 / aa5e15e3 | live vault migration plan / review / impl / validate / commit | commit `d1bae21`（live vault 已迁移） |

### 主题 G — Phase 5/6/7 Roadmap & 实现

| task_id | 主题 | 落地证据 |
|---|---|---|
| 791a69a6 / a59e5c01 / 93a94453 / e6136b8f / 4e582266 | 上游架构 analysis + roadmap drafting | 已被 architecture.md + 实际 commit 取代 |
| 0615728a / 70ae76cd / dc3dbd16 / 1e053f86 / 95dbfd97 / e6692b64 / 737f1c6e | Phase 5 plan / review / impl / validate | commit `ed66eb9` |
| ad7fb79a / 6277d8ee / 6213f9b5 / 50b6c51a / 6ba5befc / c74353ed / cfbf0f80 / 622ef199 | Phase 6 plan / review / impl / validate | commit `ed66eb9` |
| 5fe553ee / 61377415 / 73668806 / cc1bc1e1 / aa0c24c0 / 210c443c / df94680e / 07e621a2 / 938c9aa3 / e8619ce1 | Phase 7 plan / review / impl / validate / commit | commit `d1251bc` |

合计 retire ≈ **80 条**对齐主线任务。每条都有对应 commit 或落地文件路径作为替代物。

## Pause 列表（保留为可选观察项，不立任务）

| 项 | 出处 | 触发条件 |
|---|---|---|
| **G5 — SKILL.md inputs/outputs schema 形式化** | gap-analysis.md G5 | 出现真实 cross-backend 字段漂移证据时再开任务 |
| **G6 — Live AionUi end-to-end team smoke test** | gap-analysis.md G6 / architecture.md R-MCP | 真实多 backend 协作场景出现行为不一致时再开任务 |

**重要**：这两项当前不构成阻塞，**不要立 pending task**，避免被误读为必须实施。如未来出现触发条件，再单独开新任务。

## Continue 列表（AionUi 对齐主线）

**无。**

当前对齐主线的所有原计划工作均已 commit 落地，没有需要继续的实现项。

## 范围外说明（仅 reference，不在本次 triage 范围）

下列 pending 任务是与 AionUi 对齐**无关**的独立项，本 triage 不分诊，由各自优先级处理：

- 独立调查/修复：`294bf604`（verify-update-managed-assets）、`605dac8a` / `baa7c80a`（update-managed-assets test hardening）、`68bd1fbf`（sandbox_mode writeback）、`85ff35b0`（codex startup smoke）
- 文档刷新：`d9939f42` / `5d34f907` / `dae9c1cf` / `25f0b286` / `0a04db97` / `5dde0ee7`
- Goldwind workspace onboarding：`d70d1923` / `d6ff946c` / `9dc3ccc2` / `6d25d8ca` / `be014d83` / `bb0a8484` / `5bbd7777` / `19ce2fab` / `a32b19a6` / `8e4e0355`
- CodeStable 借鉴主线（已大量 commit，但仍挂 pending — 应另行做一次 CodeStable 主线 triage，非本任务范围）：`702f70ab` 起约 25 条任务

## 结论

AionUi 对齐主线**没有真正的 continue 项**。pending board 上 ~80 条对齐任务都可 retire（commit 已映射）。G5 / G6 仅作为观察项，不立任务。下一步只是 board 清扫操作（status 置 `deleted` 或 `completed`），不是新工作。

继续保留这些 retire 项会让 backlog 看起来仍有大量 AionUi 对齐工作待做，从而误导优先级判断 — 这是当前 backlog 噪音的主要来源。
