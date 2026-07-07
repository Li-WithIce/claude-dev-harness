# Adversarial Review Gate

At least five adversarial review rounds are required before IMPLEMENT for V0-V3. V4-V6 require at least seven rounds. A final release review uses nine rounds.

## Rule

- Each round records reviewer_role, question, evidence_paths, finding, severity, mitigation, and status.
- Blocking findings must be mitigated; the task must not advance while a blocking item is open.
- Review records must not introduce a new stage.
- Review records must not add frontmatter fields.

## Current Enforcement

- This is a formal human/process gate, not a parsed workflow stage.
- Current validators verify that this contract exists and is referenced; they do not count or parse per-task adversarial review rounds.
- `advance-stage.ps1` only checks the latest review `verdict`; it does not parse free-form adversarial review notes in this pass.
- Future work may add an advisory or strict parser once the review record format is stable enough to parse without breaking old tasks.

## Required Rounds

1. Workflow Core Defender
2. Install Isolation Defender
3. Truth Source Defender
4. Provider Staleness Defender
5. Minimal Safe Change Defender
6. Experimental Provider Defender
7. Validator Compatibility Defender
8. Lazy Loading / Skill Footprint Defender
9. Scope Creep Defender

## Evidence Rule

Every finding must cite current repo evidence. Provider hints can start a question, but they cannot be the answer.
