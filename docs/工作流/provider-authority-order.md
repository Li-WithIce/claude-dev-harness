# Provider Authority Order

## Workflow Authority

1. Current user instruction
2. Current repo files
3. `docs/tasks/<task-id>/plan.md` frontmatter
4. `docs/tasks/<task-id>/test.md` conclusion
5. `.assistant/运行时/*` derived view
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
4. `.assistant/运行时/收件箱.md` pending items
5. agentmemory historical recall

## Conflict Rule

Current repo overrides provider index. Current task overrides historical recall. `.assistant` authority overrides agentmemory recall. User current instruction overrides stale memory.
