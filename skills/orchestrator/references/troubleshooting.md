# Troubleshooting

## 1. Approved Inputs Are Missing

Symptoms:

- requirement review or UI review is absent
- technical review status is unknown

Actions:

1. Do not invent missing inputs
2. Record the gap in `current-flow.md`
3. Decide whether the gap can be closed by `DELTA_SPEC`
4. If not, write `decision-needed.md`

## 2. DELTA_SPEC Is Created Too Early or Too Late

Symptoms:

- `spec.md` appears even though approved inputs are already sufficient
- plan drafting starts without enough boundary information

Actions:

1. Re-evaluate approved inputs against plan requirements
2. Use `spec.md` only for development-boundary deltas
3. Keep `spec.md` out of the default stage chain

## 3. Legacy DONE Still Appears in New Writes

Symptoms:

- freshly written `current-flow.md` or `handoff.md` uses `DONE`

Actions:

1. Treat as migration regression
2. Repair the affected markdown immediately
3. Re-run the health gate before continuing

## 4. Shared Runtime Drift

Symptoms:

- `.assistant/orchestration/current-flow.md` exists, but `运行时/当前任务.md` or `运行时/tasks/<task-id>.md` is missing
- the health gate returns `WARN` or `FAIL`

Actions:

1. Repair shared runtime pointer files
2. Confirm `current-flow.md` still points to the real workspace docs through `artifact_root` and explicit artifact paths
3. Re-run `..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath <absolute-path-to-current-flow.md>` until it returns `STATUS: PASS`

## 5. Mirror Sync Looks Complete but Drift Remains

Symptoms:

- only one or two files were compared after D2
- downstream runner still behaves with old semantics

Actions:

1. Re-run the full mirror matrix, not a single-file check
2. Verify all required groups:
   - `using-superpowers`
   - `orchestrator + references`
   - `spec/plan`
   - `implement/review/test`
3. Treat any mismatch as a blocker

## 6. Mojibake Appears in Markdown

Symptoms:

- Chinese text appears garbled
- replacement characters appear in freshly written files

Actions:

1. Re-read the source with explicit UTF-8
2. Repair the damaged markdown before any further handoff
3. Re-run the health gate

## 7. Artifact Contract Drift

Symptoms:

- gate check says an artifact should be usable, but the markdown is missing required meta or sections
- `handoff.md` or `test.md` exists, but downstream cannot safely consume it

Actions:

1. Run `scripts/validate-harness-artifacts.ps1 -CurrentFlowPath <absolute-path-to-current-flow.md>`
2. Repair the artifact named in the validator output
3. Re-run the validator until it returns `STATUS: PASS`
