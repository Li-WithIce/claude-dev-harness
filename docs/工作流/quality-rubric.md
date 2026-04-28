# Quality Rubric

本文件定义 `-Quality` 模式下 review run 的 4-dim 评分口径。语言以中文为主，dimension 名保留英文，避免与 CCW 原术语漂移。

## Dimensions

### completeness

- 定义：是否覆盖当前阶段必须交付的范围、验收、验证与边界。
- 中文短注：看有没有漏项，尤其是计划里已经批准的 TODO 和回归面。

### consistency

- 定义：文档、实现、验证、结论之间是否互相一致。
- 中文短注：看说法、代码、测试和结论有没有互相打架。

### accuracy

- 定义：论断是否被实际证据支持，且关键字段、路径、命令、contract 是否精确。
- 中文短注：看引用是否准确、命令是否真实、`convergence:` 是否可被 grep / 文件断言 / 命令验证。

### depth

- 定义：是否触及真正的实现风险、耦合点与回归面，而不是停留在表面描述。
- 中文短注：看 review 或实现有没有抓到实质性问题，而不只是形式检查。

## Thresholds

- 综合分 = `completeness` + `consistency` + `accuracy` + `depth` 的等权算术平均，向下取整。
- `≥80`：`pass`
- `60-79`：`revise`
- `<60`：blocker，结论必须是 `revise`
- 任一单维度 `<60`：直接按 blocker 处理，即使综合分仍高于 60 也不能写 `pass`
- `scripts/validate-lite-artifacts.ps1 -Quality` 按本节阈值校验 review run 的 score / verdict 一致性。

## completeness 示例

- `pass` 示例：`score.completeness: 88`
  - rationale: 已覆盖全部批准 TODO、回滚边界、验证命令与已知风险，没有遗漏受影响路径。
- `revise` 示例：`score.completeness: 72`
  - rationale: 主实现已完成，但少了直接相关的回归锁定或文档交接说明，范围覆盖不完整。
- blocker 示例：`score.completeness: 45`
  - rationale: 漏掉已批准的核心 surface 或只做了部分 TODO，无法视为当前阶段完成。

## consistency 示例

- `pass` 示例：`score.consistency: 84`
  - rationale: plan、代码、测试输出与最终结论一致，没有互相打架的地方。
- `revise` 示例：`score.consistency: 68`
  - rationale: 文档说只改 1 条路径，实际 diff 多出直接相关但未解释的改动，仍需收口。
- blocker 示例：`score.consistency: 50`
  - rationale: verdict、实现结果和测试证据互相矛盾，或者 validator / 文档契约两套说法不一致。

## accuracy 示例

- `pass` 示例：`score.accuracy: 90`
  - rationale: 路径、字段名、命令、输出引用准确；`read_first:` 和 `convergence:` 都能被 reviewer 实际抽查。
- `revise` 示例：`score.accuracy: 74`
  - rationale: 主要判断是对的，但有少量表述仍过宽，某些 `convergence:` criterion 需要再具体化。
- blocker 示例：`score.accuracy: 40`
  - rationale: 关键命令不可执行、引用了不存在的路径，或 `convergence:` 只写了 `TBD` / 模糊口号。

## depth 示例

- `pass` 示例：`score.depth: 82`
  - rationale: 已覆盖真正的实现耦合、兼容边界和回归风险，不只是机械列文件。
- `revise` 示例：`score.depth: 66`
  - rationale: 找到了主要问题，但对副作用或零回归面分析不够深入，需要补证据。
- blocker 示例：`score.depth: 35`
  - rationale: 只做表面检查，没有识别会影响主线 contract 的风险或实际 blocker。

## Cross References

- review run 的 score 字段写法见 `skills/review/SKILL.md`
- `read_first:` / `convergence:` 的写法见 `skills/plan/SKILL.md` 与 `skills/orchestrator/references/lite-writing-guide.md`
- wisdom 4 类与本 rubric 无直接字段绑定；wisdom 写入约束见 `skills/obsidian-memory/SKILL.md`
