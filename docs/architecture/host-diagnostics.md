# 按需宿主诊断与真实验收

`scripts/diagnose-harness-host.ps1` 是人工调用的只读工程诊断，不进入普通请求准入路径，不授予 TaskId、Approval、ExpectedVersion 或写入权限。不修改 Runtime、Hook、信任、预算或 HostCapabilities 公共 Schema。

新增脚本归属现有 harness-maintenance 的 C2 工程包。当前精确 C2 清单由 43 增至 44，对应构造器和 owner 的数量断言同步，仍检查逐项归属；不改变历史 TK-07 记录、Runtime roots 或计量算法。相关清单由原生成器派生。

## 使用

在集成源码目录调用 PowerShell 7.2 以上版本。先由操作者将 `$expectedWorkspace`、`$expectedSource` 设置为明确的绝对路径，不以协调进程目录代替被测会话目录：

```powershell
./scripts/diagnose-harness-host.ps1 -WorkspaceRoot $expectedWorkspace -RepoRoot $expectedSource
```

默认仅返回 JSON，不写观察文件。可选 `-ProbeHostDetails` 复用 HostCapabilities 的 CLI 版本探测；该版本不代表桌面后端。`-UserProfileRoot` 指定被观察配置根；未指定时使用协调进程 USERPROFILE。`-CodexHome` 可显式指定 Codex 配置目录；否则显式 UserProfileRoot 下取 `.codex`，再否则使用协调进程 CODEX_HOME 或用户 `.codex`。这些环境来源都不是历史被测会话的环境证明。

已获得最小宿主记录摘录时，可加 `-ObservationPath $recordPath`。需要保存时明确加 `-OutputPath $externalObservationPath`：必须是工作区及诊断源码目录之外、父目录已存在的新文件。不会覆盖旧文件。保存失败返回固定错误和原观察投影，不换通道、不改变原允许/拒绝结果。退出码：0 表示诊断完成且未发现定位/配置问题（**不表示 Hook 通过**）；1 表示具体不匹配或记录不可用；2 表示输入/诊断来源不可用；3 表示保存失败，`assessment_exit_code` 保留保存前结果。

## 观察契约

| 字段 | 来源与含义 |
|---|---|
| `coordinator_cwd` | 本次诊断进程目录；绝不作为历史工具 cwd |
| `session.cwd` | 仅从标为 host-record 的宿主记录摘录读取，否则 null；合法子目录可匹配，其他工作区或嵌套安装入口明确不匹配 |
| `entry` | 通过 PowerShell AST 读取本地 task.ps1 的字面根绑定与脚本路径；不执行所发现的入口 |
| `hooks` | 只投影用户/工作区 hooks.json 的相关 PreToolUse launcher 引用与已知下游文件身份；不输出命令正文或其他 Hook 配置 |
| `source_aligned` | kernel、AdapterAction 路径是否来自期望源码；即使内容相同，异源路径也明确不匹配 |
| `rendered_content_matches` | 按现有安装的单引号转义及占位符替换契约比较 launcher/adapter 文本；同时保留安装文件 SHA256，不能比较模板与渲染文件的原始哈希 |
| `protocol` | 复用现有库的协调者只读查询；不代表被测会话调用了入口 |
| `cli` | 现有 HostCapabilities 声明与可选 CLI 版本，不是桌面能力实时发现 |
| `configured` | 在所检查 JSON 层看到引用，不能推导已加载/信任/执行 |
| `loaded`、`trusted`、`enabled` | 仅投影明确取得的宿主状态。hooks/list 的 trustStatus 为 managed/trusted/untrusted/modified；其元数据没有 loaded 字段，不能由列表存在填 true |
| `hook_process_observed` | 所提供宿主记录包含进程运行摘要；仍需单独确认它属于 Harness |
| `host_tool_event_observed` | 所提供宿主记录存在工具事件，不由文件写入成功推导 |
| `decision_observed` | 只投影明确的 permissionDecision；completed/failed、模型停止或 API 预检都不能补出决策 |
| `correlation` | 展示事件 sourcePath 与配置是否相符；一个配置可有多个 Hook，路径相符或相邻记录不足以自动证明 Harness handler 或工具与决策的关联 |

因此 `harness_handler_attribution` 和 `tool_to_hook_attribution` 保守保持 unknown，留给持有原始宿主记录的操作者核验。诊断本身不认证调用者提供的摘录。单独给出 `diagnostic_run_id`；宿主字段 threadId、turnId、session_id、turn_id、tool_use_id、Hook run.id 按原命名复制，缺失为 null，不生成代用 ID。HookRunSummary 没有 tool_use_id，不能从 run.id 推造。

下面是**合成投影夹具**的输入形状，不是真实宿主记录、执行证明或公共授权 Schema。真实输入只摘录已经取得的对应字段，未取得的字段应省略：

```json
{
  "source_kind": "synthetic-process",
  "source_reference": "isolated-process-receipt",
  "run": { "id": "fixture-run", "handlerType": "command", "eventName": "PreToolUse", "status": "completed" },
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "permissionDecisionReason": "Harness PreToolUse denied: policy-requirement"
  }
}
```

source_kind 只接受 host-record 或 synthetic-process，source_reference 是已有本地记录引用。后者仅填 synthetic 维度，不能提升为真实宿主进程、工具事件或会话 cwd。记录限 64 KiB，只投影允许字段；不保存完整补丁、tool_input、命令、stderr、entries.text、statusMessage、认证文件、环境或聊天，也不对敏感值计算摘要。文件哈希仅用于指定源码/安装脚本身份。调用者应在提供摘录之前去除敏感正文；诊断不应接收原始聊天或认证文件。

仅解析正常字面绑定；动态命令、缺失文件和无法识别的绑定报告 unavailable，不执行它们来“探测”。TOML、插件、企业层的合并结果和真实信任/加载状态必须通过宿主接口获得；未检查层不算没有 Hook，也不自动修改配置。PowerShell 本身可能维护进程启动缓存；这不属于诊断新增的任务或全局审计日志，隔离测试将协调进程缓存与被观察配置目录分开。

## 拒绝分类与验证范围

已有 H02 adapter 以退出 2 和精确 `HARNESS_DENY:<code>` 报告已知类别。launcher 仅转发现有允许表中的精确类别为 `Harness PreToolUse denied: <code>`，向宿主输出 deny JSON；launcher 退出 0 不等于允许。诊断从该现有允许表识别已知类别，不新增政策引擎。input、permission-mode、workspace-binding、patch-path、patch-syntax、path-boundary、read-only、shell-form、policy-requirement、policy-unavailable、startup 沿原契约解释。

未知或混杂 stderr、异常、超时保持通用拒绝或原有固定启动诊断，不透传正文，不把 unknown 归为政策命中。当前 adapter 的 permission_mode 仅支持 default/bypassPermissions；官方文档还有其他模式，出现 permission-mode 必须如实记录输入兼容缺口，本次不扩大 Runtime 接受范围。policy-requirement 也不能单凭类别解释为“一定缺生产 Approval”；具体条件需核对原政策与已确认任务。

`tests/verify-host-diagnostics.ps1` 验证只读投影、定位/来源不匹配、隐私和缺证据行为；`tests/verify-thin-adapters.ps1` 复用现有渲染夹具验证 H02 分类从真实 adapter 进程经 launcher 到宿主响应格式。后者均称为**合成触发的进程链验证**，没有真实宿主工具请求，不是历史事件复现。`tests/verify-runtime-hooks.ps1` 保留其既有 owner 覆盖。

## 官方能力与现场缺口

参考：[Codex Hooks](https://developers.openai.com/codex/hooks/)、[App-server](https://developers.openai.com/codex/app-server/)、[CLI reference](https://developers.openai.com/codex/cli/reference/)。CLI `/hooks` 可查看来源、启用与信任状态；非托管定义可能因未信任或定义变化被跳过。不要修改信任文件来补验收。

桌面后端协议具有 hooks/list 与同步 hook/started、hook/completed 通知。通知是进程摘要，sourcePath 是配置来源，不保证是执行脚本；异步 Hook 不产生同样的同步通知。已安装后端生成的协议 Schema 与在线文档支持这些方法，不代表本轮连接器暴露了它们，也不代表过去事件可回放。CLI 与桌面的版本及接口分别记录在外部观察材料中。

当前必要后续操作是：让**连接被测桌面会话的现有客户端**提供一次绝对 cwd 的 hooks/list 结果，并在同一连接采集相关同步 hook/started、hook/completed 以及对应工具/决策记录的最小摘录。需要来源、启用/信任、thread/turn、Hook run、已有 tool_use_id、目标根与允许/拒绝类别；不得采集完整 tool_input/stderr。当前工具连接器未暴露这一接口时，执行证据保持 NOT_VERIFIED，不循环查询空历史，不另启动独立 app-server 冒充现有桌面连接。现阶段无需新增 Runtime 全局事件收集器。

## 后续真实宿主验收步骤

1. 每个请求明确目标工作区绝对根，在新被测会话记录其归属、项目指令读取和本地 protocol 调用。协调者补跑不能代替被测记录；根内普通子目录合法，其他工作区应停止并记录定位问题。
2. 核对来源及真实可观察的加载/信任状态。必要的正常界面加载/信任动作由用户完成，不自动改权限或配置。
3. 只读核对结束、业务请求发出前，使用已有范围与算法建立阶段快照，放工作区外；不改名旧快照冒充新基线。
4. 普通允许与受保护拒绝分别发送、分别建请求前后快照。仅走约定真实工具链；不以直接 API 预检或其他 Hook/系统拒绝替代 Harness 事件。
5. 模型调用前按规则停止可说明模型遵循，不能算 Hook 拦截；不要强迫它忽略规则制造调用。配置、安装/protocol PASS、成功写入均不是执行证据。
6. 分别结算定位、入口、配置、加载/信任、进程、真实工具、决策和目标结果。没有可靠的真实调用与决策关联保持 NOT_VERIFIED；通用错误只证明观察到拒绝，原因 unknown。保存失败不绕过、不影响原决策。

本说明不改变 B01–B06 原结算，尤其不将原 B06 改写成新通过；不自动发起复测、部署或新的修复。
