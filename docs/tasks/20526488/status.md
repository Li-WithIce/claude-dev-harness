# 20526488 Status

## Summary

修复 `6f2fb308` 复审指出的 blocking 点：入口与 host 模板中的 Lazy loading 摘要现在都明确包含 `ask` 语义，并对 Claude host 模板给出兼容边界。

## Changes

- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
- `agent-configs/codex/AGENTS.md.template`
- `agent-configs/workspace/AGENTS.md.template`
- `agent-configs/claude/CLAUDE.md.template`
- `tests/verify-lite-footprint.ps1`
- `docs/tasks/20526488/status.md`

## Rules

- `ask` 不加载 workflow skill，只问一个最小澄清问题。
- Claude 是显式兼容 host；仍先调用 `/using-superpowers`，但后续读取面跟随工作区入口懒加载路由。
- 本轮不做 `using-superpowers` rename，不做 Gemini 兼容面删除或迁移。

## Verification

- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` -> PASS
- `git diff --check` -> PASS

## Residual Risk

- 仅做文档/协议与测试锁点收口；没有新增执行器或 runtime enforcement。
