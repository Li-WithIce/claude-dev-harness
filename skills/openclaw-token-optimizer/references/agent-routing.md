# Agent 路由配置详解

## 目录

1. [主 Agent 配置原则](#主-agent-配置原则)
2. [子 Agent 分类与模型选择](#子-agent-分类与模型选择)
3. [路由判断逻辑](#路由判断逻辑)
4. [OpenClaw 配置示例](#openclaw-配置示例)
5. [常见误区](#常见误区)

---

## 主 Agent 配置原则

主 Agent 是用户的"接待员"——它理解需求、拆解任务、分配给子 Agent、汇总结果。

**模型：gpt5.4**（必须，因为它需要理解复杂意图和做决策）

**System Prompt 要素：**

```text
你是任务协调员。你的职责：
1. 理解用户意图（不超过 3 句话概括）
2. 将任务拆解为独立子任务
3. 为每个子任务选择合适的执行者
4. 汇总所有子 Agent 的结果，向用户返回清晰的摘要

规则：
- 不要自己执行具体任务，委托给子 Agent
- 子任务之间如果独立，可以并行派发
- 汇总时去除重复，压缩为用户需要的格式
```

**主 Agent Token 节省技巧：**
- System Prompt 固定不变，利用前缀缓存
- 只把"任务摘要"传给主 Agent，不传完整原始数据
- 子 Agent 返回结果时只返回"结论+关键数据"，不返回过程日志

---

## 子 Agent 分类与模型选择

### A类：数据处理型 → glm5

特征：输入格式固定，输出格式固定，不需要推理。

```yaml
agent_type: data_processor
model: glm5
max_tokens: 512
temperature: 0
examples:
  - JSON 字段重命名 / 格式转换
  - CSV 数据提取某列
  - 日志过滤（只保留 ERROR 级别）
  - 多语言字符串翻译（短文本）
```

### B类：状态判断型 → glm5

特征：输入是状态信息，输出是简单判断（是/否/枚举值）。

```yaml
agent_type: status_checker
model: glm5
max_tokens: 64
temperature: 0
examples:
  - 任务是否完成（pending/running/done/error）
  - 用户意图分类（查询/修改/删除，≤10个类别）
  - 内容安全检测（pass/flag）
  - 心跳存活检查
```

### C类：内容生成型 → gpt5.4

特征：需要创造性、推理、或多步骤理解。

```yaml
agent_type: content_generator
model: gpt5.4
max_tokens: 2048
temperature: 0.7
examples:
  - 代码生成 / 代码审查
  - 技术方案设计
  - 复杂文档撰写
  - 用户投诉处理（需要共情）
  - 多步数学/逻辑推理
```

### D类：检索增强型 → glm5（检索）+ gpt5.4（合成）

特征：先检索事实，再综合生成答案。

```
glm5：执行检索查询，提取关键段落（token 少）
  ↓
gpt5.4：基于检索结果生成最终回答（只处理精华，不处理全文）
```

---

## 路由判断逻辑

在主 Agent 的 System Prompt 中嵌入路由规则，让 gpt5.4 输出结构化的子任务分配：

```json
// 主 Agent 输出格式示例
{
  "subtasks": [
    {
      "id": "t1",
      "description": "从订单数据提取金额字段",
      "agent_type": "data_processor",
      "model": "glm5",
      "input_summary": "订单 JSON，字段：order_id, items, total"
    },
    {
      "id": "t2",
      "description": "生成订单异常分析报告",
      "agent_type": "content_generator",
      "model": "gpt5.4",
      "depends_on": ["t1"],
      "input_summary": "t1 提取的金额数据"
    }
  ]
}
```

---

## OpenClaw 配置示例

### 心跳 Agent 配置

```yaml
# openclaw_agents.yaml
agents:
  heartbeat:
    model: glm5
    interval_seconds: 30
    max_tokens: 32
    system_prompt: "回答当前系统状态。只输出：ok 或 error:[原因]"
    temperature: 0

  task_router:
    model: glm5
    max_tokens: 128
    system_prompt: |
      根据任务描述，输出任务类型。
      可选类型：data_processor | status_checker | content_generator | retrieval
      只输出类型名，不要解释。
    temperature: 0

  main_coordinator:
    model: gpt5.4
    max_tokens: 1024
    system_prompt: "你是任务协调员。理解用户需求，拆解为子任务，汇总结果。"
    temperature: 0.3

  data_worker:
    model: glm5
    max_tokens: 512
    temperature: 0

  content_worker:
    model: gpt5.4
    max_tokens: 2048
    temperature: 0.7
```

### 多轮对话历史截断配置

```python
# 历史消息管理
def trim_history(messages, model):
    limits = {
        "glm5": 3,      # 只保留最近 3 轮
        "gpt5.4": 8,    # 保留最近 8 轮
    }
    keep = limits.get(model, 5)
    system = [m for m in messages if m["role"] == "system"]
    non_system = [m for m in messages if m["role"] != "system"]
    # 保留最后 N 轮（每轮 = user + assistant）
    recent = non_system[-(keep * 2):]
    return system + recent
```

---

## 常见误区

| 误区 | 正确做法 |
|------|---------|
| 所有 Agent 都用 gpt5.4 保险 | 分类型选模型，glm5 处理简单任务 |
| 把完整原始数据传给每个子 Agent | 只传子 Agent 需要的字段/片段 |
| 子 Agent 返回完整处理过程 | 子 Agent 只返回结论和关键数据 |
| 每次对话都传完整历史 | 按模型限制截断历史轮次 |
| 心跳也用 gpt5.4 | 心跳必须用 glm5，max_tokens ≤ 64 |
