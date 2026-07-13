# Stage Discipline Matrix

## Purpose

This matrix defines thinking disciplines for each route and workflow stage. It helps agents reason consistently while preserving the canonical harness-lite workflow.

It does not add workflow stages, frontmatter fields, schema, provider requirements, or hard validation gates.

## Canonical Workflow Reminder

```text
PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST
```

- `quick` is a lightweight route, not a stage.
- `ask` is an iterative blocking clarification route, not a stage.
- `DONE` is a frontmatter terminal state, not an executable stage.
- Handoff is a TEST/DONE communication discipline, not a stage.

## Entry / Ask - Socratic Blocking Clarification

Discipline:
- First understand whether this is `resume-current`, `switch-existing`, `inbox-first`, or `new-task`.
- For `new-task`, classify `quick`, `workflow`, or `ask`.
- Ask is an iterative blocking clarification gate.
- Ask one highest-value clarification question at a time by default.
- Remain in ask until blocking uncertainty is resolved.
- Do not create task artifacts, modify code, initialize providers, or enter PLAN while blocking requirements are unresolved.
- Reassess after every user answer.
- When clear, route to `quick` or `workflow`.

Core question: "Do I truly understand the user's goal, acceptance criteria, scope, risk, and expected output well enough to act safely?"

## Quick - Smallest Reversible Action

Discipline:
- Pure read-only work uses quick when target, scope, and output are clear; high-risk code or production areas increase evidence depth but do not grant workflow artifact or write authority.
- For mutation, use quick only when scope and acceptance are clear, risk is low, and focused verification is possible.
- Do the smallest safe change or check.
- Do not create `docs/tasks/{task_id}/`.
- Do not use workflow frontmatter stages.
- Do not introduce new abstractions, dependencies, or opportunistic refactors.
- If read-only target/scope/output becomes unclear, route to `ask`; if mutation scope or risk expands, stop and route to `ask` or `workflow`.
- Report changed files and verification.

Core question: "Can this be completed safely and reversibly in the current conversation?"

## PLAN - Diverge, Resolve, Reduce, Update

Discipline:
- Osborn: consider plausible approaches before locking onto one.
- Hegel: identify tensions, constraints, and tradeoffs.
- First Principles: reduce the problem to goals, invariants, and root causes.
- Occam: choose the smallest plan that satisfies acceptance and safety constraints.
- Bayes: treat the plan as a hypothesis that can be updated by evidence.

Core question: "What is the smallest plan that satisfies the true goal and respects the hard constraints?"

## PLAN_REVIEW - Coherence + Evidence Review

Discipline:
- Check whether the plan is internally consistent.
- Identify unproven assumptions.
- Verify blocking decisions are resolved or explicitly pending.
- Check affected paths, risks, rollback, and verification are credible.
- Reject plans that cannot guide safe implementation.

Core question: "Is this plan coherent, evidence-backed, and safe enough to implement?"

## IMPLEMENT - Minimal Safe Change / Root-Cause Discipline

Discipline:
- Implement the approved plan, not adjacent ideas.
- Prefer existing helpers, patterns, and standard library capabilities.
- Fix root causes, not symptoms.
- Avoid opportunistic refactors.
- Avoid new concepts or dependencies unless justified by the plan.
- Keep diffs small, local, and verifiable.
- If the plan is wrong or incomplete, stop and return to review/planning rather than improvising.

Core question: "Am I making the smallest safe root-cause change that satisfies the plan?"

## CODE_REVIEW - Adversarial Feynman Review

Discipline:
- Try to disprove the patch before accepting it.
- Explain the change simply enough to expose hidden assumptions.
- Construct counterexamples and worst-case paths.
- Check root cause, scope, regression risk, provider misuse, unnecessary abstraction, and missing validation.
- Do not reject useful work on unsupported taste alone.
- Preserve value when asking for revise.

Core question: "Can I break this change, and can I explain why it should still be trusted?"

## TEST - Bayesian Evidence Closure

Discipline:
- Treat PLAN and IMPLEMENT as hypotheses.
- Use real commands, outputs, inspections, or documented constraints as evidence.
- Do not claim pass without evidence.
- Record unverified areas as gaps or risks.
- Update conclusion to `pass`, `fail`, or `blocked` based on evidence.
- Provider output may help choose scope but never replaces test evidence.

Core question: "What evidence changes my belief that this work is correct?"

## Handoff / DONE - Future Maintainer Clarity

Discipline:
- Explain what changed.
- Explain what was verified.
- Explain what was not verified.
- Explain remaining risks and follow-ups.
- Do not disguise unfinished work as done.
- DONE remains frontmatter terminal state only.

Core question: "Can a future maintainer understand what happened, why, how to verify it, and what remains?"

## Guardrails

- This matrix does not add stages.
- This matrix does not change stage advancement.
- This matrix does not create new hard validator gates.
- This matrix does not add frontmatter fields.
- Provider tools remain opt-in and advisory.
- `.assistant/` remains local-only.
- `quick` / `workflow` / `ask` routing remains authoritative.
