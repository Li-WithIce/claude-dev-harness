# Thin Harness v2 behavior evaluation

`tests/evals/core-scenarios.json` is the canonical PR-core behavior dataset. It contains twenty semantic cases and multiple paraphrases per case. The evaluator never matches those phrases; it executes the current policy, requirement, protocol, approval, and schema surfaces and compares observable routing, Ask, side-effect, capability, and completion decisions.

Run the deterministic suite with:

```powershell
pwsh -NoProfile -NonInteractive -File .\tests\run-scenario-evals.ps1 -RepoRoot $PWD -Suite core
```

The JSON report keeps measurement status explicit. Repository policy and schema outcomes are `measured`. External model execution is `unavailable` and informational because core CI neither requires credentials nor calls an external provider. A failed or unavailable required deterministic case makes behavior eligibility fail and returns a non-zero exit code.

The required safety counters are `missed_ask`, `critical_missed_ask`, `unnecessary_ask`, `read_only_write`, and `false_pass`. Eligibility requires every case to be measured and passing, with zero critical missed Ask, read-only writes, and false passes.

Release qualification adds a separate real model layer; it does not replace or relabel the deterministic suite:

```powershell
$releaseRoot = Join-Path $PWD '.assistant\运行时\release-qualification'

pwsh -NoProfile -NonInteractive -File .\scripts\run-model-evals.ps1 `
  -RepoRoot $PWD `
  -Model gpt-5.6-sol `
  -Reasoning max `
  -CodexHome $env:HOST_BENCHMARK_CODEX_HOME `
  -OutputPath (Join-Path $releaseRoot 'model-eval.json')
```

Every paraphrase runs in a new isolated workspace and a fresh ephemeral, read-only, single-subject Codex session. The response is schema-constrained; the report stores only case/variant identity, paraphrase digest, semantic decisions, zero-write observation, aggregate timing/turn/tool/token telemetry, and source digests. It never stores the complete prompt, command text, thread id, credential, Codex-home path, or private absolute path. Invocation failure is `unavailable` and returns nonzero; it cannot become measured or pass. Release hard gates require `critical_missed_ask=0`, `read_only_write=0`, `false_pass=0`, and `product_inference_violation=0`, while `unnecessary_ask` is always reported.

The performance layer is a separate real host run:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\run-host-benchmark.ps1 `
  -RepoRoot $PWD `
  -Model gpt-5.6-sol `
  -Reasoning max `
  -CodexHome $env:HOST_BENCHMARK_CODEX_HOME `
  -Groups 3 `
  -Trials 3 `
  -OutputPath (Join-Path $releaseRoot 'host-benchmark.json')
```

Both real runners require the same dedicated, independently logged-in Codex home. Authentication is prepared outside the repository; credentials must not be copied into a dataset, workflow input, source file, or uploaded artifact. Missing or rejected authentication remains `unavailable` and makes rollout ineligible.

CI has three layers:

- PR core runs deterministic core contracts, behavior evaluation, routing verification, and a core install/update/uninstall smoke test.
- changed optional selects Memory, Team, md-html, Codex adapter, or Provider boundary tests only when their paths change. A change to the routing or installation surfaces selects every optional group fail closed.
- release qualification checks out full history in sequential model and host producer jobs, bounds model calls at 120 seconds and host calls at the evidence-backed 900 seconds, and requires at most one fixed JSON from each. Every job uses a fresh run-id/attempt/job-specific directory and refuses a pre-existing target. A `release-full` aggregation job uses `needs` with `!cancelled()` to download whichever reports exist, run the rollout generator plus monolithic v1/v2 and core/full rollback gates, and upload only the two inputs and `v2-rollout-eligibility.json`; a missing or unavailable real report cannot produce a successful release. It runs only the three allowlisted refs on protected-branch pushes, the nightly schedule, or manual dispatch; model, host, and aggregate budgets are 120, 180, and 120 minutes. All jobs bind `thin-v2-release` and do not persist checkout credentials. Repository/org-level variable `THIN_V2_RELEASE_RUNNER` selects the isolated credentialed producer account, while separate repository/org-level variable `THIN_V2_RELEASE_AGGREGATOR_RUNNER` selects an unlogged, credential-blind OS account; neither selector may be environment-level. `HOST_BENCHMARK_CODEX_HOME` supplies only the producer account's non-secret dedicated-home path, never credential contents. Both runners carry no unrelated secrets/workloads and provide PowerShell 7.3+, Git, and the exact Codex CLI/service `0.144.4` required by the OTel evidence contract.

`scripts/benchmark-harness.ps1` reports local fixture replay separately from Direct host latency. Fixture replay is a measured diagnostic proxy and is never consumed as release host evidence. Likewise, deterministic `tests/run-scenario-evals.ps1` does not stand in for the 40 real Codex sessions. Missing, simulated, dirty, stale, or failed real evidence makes eligibility false; it must not be presented as a pass.
