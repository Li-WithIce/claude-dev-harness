# Prompt 精简技巧

## 目录

1. [精简原则总览](#精简原则总览)
2. [System Prompt 瘦身](#system-prompt-瘦身)
3. [用户 Prompt 优化](#用户-prompt-优化)
4. [Context 传递优化](#context-传递优化)
5. [多轮对话管理](#多轮对话管理)
6. [Before / After 对比示例](#before--after-对比示例)

---

## 精简原则总览

Token 节省 = 删无用 + 压有用 + 缓存不变

| 优化类型 | 预计节省 | 难度 |
|---------|---------|------|
| 删除重复/废话 | 10-30% | 低 |
| 结构化替代散文 | 10-20% | 低 |
| 只传必要 Context 字段 | 20-60% | 中 |
| 历史对话截断 | 30-70% | 低 |
| System Prompt 前缀缓存 | 50-80% | 低（平台支持时） |
| 模型路由（glm5 替代 gpt5.4） | 60-90% | 中 |

---

## System Prompt 瘦身

### 规则1：删除客套语

```
# 删除前（12 tokens）
请你仔细阅读用户的问题，然后给出详细、全面、准确的回答。

# 删除后（0 tokens）
[直接写规则，不需要这句]
```

### 规则2：删除重复约束

```
# 错误：同一规则说两遍
- 回答要简洁
- 不要啰嗦，保持简短
- 避免冗余内容

# 正确：只说一次
- 回答 ≤ 100 字
```

### 规则3：用列表代替段落

```
# 段落写法（高 token）
你是一个客服助手，你需要用礼貌、专业的语气回答用户的问题。
当用户遇到问题时，你要表示理解和同情。你不应该承诺无法实现的事情。

# 列表写法（低 token，相同信息）
角色：客服助手
语气：礼貌专业
规则：
- 表示理解再解决
- 不承诺无法实现的事
```

### 规则4：固定部分放最前面（利用前缀缓存）

```python
# System Prompt 结构（缓存友好）
SYSTEM_PROMPT = """
[固定部分 - 永远不变，会被缓存]
你是任务协调员。
规则：简洁、结构化、只返回必要信息。

[动态部分 - 每次可能不同，放最后]
当前任务：{task_description}
可用工具：{tools_list}
"""
```

---

## 用户 Prompt 优化

### 去掉无效前缀

```
# 低效
请你帮我分析一下这段代码有没有 bug，谢谢。

# 高效
分析下列代码的 bug：
```

### 指定输出格式（避免模型猜测）

```
# 不指定格式 → 模型可能生成大量解释文字（高 token 输出）
分析这份日志。

# 指定格式 → 输出精准、token 少
分析日志，输出 JSON：
{"errors": [...], "warnings": [...], "summary": "一句话"}
```

### 给出约束而不是祈使

```
# 祈使（容易被忽略）
请简短回答。

# 约束（强执行）
回答 ≤ 50 字。
```

---

## Context 传递优化

### 只传当前子任务需要的字段

```python
# 错误：传完整对象
full_order = {
    "order_id": "ORD-123",
    "user_id": "U456",
    "user_name": "张三",
    "user_email": "zhangsan@example.com",
    "items": [...],  # 可能很长
    "shipping_address": {...},
    "payment_info": {...},
    "total": 299.00,
    "created_at": "2026-03-13T10:00:00Z"
}

# 正确：只传子任务需要的字段
task_context = {
    "order_id": "ORD-123",
    "total": 299.00,
    "items_count": 3
}
```

### 长文本只传摘要

```python
def prepare_context(raw_log: str, model: str) -> str:
    """根据模型选择传完整日志还是摘要"""
    if model == "glm5":
        # glm5 做日志分析：只传最后 50 行 + error 行
        lines = raw_log.split("\n")
        errors = [l for l in lines if "ERROR" in l]
        recent = lines[-50:]
        return "\n".join(errors[:10] + ["..."] + recent)
    else:
        # gpt5.4 做深度分析：传完整日志（但也要限制长度）
        return raw_log[:8000]  # 约 2000 tokens
```

### 避免在 Context 里传 Prompt 本身

```
# 错误：在 context 里重复系统规则
context = f"""
系统规则：你是客服助手，要礼貌专业...（500字规则）
用户数据：{user_data}
"""

# 正确：系统规则在 System Prompt，context 只传数据
system = "你是客服助手，要礼貌专业...（500字规则）"
user = f"用户数据：{user_data}"
```

---

## 多轮对话管理

### 按模型设置历史保留轮数

```python
HISTORY_LIMITS = {
    "glm5": 3,      # 3轮 ≈ 6条消息
    "gpt5.4": 8,    # 8轮 ≈ 16条消息
}

def get_messages_for_api(history: list, model: str) -> list:
    limit = HISTORY_LIMITS.get(model, 5)
    system_msgs = [m for m in history if m["role"] == "system"]
    chat_msgs = [m for m in history if m["role"] != "system"]
    # 每轮 = user + assistant，保留最近 N 轮
    recent_chat = chat_msgs[-(limit * 2):]
    return system_msgs + recent_chat
```

### 长对话插入摘要代替截断

```python
def summarize_old_history(old_messages: list) -> dict:
    """当历史过长时，用 glm5 生成摘要替代原始历史"""
    summary_prompt = f"""
    以下是对话历史，用 3 句话概括关键信息：
    {format_messages(old_messages)}
    """
    summary = call_llm("glm5", summary_prompt, max_tokens=150)
    return {"role": "system", "content": f"[历史摘要] {summary}"}
```

---

## Before / After 对比示例

### 示例1：心跳 Prompt

```
# Before（~40 tokens）
请检查当前系统的运行状态，如果一切正常请告诉我系统正常运行，
如果有问题请详细描述发生了什么问题以及可能的原因。

# After（~8 tokens）
系统状态检查。输出：ok 或 error:[原因]
```
**节省：~80%**

---

### 示例2：意图分类 Prompt

```
# Before（~60 tokens）
请分析用户的以下输入，判断用户的意图是什么，
可能的类别包括：查询订单、修改订单、取消订单、投诉、咨询产品、其他。
请只输出类别名称。

# After（~20 tokens）
用户意图分类。类别：查询订单|修改订单|取消订单|投诉|咨询产品|其他
只输出类别名。
```
**节省：~67%**

---

### 示例3：数据提取 Prompt

```
# Before（~50 tokens）
请从下面的 JSON 数据中提取所有产品的名称和价格，并以列表形式返回给我，
每行一个产品，格式为"产品名: 价格"。

# After（~15 tokens）
提取产品名和价格。格式：每行"名称:价格"
数据：{json_data}
```
**节省：~70%**
