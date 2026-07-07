# Adversarial Review Gate

At least five adversarial review rounds are required before IMPLEMENT for V0-V3. V4-V6 require at least seven rounds. A final release review uses nine rounds.

## Rule

- Each round records reviewer_role, question, evidence_paths, finding, severity, mitigation, and status.
- Blocking findings must be mitigated; the task must not advance while a blocking item is open.
- Review records must not introduce a new stage.
- Review records must not add frontmatter fields.

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
