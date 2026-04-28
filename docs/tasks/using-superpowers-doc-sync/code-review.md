# using-superpowers Doc Sync Code Review

## Findings

- none

## Conclusion

- verdict: pass
- 本轮 scoped sync 已正确收口：
  - 旧的“非 DONE 推进必须显式给 `-Tool`”表述已移除。
  - 当前文案已与真实实现一致：非 `DONE` 推进按 `-Tool -> -Profile -> workflow descriptor default_profile` 解析；只有三者都缺失时才会报 `requires -Tool`。
  - 实际 diff 只落在 `skills/using-superpowers/SKILL.md`，没有扩到代码逻辑或其他邻接文档。

## Evidence

- `git status --short skills/using-superpowers/SKILL.md README.md scripts/advance-stage.ps1 agent-configs/workflows/harness-lite.yaml docs/tasks/using-superpowers-doc-sync`
- `git diff --unified=0 -- skills/using-superpowers/SKILL.md`
- `Get-Content .\skills\using-superpowers\SKILL.md`
- `Get-Content .\scripts\advance-stage.ps1`
- `Select-String -Path .\scripts\advance-stage.ps1 -Pattern 'requires -Tool'`
