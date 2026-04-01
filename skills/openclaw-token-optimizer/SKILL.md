---
name: openclaw-token-optimizer
description: 为 OpenClaw 平台节省 token 的优化指南。当需要降低 LLM 调用成本、配置主/子 Agent 模型路由、优化心跳或轮询任务、精简 Prompt 时使用。适用模型：glm5（低成本）和 gpt5.4（高能力）。触发词：节省token、token优化、降低成本、模型路由、心跳用哪个模型、主Agent配置、子Agent配置。
---

# OpenClaw Token 优化指南

**输出语言：** 中文（非代码文本）。代码、命令、标识符保留英文。

## 核心原则

**贵的模型做判断，便宜的模型做执行。** 不是每次 LLM 调用都需要最强的模型。

## 模型速查

| 模型 | 成本 | 适用场景 |
|------|------|---------|
| `glm5` | 低 | 心跳、状态检查、格式转换、简单分类、路由判断 |
| `gpt5.4` | 高 | 复杂推理、代码生成、多步规划、用户直接对话 |

## 优化维度一：心跳 / 轮询任务 → 用 glm5

心跳、状态探测、健康检查等调用频率高但内容简单——永远用 `glm5`。

```yaml
# OpenClaw 心跳任务配置示例
heartbeat_task:
  model: glm5
  max_tokens: 64
  temperature: 0
  prompt: "状态检查：当前任务是否正常？回答 ok 或 error。"
```

**适用 glm5 的场景清单：**
- 定时心跳 / keepalive
- 任务状态轮询（pending / running / done）
- 简单路由判断（把请求分给哪个子 Agent）
- 日志摘要（把长日志压缩为一行）
- 格式转换（JSON → YAML，字段重命名）
- 简单分类（意图识别，类别 ≤ 10 个）

## 优化维度二：主 Agent / 子 Agent 分工

主 Agent 负责沟通和任务拆解；子 Agent 负责实际执行。两者用不同模型。

```
用户请求
  │
  ▼
主 Agent（gpt5.4）── 负责：理解需求、拆解任务、汇总结果、回复用户
  │
  ├─→ 子 Agent A（glm5）── 数据获取 / 格式处理 / 简单转换
  ├─→ 子 Agent B（glm5）── 日志分析 / 状态汇报
  └─→ 子 Agent C（gpt5.4，仅当任务需要复杂推理时）── 代码生成 / 方案设计
```

详细配置方案见 [references/agent-routing.md](references/agent-routing.md)

## 优化维度三：Prompt 精简

每多 100 个输入 token = 多付钱。精简 Prompt 是零成本降费。

**5 条黄金规则：**

1. **删重复**：同一条规则只说一遍，不要在 system + user 里各说一遍
2. **删客套**：去掉"请你帮我"、"非常感谢"等无效前缀
3. **用列表代替段落**：列表比散文 token 效率高约 20%
4. **Context 只传必要字段**：传 JSON 时只传当前任务需要的字段
5. **历史截断**：多轮对话只保留最近 N 轮（推荐 glm5 保留 3 轮，gpt5.4 保留 8 轮）

详细 Prompt 精简技巧见 [references/prompt-compression.md](references/prompt-compression.md)

## 优化维度四：输出长度控制

输出 token 通常比输入贵 2-3 倍，优先压缩输出。

```yaml
# 在 System Prompt 末尾加入输出约束
output_rules: |
  - 回答简洁，不超过 200 字
  - 不要重复用户的问题
  - 不要加结束语（"希望对您有帮助"等）
  - 结构化数据用 JSON，不用 Markdown 表格
```

## 优化维度五：缓存 / 批处理

- **前缀缓存**：把不变的 System Prompt 放最前面，OpenClaw 的前缀缓存命中可节省 50-80% 输入费用
- **批处理**：非实时任务（报告生成、批量分析）用 batch 模式，通常有折扣
- **去重调用**：同一个输入在同一分钟内被调用多次时，缓存结果直接返回

## 快速决策树

```
收到任务
  │
  ├─ 是否是心跳/状态检查/简单分类？
  │   └─ 是 → 用 glm5，max_tokens ≤ 128
  │
  ├─ 是否是子 Agent 执行任务（格式转换/数据处理）？
  │   └─ 是 → 用 glm5
  │
  ├─ 是否需要复杂推理/代码生成/用户直接对话？
  │   └─ 是 → 用 gpt5.4
  │
  └─ 不确定？
      └─ 先用 glm5 试，输出质量不达标再升级到 gpt5.4
```

## 参考文件

- **Agent 路由配置详解** → [references/agent-routing.md](references/agent-routing.md)
- **Prompt 精简技巧** → [references/prompt-compression.md](references/prompt-compression.md)
