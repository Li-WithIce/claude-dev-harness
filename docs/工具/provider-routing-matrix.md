# Provider Routing Matrix

| Operation | CodeGraph | agentmemory | codedb-mcp |
|---|---|---|---|
| Direct | default off; explicit code-intel need only | default off; explicit history need only | off |
| Ask | only if a repo fact resolves uncertainty | only if history is requested | off |
| Governed planning, when required | optional impact/call hints | optional historical context | off |
| Implementation | optional code hints, then real file reads | only for relevant historical constraints | experimental only |
| Policy-required review | optional missed-impact hints grounded in current files | stale-memory/conflict checks | experimental only |
| Verification | optional test-scope hints | no verdict authority | off |

Provider routing is a lazy-loading rule, not a new stage.
All provider entries are advisory.

Local `.assistant/entry/context.ps1 recall/read` is an on-demand read-only alternative for project documents and explicitly requested Codex history. It needs no Provider and does not create a task or activate full Memory.
