---
name: claude-api
description: Use this skill when working with Claude API integrations, including authentication, client setup, message formatting, streaming responses, tool use, and error handling.
---

# Claude API Integration

> **二级能力声明**：本 skill 是开发主流程中的二级能力，仅在 orchestrator 管理的 stage 内被调用。如任务属于标准开发活动，应先由 orchestrator 决定当前 stage，再在 stage 内调用本 skill。

This skill provides guidance for working with the Anthropic Claude API in applications, including authentication, client setup, message formatting, streaming responses, tool use, error handling, and production deployment.

## Quick start

### Official SDKs

Preferred SDKs:

- TypeScript: `@anthropic-ai/sdk`
- Python: `anthropic`

Install examples:

```bash
npm install @anthropic-ai/sdk
python -m pip install anthropic
```

### Basic authentication

Set `ANTHROPIC_API_KEY` and use the official SDKs or direct HTTPS requests.

TypeScript:

```ts
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
```

Python:

```python
import os
from anthropic import Anthropic

client = Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
```

## Common implementation areas

### Messages API

Use the Messages API for most integrations. Typical requests include:

- `model`
- `max_tokens`
- `messages`
- optional `system`
- optional tool definitions

### Streaming

Use streaming for interactive UIs or long outputs. Handle incremental events and assemble the final response safely.

### Tool use

If Claude requests a tool call, execute the tool in your application, then send the result back as a tool result / follow-up message in the expected format.

### Error handling

Plan for:

- invalid authentication
- rate limiting
- network failures
- request timeouts
- malformed tool results

## Production guidance

- Keep API keys in environment variables or a secure secret manager.
- Log request IDs and relevant error metadata.
- Bound retries with backoff.
- Validate tool inputs and outputs.
- Keep prompts and tool schemas versioned.
- Test both streaming and non-streaming paths.

## References

- Docs: https://docs.anthropic.com/
- SDK examples: https://github.com/anthropics/anthropic-sdk-typescript
- Python SDK: https://github.com/anthropics/anthropic-sdk-python
