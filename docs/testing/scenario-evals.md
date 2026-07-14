# Thin Harness v2 behavior evaluation

`tests/evals/core-scenarios.json` is the canonical PR-core behavior dataset. It contains twenty semantic cases and multiple paraphrases per case. The evaluator never matches those phrases; it executes the current policy, requirement, protocol, approval, and schema surfaces and compares observable routing, Ask, side-effect, capability, and completion decisions.

Run the deterministic suite with:

```powershell
pwsh -NoProfile -NonInteractive -File .\tests\run-scenario-evals.ps1 -RepoRoot $PWD -Suite core
```

The JSON report keeps measurement status explicit. Repository policy and schema outcomes are `measured`. External model execution is `unavailable` and informational because core CI neither requires credentials nor calls an external provider. A failed or unavailable required deterministic case makes behavior eligibility fail and returns a non-zero exit code.

The required safety counters are `missed_ask`, `critical_missed_ask`, `unnecessary_ask`, `read_only_write`, and `false_pass`. Eligibility requires every case to be measured and passing, with zero critical missed Ask, read-only writes, and false passes.

CI has three layers:

- PR core runs deterministic core contracts, behavior evaluation, routing verification, and a core install/update/uninstall smoke test.
- changed optional selects Memory, Team, md-html, Codex adapter, or Provider boundary tests only when their paths change. A change to the routing or installation surfaces selects every optional group fail closed.
- release full runs the monolithic v1/v2 validation entry, core and full installation rollback, behavior evaluation, and the bare/v1/v2 benchmark. It runs on protected-branch pushes, a nightly schedule, and manual dispatch.

`scripts/benchmark-harness.ps1` reports local fixture replay separately from Direct host latency. Fixture replay is a measured diagnostic proxy and is never treated as host latency. Missing, simulated, or failed Direct latency evidence makes performance eligibility false; it must not be presented as a pass.
