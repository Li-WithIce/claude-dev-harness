# Adversarial Review Gate

Before IMPLEMENT, record adversarial rounds in `## Plan Review`.

This is currently a human/process gate. Validators check that the gate contract exists and is referenced; they do not parse free-form rounds or block `PLAN_REVIEW -> IMPLEMENT` by counting roles. `advance-stage.ps1` continues to rely on the latest `- verdict:` only. A later advisory/strict parser can be added when the record shape is stable.

Required final-release roles:

1. Workflow Core Defender
2. Install Isolation Defender
3. Truth Source Defender
4. Provider Staleness Defender
5. Minimal Safe Change Defender
6. Experimental Provider Defender
7. Validator Compatibility Defender
8. Lazy Loading / Skill Footprint Defender
9. Scope Creep Defender

Blocking findings must be mitigated; the task must not advance while blocking findings are open.
