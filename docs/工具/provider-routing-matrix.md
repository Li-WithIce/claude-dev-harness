# Provider Routing Matrix

| Stage | CodeGraph | agentmemory | codedb-mcp |
|---|---|---|---|
| ENTRY quick | default off | default off | off |
| ENTRY ask | only if repo fact is needed | only if history is requested | off |
| PLAN | optional impact/call hints | optional historical context | off |
| PLAN_REVIEW | evidence grounding checks | stale-memory checks | experimental only |
| IMPLEMENT | optional code hints, then real file reads | rarely, only for accepted constraints | experimental only |
| CODE_REVIEW | optional missed-impact hints | conflict checks | experimental only |
| TEST | optional test-scope hints | no verdict authority | off |

Provider routing is a lazy-loading rule, not a new stage.
All provider entries are advisory.
