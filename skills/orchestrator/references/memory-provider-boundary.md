# Memory Provider Boundary

- `.assistant` and `docs/tasks` are authoritative memory/workflow state.
- agentmemory is read-only historical recall.
- agentmemory output must be marked historical context when it affects a task.
- Current repo, current plan, and user instruction override historical recall.
- agentmemory output can enter evidence, risks, or plan TODOs; it must not enter frontmatter.
- agentmemory must not bypass inbox/triage/promote for wisdom.
- Windows users should treat WSL2 as the practical fast path when native setup is limited.
- Harness install/update must not run `agentmemory connect`.
