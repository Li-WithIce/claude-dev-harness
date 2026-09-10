# Governed Plan

- task_id: thin-harness-v2-default-promotion
- contract_digest: sha256:912ccf5de9935865e847754821e83e73b8e311c3cf69b0e705cde9d4dc319aaf

## Goal

验证 `v2-public-optin-beta.1` 是否具备进入 Default Promotion 工程阶段的基础，形成证据可追溯、状态不夸大的资格 Gate Matrix，并把后续工作限制在 DP-02 至 DP-05。DP-01 结束后暂停任务，等待单独授权。

## Scope

- 只读审计 Model40、cognitive Host 3×3、installed Desktop Host 3×3、`v2/bare <= 1.25`、request-send reduction、Installed Desktop Gate、release-model/release-host/release-full、rollout report、Auto resolver、v1 rollback、Canary/Stable 和 qualification-only Desktop writer。
- 只运行协议配置、默认翻转、rollout 校验、release workflow routing、Host qualification contract、v1/v2 coexistence 与 v1 rollback 的快速确定性 Verifier。
- 每个 Gate 记录实现、测试、缺失证据、外部依赖、预计运行时间、是否阻塞默认翻转和唯一推荐批次；未运行项不写成 pass。
- 不修改源码，不运行真实 Model40、正式 cognitive/installed Host 3×3、release-full、Promotion、Auto Flip 或 Canary，不删除 v1，不 commit/push/建 PR。

## Implementation

1. 完成开发/稳定 Worktree 隔离预检，并核验稳定分支、稳定 Tag、HEAD、clean 状态和祖先关系。
2. 仅由稳定 `D:\data\dev-harness` 以 governed preset 管理本 Workspace；核验 Manifest、Registry、task shim 和用户级托管资产仍绑定稳定 RepoRoot。
3. 通过 Workspace shim 启用 v2，创建并激活唯一 Governed 任务；策略固定为 plan、rollback、independent review、verification required，approval false。
4. 从当前分支的 runner、schema、workflow、policy、文档和测试收集每个 Gate 的直接证据，形成完整 Gate Matrix。
5. 执行允许的聚焦 Verifier，记录命令、退出码和覆盖；丢失、未运行或外部不可用的结果保持 evidence-missing/environment-blocked。
6. 将真实缺口收敛为最多四个后续批次，生成本地 Evidence，完成独立只读审计后把任务暂停在 DP-01 边界。

## Verification

- `tests/verify-v2-protocol-config.ps1`：协议配置、workspace opt-in、Auto gating 与 `HARNESS_PROTOCOL=v1` stop-loss。
- `tests/verify-rollout-evidence.ps1`：Model40/Host 3×3 schema、阈值重算、rollout 输入与失败分类。
- `tests/verify-release-runner-boundary.ps1` 与 `tests/verify-release-validation.ps1`：release job 路由、runner/account 隔离、artifact 范围和 rollback smoke。
- `tests/verify-host-benchmark-qualification.ps1`：cognitive/installed qualification 合同，并确认 installed Desktop 仍保持 qualification-unavailable。
- `tests/verify-v1-v2-coexistence.ps1`：artifact-first 共存、v1 完整阶段链和 immediate rollback。
- 回读 Task State、Contract、Plan、Evidence、Audit 和两个 Git Worktree；要求无 pending transaction、无 tracked/staged/untracked 源码变化。

## Rollback

- DP-01 不产生源码变更，因此不使用 `git reset`、`clean`、`stash` 或分支修复；任何失败都保留原始证据并停止。
- 安装事务只允许由稳定 Harness 自带恢复机制处理，禁止手改 Registry、Hook、Adapter 或稳定仓库。
- workspace v2 偏好如需止损，只能在后续明确授权后通过同一 shim 执行 `disable-v2`；现有 v1/v2 task artifact 不迁移、不删除。
- Task/Plan/Evidence/Audit 均保持本地、Git ignored；DP-01 完成后保留并暂停任务，等待 DP-02 授权，不通过删除状态伪造回滚。
