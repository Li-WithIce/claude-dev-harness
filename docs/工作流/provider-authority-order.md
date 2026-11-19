# Provider Authority Order

## Workflow Authority

1. Current user instruction
2. Current repo files
3. Current v2 Contract and `.assistant/runtime/tasks/{task_id}/task.json`
4. Evidence bound to the current task version, Contract and revision
5. Current task plan and audit where required by its policy
6. Provider output

## Code Authority

1. Current file contents
2. Current command output
3. Current diff
4. Provider index
5. Historical memory

## Memory Authority

1. Current user instruction
2. Current task artifact
3. `.assistant` shared memory
4. Explicitly captured pending memory items (advisory, not task state)
5. agentmemory historical recall

## Conflict Rule

Current repo overrides provider index. Current task overrides historical recall. `.assistant` authority overrides agentmemory recall. User current instruction overrides stale memory.
