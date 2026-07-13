# Risk-Driven Adversarial Review Playbook

Before IMPLEMENT, use adversarial review questions in `## Plan Review` only to the degree justified by risk. This is a human/process playbook, not a fixed number of review rounds and not a separate workflow stage.

For production publishing, permissions/identity boundaries, data migration/destructive recovery, or irreversible external effects, the latest review run must name an independent `reviewer_identity` and include an `evidence_digest` of the inspected diff, commands, and artifact paths. Routine work uses the normal review run format without artificial reviewer overhead.

Each run must contain exactly one `- verdict: pass | revise` and exactly one findings form: `- findings: none` or a bounded block containing only indented `P0`-`P3` entries. Duplicate, mixed, empty, or malformed forms fail closed.

`advance-stage.ps1` evaluates only the latest structured run, not free-form roles or text outside its bounded findings block. Latest `pass` with `P0`/`P1` and latest `revise` with `findings: none` are rejected; `pass` with only `P2`/`P3` is legal. Historical contradictions remain history when the latest run is legal.

Use relevant question-bank roles: Workflow Core Defender, Install Isolation Defender, Truth Source Defender, Provider Staleness Defender, Minimal Safe Change Defender, Experimental Provider Defender, Validator Compatibility Defender, Lazy Loading / Skill Footprint Defender, Scope Creep Defender.
