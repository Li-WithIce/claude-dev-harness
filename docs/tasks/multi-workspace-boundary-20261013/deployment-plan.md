# 固定候选部署方案

本方案准备就绪，尚未批准执行。目录范围已获授权；本次确认绑定具体候选、预算、共享安装影响和登记操作。

- candidate commit: a24f86f580af45bd0cbb28dc242b74e2ff8bbc3a
- candidate tree: 1febaaddfae1478043302c8a800f6174046ea3f0
- deployment plan: deployment-plan.json
- deployment plan SHA256: 67051f2a30613dc1bcde61fccce9dcc0c57ab48fe266bf954956a8ca5a76c405
- exact actions: deployment-actions.json，15 条固定命令
- actions SHA256: af1d05e1d4411b666d8792c88d311dd131f8ffecef30c6b2ff028b0a5edfb844
- task_id: multi-workspace-boundary-20261013
- current task version: 2，running，approvals=[]
- contract digest: sha256:9f572e778018fc32dfe71a0f12c2bcf336108ffde5e7aeda00837d2c10be151a

## 正常升级与会话授权

将干净的 `D:\data\dev-harness` 分发源从保留基线 `c4faeb66eaf78bc52cf69259c5207f6fe2348ac6` 切换到上述固定候选，按正常 installer 安装：

| 工作区 | 预设 |
| --- | --- |
| D:\GVPP | core |
| D:\energy\base-service | full |
| D:\energy\base-front | full |

只为会话 `01a0d718-c8dc-7671-a61a-e28bd31d74e6`、主根 `D:\GVPP` 登记两个 IoT 根，绑定三根物理身份。registry 初始状态必须为 `missing`。本会话授权不自动到期；通过相同 API 的空根集和当前 CAS digest 撤销。

共享全局 Hook 的升级会影响六个现有消费者：`D:\data\dev-harness`、`D:\data\dev-harness-next`、`D:\data\harness-b01-20260914-30eb4767\workspace`、两个 IoT 根和 `D:\GVPP`。全部需要回读；非目标入口、协议、策略、指针，以及受保护 worktree 的 index、15 条状态和 312 个未跟踪文件均须保留。

## 执行顺序与检查

1. 在具体方案获批准后导入新的 architecture Approval，通过正常 task API 将 Task 2→3；不激活 current pointer。登记 operation identity 为 `sha256:cd4e84b49cb5544f3f2f4f55e39565b81166eb176d6b25fe7738121f6bfe8f43`。
2. fetch 固定候选，正常 detach checkout，并按 core/full/full 安装。记录真实退出码和各 installer manifest，保留安装备份。
3. 由不同 actor/context 执行真实登记 `-DryRun`；成功且 registry 未创建后，按相同参数和 `missing` CAS 正式登记。
4. 在三个目标根分别执行 `verify-installation -Scope All` 和真实入口 `protocol`。比对安装资产与六个消费者，保留用户配置片段、业务文件、历史 Task/failed-writes 和 current pointer。
5. 执行已安装 K1 的只读预检：指定会话的两个目标允许，未知会话和未授权 sibling 拒绝；不创建 probe 文件，registry digest 不变。该结果属于 native replay。

任一候选、Task/Contract、Approval、物理身份、CAS、preimage 或资产不匹配即停止。允许正常 installer 的受管资产/配置块变化；禁止 force checkout、Git trust 修改、Hook 停用、旧 Approval 继承和手工改 registry。

回滚顺序：若已登记，先用新的精确 scope Approval 和当前 CAS 通过新 API 撤销，再切回保留基线并正常重装 core/full/full。基线没有登记 API。保留全部备份、失败证据和用户文件。

## 预算与证据

确认候选 KTB-EX-011：Runtime **3391 LOC / 37843 tokens / 11164 statement ASTs**，较基线实现 **+184 / +1670 / +481**；LOC 严格上限 `<3392`。原始 3068 基线、旧额度、核算算法、密度规则和每个 Adapter `<200` 不变。

75 个活跃 owner 均已有通过覆盖：首次 Suite all 为 **67 pass / 8 fail、exit 1**；8 项完整原生补跑均 **exit 0**，失败历史保留。完整安装预设 442 项、只读零写入 10 项通过。详见 validation-report.md。

主 preimage SHA256 为 `8837f306b05f0b5d2effd1a1ab666fb6d237b895ee6cd57dce272729c3fea795`；补充 preimage 为 `26e9bd8e9be82956d13c9c6c16c8ad7ee6552639bc2fdb57f0b18b4fe73dd5ce`。共保留 1358+34 条记录，含四个额外全局配置文件；配置敏感内容不回显。

本方案的审批要求来自当前 Task 的 `approval_required: true` 和登记 API 对当前 architecture Approval 的要求。新的 Approval 必须绑定本方案 digest、固定 commit/tree、预算以及 version 3 的精确登记 operation。

真实桌面 Hook 加载与业务写入仍为 `NOT_VERIFIED`。Shell 继续沿用 cwd 的既有策略；新增根用于文件工具和直接补丁。数据库权限和业务代码尚未改动。
