# Risk-Driven Adversarial Review Playbook

Adversarial review is a risk-driven human/process practice, not a fixed-count machine gate. Do not require five, seven, or nine rounds merely because a task belongs to a named version line.

## When independent review is required

Require an independently identified reviewer and an `evidence_digest` only when a change is high risk: production publishing/release, permissions or identity boundaries, data migration/destructive recovery, or an irreversible external effect. Routine documentation, isolated refactors, and ordinary feature work use the normal latest-run review gate.

For a high-risk review run, record:

- `reviewer_identity`: a reviewer role or person distinct from the implementer
- `evidence_digest`: short hash or stable summary of the inspected diff, commands, and artifact paths
- `question`, `evidence_paths`, `finding`, `severity`, `mitigation`, and `status`

Blocking findings must be mitigated before the human reviewer gives `verdict: pass`.

Every review run has exactly one `- verdict: pass | revise` and exactly one findings form: inline `- findings: none`, or a bounded `- findings:` block containing only indented `P0`-`P3` entries. The block ends at the next top-level `- key:` or the end of the run. Duplicate, mixed, empty, or malformed forms are rejected.

## Current enforcement

- This playbook does not introduce a workflow stage or frontmatter fields.
- `advance-stage.ps1` evaluates the latest structured review run; it does not count free-form adversarial rounds.
- Latest `pass` is rejected when its real findings block contains `P0`/`P1`; latest `revise` is rejected with `findings: none`. `pass` with only `P2`/`P3` is legal. Historical contradictions remain append-only history and do not override a legal latest run.
- Text outside the bounded findings block, including `next` or evidence text containing `P1:`, is not a finding.
- Validators enforce this structured contract, but they do not pretend that a numeric round count is machine proof.

## Question bank

Select only questions relevant to the risk:

1. Workflow Core Defender
2. Install Isolation Defender
3. Truth Source Defender
4. Provider Staleness Defender
5. Minimal Safe Change Defender
6. Experimental Provider Defender
7. Validator Compatibility Defender
8. Lazy Loading / Skill Footprint Defender
9. Scope Creep Defender

Every finding must cite current repo evidence. Provider hints can start a question, but they cannot be the answer.
