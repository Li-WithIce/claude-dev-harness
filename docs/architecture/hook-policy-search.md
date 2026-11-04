# Hook SQL 关键词搜索误判修复

## 问题与行为

原有内置 `production-database-destructive` 规则直接对 shell 文本匹配 SQL 关键词。只读搜索中的 `DROP DATABASE`、`DELETE FROM` 等数据参数因此触发受保护写入检查；缺少可信 Environment 时，其异常文本又未匹配 adapter 的有限错误分类，桌面 Hook 显示 `unknown; stage=policy; action=shell`。

首轮部署候选为 `edbdfc71a81c65878998cb866fa4915c0afbfc77`，核心修复位于其 parent `b179f7137c639a80e07dc096a92cf942d61e0785`。共享 matcher 仅为该内置规则识别直接 `rg --no-config` 的有限静态参数；缺少 Environment 的异常采用现有 `protected write requires` 前缀，映射为 `policy-requirement`。匹配原破坏性规则的 SQL 命令仍按原有环境、任务和审批要求检查。

## 有限支持范围

支持的小写直接命令示例：

```text
rg --no-config -n -F -e "DROP DATABASE" -e "DELETE FROM" .assistant/runtime/hook-policy-search-witness.txt
```

选项限定为 `-n`、`-i`、`-F`、`-e`、`--fixed-strings`、`--line-number`、`--count`、`--`。双引号内允许有限 ASCII 静态文本、空格和正则字符 `[]()^*+?|`，以及仅有的 `\s`、`\.`、`\x60` 转义；排除变量展开、命令替换、控制字符、任意反斜线和可转义闭合引号的形式。单引号参数仍不允许空格或复杂正则，未引号参数不允许反斜线，quoted 参数不得以 `-` 开头。未知选项、预处理器、复合命令、管道及 shell 展开继续进入原策略。custom rules 和 read-only session 限制仍单独生效；shell ActionMode 未改为 read。

## 实际计数调用的补修

后续 GVPP 重试仍被拒的原始调用是 `rg --count` 加单引号复杂正则，没有 `--no-config`。原始工具记录给出了 `policy-requirement; stage=policy; action=shell`，聊天最终答复仅引用了分类。此前的 18 个向量和真实读取只证明有限字面量搜索，没有覆盖该计数形式。

计数查询必须改为直接 `rg --no-config --count`，用双引号保护静态正则。SQL 标识符中的反引号用正则 `\x60` 表示，避免 shell 的反引号解释。与原查询语义相同的合成示例为：

```text
rg --no-config --count -e "(?i)^\s*(USE\s|CREATE DATABASE|DROP DATABASE)|\x60synthetic_lab\x60\." .assistant/runtime/hook-policy-count-witness-20261014.txt
```

实际业务聊天应保留它自己的隔离库名及输入路径，并只调整上述搜索形式。本修复不搜索备份内容、不执行业务 SQL，也不自行继续该业务聊天。旧命令缺少 `--no-config`，以及单引号复杂正则、插值、反引号、闭合引号注入等形式继续保留原策略。新增向量在修复前为 24 pass / 2 fail，准确复现两项计数能力缺口；原任务及其 Evidence 保留，补修另用 `hook-policy-count-repair-20261014` 记录。

独立审查发现早期新增 overlay 向量会影响后续否定测试，现已把两种 overlay 放到最后。原 18 个向量完整保留；修正后的完整专项为 26 pass / 0 fail、exit 0。此前同一 Runtime/Adapter 字节的 thin Hook owner 为 228 checks PASS、exit 0；完整 standalone fixture 的新结果覆盖仅有的测试顺序调整，独立审查接受该验证组合。TCB 和 adapter inventory Check 均为 exit 0，Runtime executable LOC 保持 3391。此次没有重跑完整 core，其首轮真实失败及局限仍保留于下文。正常源码更新与安装后验证另由 count 任务记录；本轮回退使用首轮已部署的 edbdfc revision 及正常受管重装。

计数补修候选 `9b678a1233c2f8bbe9ec3bdaa13dee2a2357620d` 已获独立代码审查通过，并正常安装到现有分发源 `D:\data\dev-harness`；分发源保持 clean，四个冻结文件摘要逐项一致。switch、core install、安装后 verifier 和 v2 protocol 的实际 exit 均为 0；verifier 为 42 checks PASS、warnings/errors 均为 none，protocol 的 runtime_writes 为 0。新 manifest 位于 `C:\Users\28796\.dev-harness\backups\install-20261014-142744-995-52196\install-manifest.json`，状态 committed、8 个受管 targets。

安装后的普通工具调用执行上述 canonical count，合成 witness 实际返回 `4`、exit 0，工具 chunk 为 `f77e2f`。25 个保护资产、用户原 staged 文件及 index objects、workspace grant 集合和两处 current pointer 均保持原值；备份仅核对摘要，没有检索其内容或执行业务 SQL。新任务的独立审查、安装回执、保留性核对与实际读取分别记录于 `.assistant/runtime/hook-policy-count-*-20261014.*`；desktop Hook event correlation 仍为 **NOT_VERIFIED**，完整 core 为 **not_run**。旧 read-repair 任务及其 Evidence 保留为 v4/verifying；本轮未修复其重复 Evidence 的生命周期 Schema 缺陷。

原有 shell literal patch recognizer 仅删除了已经由完整形状与参数检查证明冗余的 masking。两个共享调用方仍为 `Harness.ProtectedAction.psm1` 与 `Harness.Policy.psm1`。变更同步覆盖专项 fixture、thin adapter 调用、旧异常断言、maintenance ownership 和生成的 trust catalogs/inventory。Runtime executable LOC 仍为 3391，预算未扩大。

## 验证约定

专项 fixture 只运行预检、rendered adapter 和 launcher，不执行其中的 shell 或业务 SQL。修复前保留的 15 个向量为 2 pass / 13 fail；修复后 18 个向量全部通过，覆盖静态搜索、可信环境要求、生产写入、配置/预处理器注入、反斜线选项转义、shell 展开、只读会话和 custom overlay。

专项为 18 pass / 0 fail、exit 0；thin Hook 为 228 checks PASS；TCB 检查 PASS，Runtime executable LOC 保持 3391。

原 core 在 b179 的独立干净 C 盘 checkout 完成全部 48 个检查（47 owners 加 git diff --check），结果为 **45 pass / 3 fail、exit 1**。逐项功能覆盖矩阵保留该结果，以以下三个完整复验补齐对应 owner：

| Owner | 原 core 结果 | 完整复验 | 结论与限制 |
| --- | --- | --- | --- |
| verify-release-runner-boundary.ps1 | exit 1，C 盘原生错误栈带出用户目录名 | D 盘原 guard/verifier，10/10 PASS，exit 0 | 源码字节及预期拒绝相同；C 盘隐私输出问题仍未修复 |
| verify-v2-install-presets.ps1 | 900.05 秒，exit 124 | 干净 D 盘 b179，442/0，exit 0，960.2002794 秒 | 未过滤任何检查；原 900 秒预算未满足，超时原因 unknown |
| verify-module-manifest-catalog.ps1 | 唯一失败：固定计数 181，实际为 182 | 干净 D 盘 edbdfc，38/0，exit 0，189.6457884 秒 | 仅修正新 fixture 引入的计数及说明；38 个检查和其他十个 totals 断言全部保留 |

最终 edbdfc 的原九个修复文件 SHA-256 全部与 b179 相同，验证选择集不变；唯一子提交修改为 catalog verifier 的上述一行。原 45 项通过和三个完整复验建立 **48/48 功能覆盖**，不等同于原 core suite 通过。独立审查接受该矩阵用于本次正常 D 盘更新，保留两项现有验证局限；不因 test-only 修正重跑未变化的 Runtime owners。

现场日志、真实退出码、完整矩阵及版本化 Evidence 位于任务 `hook-policy-read-repair-20261014` 的 `.assistant/runtime` 和 `docs/tasks` 记录中。最初 dirty checkout 验证失败、中止记录和完整 core 失败记录均保留。

## 更新与回退范围

本机分发源 `D:\data\dev-harness` 已从 `a24f86f580af45bd0cbb28dc242b74e2ff8bbc3a` 正常 detached switch 到 `edbdfc71a81c65878998cb866fa4915c0afbfc77`，保持 clean。正常 `install.ps1 -WorkspaceRoot D:\GVPP -Preset core` 已完成；switch、install、安装后 verifier 和 v2 protocol 回读均为实际 exit 0。安装后 verifier 为 42 checks PASS，warnings/errors 均为 none；protocol 为 selected v2、runtime_writes 0。

新安装 manifest 为 `C:\Users\28796\.dev-harness\backups\install-20261014-120003-467-19144\install-manifest.json`，状态 committed、preset core、8 个受管 targets。12 个展开受管文件字节保持不变；实际 source 的 RuntimeKernel、AdapterAction 和 TCB inventory 更新为冻结候选的精确字节。11 个既有保护资产、两份用户 staged 文件及其 index objects、两处 shared current pointer 和工作区 grant 集合均保持不变。

安装后的普通工具调用直接执行上述有界 rg 搜索，实际 exit 0，并返回合成 witness 的两行匹配；备份只核对文件摘要，未检索或输出数据库备份内容，也未执行业务 SQL。保存结果时的一个含 SQL 数据参数的 inline PowerShell 复合命令被真实 PreToolUse 拒绝，显示 `policy-requirement; stage=policy; action=shell`；拒绝记录保留在内部 failed-writes，结果改用结构化文件写入保存。该真实拒绝与成功工具执行分别记录，直接搜索的独立 desktop Hook event correlation 仍为 **NOT_VERIFIED**。

回退保留旧 revision 和正常安装 manifest，通过正常源码路径及受管重装恢复。整个任务未执行数据库清理、备份恢复、数据库权限修改或新增 workspace grant；未使用 Hook disabling、force、rebaseline 或继承旧 Approval。用户既有 staged 文档、数据库备份、清理范围文档和 shared current pointer 已逐项核对并保留。

任务 CLI 的最后收尾另遇既有生命周期缺陷：本任务曾正常发布 v3 partial Evidence，当前事务 Schema 却要求 verify 的 Evidence before_digest 为 null，因此第二次发布被拒，原生 CLI exit 2，错误为 `transaction journal format is unknown or hybrid`。错误发生在 journal 写盘前；只读回读为 v4/verifying、pending transactions 0、current null。原 Schema 与 TaskState 在本次修复前后均未修改，纯内存对照及独立审查确认根因。Hook 验收、正常安装及真实读取均已完成，机器任务状态仍为 verifying；旧 Evidence、原始失败及精确最终 resolved Evidence 均保留，未删除旧记录或强制改状态。该额外 Schema 缺陷未纳入本次 Hook 修复。

## 2026-10-23 工作流修复与收尾

上述生命周期缺陷已在后续维护任务 `harness-workflow-repair-20261023` 中修复。事务 Schema 允许 Evidence 步骤携带已有文件的 `before_digest`，继续使用现有摘要核对、CAS 写入和恢复流程。Runtime 没有增加旧 Evidence 全文恢复机制；旧全文由版本化归档保留。正常 partial → final、内容冲突拒绝、中断恢复和重复恢复均已覆盖，完整 Evidence owner 为 **99/0、exit 0**。此前两项新增断言误要求日志保存旧全文的失败记录保留，断言修正为核对发布前旧字节的 SHA256 后完成了完整复验。

实际分发源 `D:\data\dev-harness` 已正常更新到 `7432785960b5b0216eba56495d55b8f21bc2bec3`，保持 clean。`D:\GVPP` 和 `D:\data` 的正常 core 安装、安装 verifier 和各自入口 protocol 均为 exit 0；两处入口与安装记录统一指向该分发源，Bootstrap 均为 v2-only，new task admission 为 enabled。安装 manifest 分别位于用户备份目录的 `install-20261023-153804-365-55112` 和 `install-20261023-153836-379-37220`，状态均为 committed。

用户明确要求关闭 PreToolUse 后，其偏好保存为 `C:\Users\28796\.dev-harness\preferences.json` 中的 `pretooluse_enabled: false`。安装和更新读取该偏好，保持 Codex、Claude 均无 PreToolUse 注册。Codex `features.hooks=false` 和用户 `AGENTS.md` 字节保留；安装器对已有用户级规则采用 create-if-missing，不再覆盖。其他 Hook 事件、原两份用户 staged 文件及 index、`dev-harness-next` 的 index 与既有修改、三个 current pointer 和 workspace grants 均经回读保持原值。

完整安装回归为 **460/0、exit 0**，分发检查为 **68/0、exit 0**；TCB、module catalog 和 adapter inventory 检查通过，Runtime executable LOC 仍为 3391。安装回归在 `e288edc` 完成，最终 child `7432785` 仅修正上述 Evidence 测试断言，生产代码字节完全相同。未重跑完整 core，上文原 core 失败、C 盘隐私输出和时间预算局限继续保留。当前普通工具读取合成 witness 返回计数 `4`、exit 0；没有读取真实数据库备份或执行业务 SQL，desktop Hook event correlation 仍为 **NOT_VERIFIED**。

旧任务 `hook-policy-read-repair-20261014` 经独立审查后，已通过正常 `verify -ExpectedVersion 4` 发布精确 Evidence `sha256:3c520ea54198d9093c83bdbc85ad1df4ccfbf85825b472332e859b0337cc68b1`，正常进入 **v5/done**，pointer_action 为 unchanged。原 partial Evidence、旧 audit 和历史最终 resolved Evidence 的精确副本位于 `.assistant/runtime/harness-workflow-repair-20261023/old-task-archive/`。新旧日志、安装回执和保留性核对位于同一维护记录目录；本次任务的 Contract 与最终 Evidence 位于 `docs/tasks/harness-workflow-repair-20261023/`。另外两个未完成任务保持原状态。
