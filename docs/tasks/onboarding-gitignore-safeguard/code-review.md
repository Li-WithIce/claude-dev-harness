# Onboarding `.gitignore` Safeguard Code Review

## Verdict

- **revise** — 主实现 4 条合同（幂等补齐、不重复、不覆盖既有规则、保留换行风格）在代码层面都成立，但回归只锁住了"管理条目幂等恢复"这一条；"保留用户既有规则"和"保留 LF-only 换行风格"两条合同没有被任何入库测试锁住，未来若被静默打破不会被 CI 捕获。

## Findings

### P2 - "不覆盖现有 `.gitignore` 其他规则" 没有被回归锁住

- `install.ps1:216-271` 的 `Ensure-WorkspaceGitIgnoreEntries` 是 append-only：`existingContent.TrimEnd([char[]]@("`r", "`n"))` 只剥末尾空白，再用 `$trimmedExisting + $newline + $newline + ($appendedLines -join $newline) + $newline` 拼回；正文从未被改写。这一行为在当前代码里是正确的。
- 但 `tests/verify-update-managed-assets.ps1:301-317` 的回归 fixture 只对 4 条 managed entry 之一（`GEMINI.md`）做删除-恢复验证；mutator 从不预置任何用户自有规则（如 `node_modules/`、`*.log`），PostAssert 也只断言 4 条 managed entry 各出现 1 次。
- 结果：如果未来 `Ensure-WorkspaceGitIgnoreEntries` 被改成"重写整个文件"或"按白名单过滤"，只要 4 条 managed entry 还在，当前回归仍会全绿。Leader 在 confirmation point (2) 明确要求"不覆盖现有 `.gitignore` 其他规则"，这条合同今天没有测试唯一锁住。
- 建议：在 `verify-update-managed-assets.ps1` 增加一个 case，在 install 之后由 mutator 预置一条 sentinel 规则（例：`# user-custom\nnode_modules/\n*.log\n`），跑完 `update-managed-assets.ps1` 后断言这些行仍按原顺序原样存在。

### P2 - "保留原换行风格" 没有被回归锁住

- `install.ps1:198-214` 的 `Get-ExistingNewlineStyle` 实现是对的：`Contains("`r`n")` 优先于 `Contains("`n")`，否则回退到 `"`r`n"`；后续 append 完全使用这个 newline 变量。
- 但当前两个 verify 脚本的断言（`verify-installation.ps1:148`、`verify-update-managed-assets.ps1:77`）都用 `[regex]::Split($content, '\r?\n')` 把 LF 和 CRLF 一视同仁地分行；fixture 也从不显式构造 LF-only 的 workspace `.gitignore`。
- 结果：如果未来有人把 append 端硬编码成 `"`r`n"`（或反过来），LF-only workspace 的 `.gitignore` 会被悄悄混入 CRLF，而当前回归仍可能继续全绿。Leader 在 confirmation point (3) 明确要求"保留原换行风格"，这条合同今天没有测试唯一锁住。
- 建议：在 `verify-update-managed-assets.ps1` 增加一个 case，让 mutator 把 install 后产物 normalize 成 LF-only（例如先删 `GEMINI.md` 行再 `[regex]::Replace($content, '\r\n', "`n")`），跑完 update 后用字节级断言（`-not $rawBytes -contains 0x0D` 之类）验证文件仍是 LF-only。

### P3 - 受管 comment 标记"至多 1 次"未被显式锁住

- `install.ps1:251` 用 `if (-not $normalizedLines.Contains($managedComment))` 决定是否前置 `# claude-dev-harness workspace artifacts`。这里走的是 trimmed-line HashSet（OrdinalIgnoreCase），在当前文本里能保证 comment 至多 1 次。
- 但 `Assert-GitIgnoreManagedEntries` 与 `Assert-GitIgnoreEntriesExactlyOnce` 都只断言 4 条 entry 各 1 次，不断言 managed comment 行也只 1 次；现有 `workspace-gitignore-managed-entries-are-idempotent` fixture 因为只删 `GEMINI.md` 这一条 entry 行、不动 comment 行，是"顺带"过的，并非显式锁定。
- 不是 blocker（当前行为正确），但建议把"managed comment 行存在且仅存在 1 次"也加进同一组断言，与 4 条 entry 平级，避免后续重构 `appendedLines` 拼接时悄悄出现重复 comment。

## Open Questions / Assumptions

- 无。评审按 Leader 指定的"安装链路 `.gitignore` 自动保护"surface 执行；工作区里其他脏文件（`docs/tasks/...` 等）视为既有背景噪音，不作为本轮 scope drift finding。
- 已现场确认：`scripts/update-managed-assets.ps1:179-183` 通过直接调用 `install.ps1` 复用 `Ensure-WorkspaceGitIgnoreEntries`（line 1220），不存在"update 路径绕过 guard"的风险，confirmation point (1) 在路径覆盖层面成立。

## Change Summary

- 主实现面与本次 surface 合同一致：
  - 幂等：HashSet (OrdinalIgnoreCase) 计算 missing；`if ($missingEntries.Count -eq 0) { return }` 提前出口，连 `Backup-IfNeeded` 都不调用。
  - 不重复：依赖 HashSet + early-return；`workspace-gitignore-managed-entries-are-idempotent` 已锁住"删除-恢复"路径不会出现 N>1。
  - 不覆盖：append-only，`TrimEnd` 只剥末尾换行而不改写正文。
  - 保留换行：`Get-ExistingNewlineStyle` 三段优先级正确。
  - 缺失文件：`Read-FileUtf8` 返回 `null` 时分支正确，会写出"managed comment + 4 条 entry"的全新文件。
- 本轮 blocker 不在实现结果本身，而在 confirmation point (4) 的回归覆盖：当前回归只锁住了"幂等"这一条，"不覆盖用户规则"和"保留 LF-only"两条今天靠人工 review 通过，未来易回归静默打破。

## Evidence

- `Read install.ps1` 第 188-271 行（`Read-FileUtf8` / `Get-ExistingNewlineStyle` / `Ensure-WorkspaceGitIgnoreEntries`）
- `Read install.ps1` 第 1209-1220 行（主 try 块中的 guard 调用点）
- `Read scripts/update-managed-assets.ps1` 第 178-200 行（`Invoke-Step` 直接调起 `install.ps1`，不绕过 guard）
- `Read tests/verify-installation.ps1` 第 134-159 行（`Assert-GitIgnoreManagedEntries`）+ 第 387 行（调用点）
- `Read tests/verify-update-managed-assets.ps1` 第 68-85 行（`Assert-GitIgnoreEntriesExactlyOnce`）+ 第 301-317 行（`workspace-gitignore-managed-entries-are-idempotent` fixture）
- `Grep "Ensure-WorkspaceGitIgnoreEntries"` —— 仅 `install.ps1` 命中，确认 `scripts/` 不存在重复实现
- `Grep "gitignore" path=scripts/` —— 0 命中，确认 update 路径只通过调起 install.ps1 复用 guard
