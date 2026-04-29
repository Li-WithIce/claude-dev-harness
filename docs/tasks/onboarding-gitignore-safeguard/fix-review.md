# Onboarding `.gitignore` Safeguard Fix Review

## Verdict

- **pass** — no findings。实现方这轮窄修已把上一轮 review 提出的 3 个缺口都显式锁进测试。

## Findings

- No findings.

## Scope Check

1. 既有 sentinel 规则不会被覆盖，也不会丢顺序：
   - `tests/verify-update-managed-assets.ps1:375-392` 新增 `workspace-gitignore-preserves-user-sentinel-rules` case，先注入 `# user sentinel` / `node_modules/` / `*.log`，再跑 managed update。
   - `tests/verify-update-managed-assets.ps1:68-93` 的 `Assert-GitIgnoreEntriesExactlyOnce` 显式锁住这些 sentinel 行仍各出现 1 次。
   - `tests/verify-update-managed-assets.ps1:96-125` 的 `Assert-GitIgnoreOrderedEntries` 再锁住 sentinel 序列仍位于 managed block 之前，顺序不丢。

2. LF-only `.gitignore` 经过 update/install 后仍保持 LF-only：
   - `tests/verify-update-managed-assets.ps1:396-412` 新增 `workspace-gitignore-preserves-lf-only-newlines` case，先把 `.gitignore` 归一成 LF-only，再删掉 `GEMINI.md`，随后跑 managed update。
   - `tests/verify-update-managed-assets.ps1:128-139` 的 `Assert-GitIgnoreLfOnly` 做字节级断言，明确禁止回写 CR (`0x0D`)。
   - 该路径最终复用的仍是 `install.ps1` 里的 `.gitignore` 保护逻辑：`scripts/update-managed-assets.ps1:179-194` 调 `install.ps1`，而实际 newline 保留逻辑在 `install.ps1:198-271`。

3. 受管 comment 行已被显式锁成 exactly once：
   - `tests/verify-update-managed-assets.ps1:68-93` 已把 `# claude-dev-harness workspace artifacts` 纳入默认 exact-once 断言集合。
   - `tests/verify-installation.ps1:134-159` 也把同一 comment 纳入 fresh install 的 exact-once 校验，并在 `tests/verify-installation.ps1:387` 调用。

## Validation

- 已复跑 fresh install + `tests/verify-installation.ps1`：`STATUS: PASS`。
- 已复跑 `tests/verify-update-managed-assets.ps1`：`PASS`。其中既有旧 case（`workflow-protocol-drift-is-repaired`、`cwd-autodetect-pass`、`decision-needed-template-drift-is-repaired`）与本轮新增的 3 个 `.gitignore` 回归 case 均通过，因此本轮 fix 的回归覆盖已经落在实际可执行的 green path 上。

## Evidence

- `tests/verify-update-managed-assets.ps1:68`
- `tests/verify-update-managed-assets.ps1:96`
- `tests/verify-update-managed-assets.ps1:128`
- `tests/verify-update-managed-assets.ps1:357`
- `tests/verify-update-managed-assets.ps1:375`
- `tests/verify-update-managed-assets.ps1:396`
- `tests/verify-installation.ps1:134`
- `tests/verify-installation.ps1:358`
- `tests/verify-installation.ps1:387`
- `scripts/update-managed-assets.ps1:179`
- `scripts/update-managed-assets.ps1:194`
- `install.ps1:198`
- `install.ps1:216`
