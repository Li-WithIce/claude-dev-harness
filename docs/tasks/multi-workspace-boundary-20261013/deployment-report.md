# IoT 入口与会话多工作区部署结果

固定方案已按用户批准执行，部署状态为 `installed-and-registered-native-verified`。`D:\GVPP`、`D:\energy\base-service`、`D:\energy\base-front` 的正常安装、All-scope 校验和 v2 入口 protocol 均通过。指定 GVPP 会话的两个 IoT 根登记成功，已安装 K1 正负预检通过。真实桌面 Hook 加载及业务工具写入仍为 `NOT_VERIFIED`。

## 固定授权与候选

- task_id: `multi-workspace-boundary-20261013`；登记时 Task version `3`，Contract `sha256:9f572e778018fc32dfe71a0f12c2bcf336108ffde5e7aeda00837d2c10be151a`。
- 实现 commit: `a24f86f580af45bd0cbb28dc242b74e2ff8bbc3a`；tree: `1febaaddfae1478043302c8a800f6174046ea3f0`。分发源 `D:\data\dev-harness` 正常 fetch、detach 到该候选，回读为 clean。
- 批准方案 SHA256: `a6a9cb928853ac9a257d47e020dbc8542d02b40adf51c4ff72a0884a5cee1757`；15 步 actions SHA256: `af1d05e1d4411b666d8792c88d311dd131f8ffecef30c6b2ff028b0a5edfb844`。方案、actions 及其绑定的准备阶段 validation 文件保留原字节；其中 pending 文案是批准前快照，执行授权另见 `deployment-authorization.json`。
- 用户明确答复“批准按固定方案执行（推荐）”。KTB-EX-011 已接受：3391 LOC / 37843 tokens / 11164 statement ASTs，增量 +184 / +1670 / +481，LOC 严格 `<3392`；其他核算和 Adapter 约束不变。
- 新 architecture Approval `apr_multi_workspace_ca55c574d4a148ce9fff87ac78d685d3` 经正常 Task API 导入，exit `0`，Task `2→3`；导入摘要为 `sha256:0c710acd9cbddb280954d043aae7fc9c0e0d4bb456c1afc3d4f39eacb258bfe4`。未激活 current pointer。

## 正常安装与入口

| 根 | preset | install exit | manifest transaction | All-scope exit | protocol exit |
| --- | --- | --- | --- | --- | --- |
| D:\GVPP | core | 0 | committed | 0 | 0 |
| D:\energy\base-service | full | 0 | committed | 0 | 0 |
| D:\energy\base-front | full | 0 | committed | 0 | 0 |

三份 manifest 均位于 `C:\Users\28796\.dev-harness\backups\`：

| 根 | manifest 相对备份目录 | SHA256 |
| --- | --- | --- |
| GVPP | install-20261013-141313-216-60600/install-manifest.json | 94f42e7c35b7dfe362f2b0a04fdaa3ed08c8ca0b8d0de90d180be439c0107152 |
| base-service | install-20261013-141326-261-65052/install-manifest.json | a10f51d0048fdb5ad4845ca5fea900a502419be1b75a4678095dd60c759df32b |
| base-front | install-20261013-141341-693-48492/install-manifest.json | 906b9ed3a5b1722adc1f173e3b9bb06d8ca0b887c2c3ffb8559e690f89cc324e |

34 个备份 payload（包含 directory）经现有 installer helper 核验通过。三根安装校验均 `STATUS: PASS`、warnings/errors none；protocol 均为 v2、admission enabled、runtime writes `0`。完整 argv、时间、输出和 exit code 保留在 `.assistant/runtime/multi-workspace-execution-step-01…14-*.json`；步骤 07 的独立 DryRun 使用单独记录。

## 独立 DryRun 与正式登记

`/root/boundary_audit` 执行真实原生 registration `-DryRun`：exit `0`、`dry_run=true`、`written=false`，registry 仍 missing。前后 Task、Approval、current、index、候选与控制文件均无变更。记录为 `.assistant/runtime/multi-workspace-independent-registration-dry-run.json`，摘要 `sha256:51578b0a645f291f67035d79e7554e6a53d7c607333b6c769ca6afbfc7059d92`。actor/context 来自真实工具上下文及角色引用，无独立 per-call host authentication；不声称更强身份认证。

随后 `/root` 以同一参数、Task version `3` 和 `missing` CAS 正常登记，exit `0`、`written=true`。operation identity 为 `sha256:cd4e84b49cb5544f3f2f4f55e39565b81166eb176d6b25fe7738121f6bfe8f43`，intent digest 为 `sha256:2cd86cd48b96aafbc2858a28c7ec088bb5b4ea4b030b8e47c6194f6d3cdafd24`。

- session: `01a0d718-c8dc-7671-a61a-e28bd31d74e6`；primary: `D:\GVPP`。
- 唯一 additional roots: `D:\energy\base-service`、`D:\energy\base-front`，绑定三根物理身份及批准的 Task/Contract/Approval。
- registry: `D:\GVPP\.assistant\runtime\session-workspaces\7f9d07fd8312d4d34da1091394d9ce7ac8929486597749a1027cb9be6e6656f6.json`。
- registry digest: `sha256:8f0a50014d7aedfa053ffa42dd598df13f24ae9d276c135abfe140666a816460`。公开 `Get-HarnessSessionWorkspaceRoots` 回读恰好返回两个目标根。
- expires_at: `null`，符合明确批准的不自动到期范围；撤销须经 API、当前 CAS 和新的精确 Approval，详见固定方案 Rollback。

## 已安装 K1 与资产保留

| 原生 replay | 真实 exit | 结果 |
| --- | --- | --- |
| 指定 session，两个 IoT 目标 | 0 | allowed=true；两个 workspace_checks 均 allowed |
| 未登记 session | 2 | 拒绝：file mutation target escapes WorkspaceRoot |
| 指定 session，未授权 energy-dispatch-service sibling | 2 | 拒绝：file mutation target escapes WorkspaceRoot |

正负断言核对通过，未创建 probe 文件，registry 摘要不变。聚合记录 `.assistant/runtime/multi-workspace-installed-k1-replay.json` 的摘要为 `sha256:42397b5e33c09c5158936dd8135e0eae78c46e4cff78ff12e9805b320873bd75`；其原始 case 记录保留真实 exit `2`，不改报为 `0`。

最终回读 `.assistant/runtime/multi-workspace-final-readback.json` 为 pass，摘要 `sha256:fc69e588151a049507f97c4a2f0e86331e305da560c2460a6de8946460c65c36`：1358 主记录和 34 补充记录全部核对，仅共享 `pretooluse.ps1` 与 install-registry.json 两项预期受管变更；批准 API 新建的 grant 单列。其他 1356 主记录、全部补充记录、六个 shared consumers 的非目标入口/策略/protocol/current 和四个额外全局配置文件原样。

受保护 `dev-harness-next` 的 index 摘要 `sha256:8cf9b2513bb130f4a0cba063b33aeab23b681186e0c1ef361617086fe039d8ee`、15 条 collapsed status、312 个 untracked 文件名单及摘要均无漂移。业务文件、current pointer、失败历史与用户文件保留。所有正常备份及检查失败记录均保留，未清理。

## 验证边界与治理状态

Focused fixtures 42 checks PASS。首次 Suite all 为 67 pass / 8 fail、exit `1`；8 个失败 owner 的完整原生补跑均 exit `0`，75 个活跃 owner 均有通过覆盖，14 个 archived tests 为 `not_run`。保留原失败日志；没有替代的全绿 Suite all 调用，不把初始结果改报 pass。

最终 Evidence 保留该 exit `1`，AC-1 至 AC-4 satisfied、AC-5 not_verified，不能将 Task 标为 done。独立审计 pass 只表示接受准确的证据和范围，不能替代缺失的验证。

安装、登记和 native replay 不证明实际桌面 Hook 已加载或业务工具已执行，二者仍为 `NOT_VERIFIED`。新增根用于文件工具和直接补丁，Shell 继续按 cwd 的既有策略校验；目标仓库的路径和受保护操作要求仍生效。数据库权限和业务代码未纳入本次变更。
