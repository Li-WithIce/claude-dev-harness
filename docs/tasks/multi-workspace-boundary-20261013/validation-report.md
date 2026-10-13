# Multi-workspace boundary validation

- task_id: multi-workspace-boundary-20261013
- contract_digest: sha256:9f572e778018fc32dfe71a0f12c2bcf336108ffde5e7aeda00837d2c10be151a
- baseline: c4faeb66eaf78bc52cf69259c5207f6fe2348ac6
- detailed_record: .assistant/runtime/multi-workspace-validation-report.json
- detailed_record_digest: sha256:181c33b0aef439e9685b15b454146afc6fa3968f17a258a288f629e706e4b811

The candidate implementation is ready for exact deployment review. All 75 active owners have passing coverage from the retained initial run and complete native reruns. The initial `run-validation.ps1 -Suite all -IncludeCachedDiff` command remains **exit 1: 67 pass, 8 fail**; it is not reported as a passing Suite all invocation. Both Git diff checks passed. Fourteen archived verifiers remain `not_run`.

## Failed owners and complete reruns

| Owner | Initial result | Resolution | Native rerun |
| --- | --- | --- | --- |
| host-benchmark-qualification | exit 124, 900s timeout | retained incomplete fixture; unchanged full mode | exit 0, 934.72s, 217 checks |
| uninstall-isolation | exit 124, 360s timeout | unchanged full mode | exit 0, 424.35s, no failures |
| install-presets | exit 124, 900s timeout | retained Temp; unchanged full default mode | exit 0, 1006.20s, 442 checks |
| module-manifest-catalog | exit 1, one stale topology assertion | optional 37, core overlap 8; exact membership retained | exit 0, 38 checks |
| thin-adapters | exit 1, old LOC ceiling | measured candidate bound `<3392`; approval still pending | exit 0, 238 checks |
| v2-ci-routing | exit 1, six stale registration/count assertions | new owned verifier; exact groups, identities and archive isolation retained | exit 0, 69 checks |
| v2-policy-contracts | exit 1, schema whitelist omission | add only session-workspaces.schema.json; whitelist remains strict | exit 0, 89 checks |
| v2-readonly-zero-write | exit 1, runner-owned repository log lock | test unchanged; stop writers and log outside repository | exit 0, 10 checks |

No runner timeout budgets or boundary assertions were weakened. The original Suite all log, timeout observations and failed fixtures are retained. The final readonly test copied its log into Runtime only after the test finished. Generated module/capability catalogs match indexed inputs; TCB and Adapter inventory checks pass.

## Trust and installation scope

Focused session-workspace fixtures pass 42 checks. The existing Hook owner passes 227 checks. The Runtime closure is 31 files and 40 artifacts, measuring **3391 LOC / 37843 tokens / 11164 statement ASTs**. Proposed KTB-EX-011 adds **184 / 1670 / 481** over the baseline implementation; its exact candidate budget acceptance is pending. Baseline 3068, previous allowances, accounting, density guards and each Adapter's `<200` bound are unchanged.

The GVPP, base-service and base-front real entry protocol readbacks all exit 0, select v2 with admission enabled and report zero Runtime writes. This confirms the earlier IoT entry upgrade. The new candidate has not been installed or granted to the target session. A successful native or fixture check does not establish desktop Hook loading or a real business write.

Installation preimages retain 1358 primary and 34 supplementary records. The supplement covers four additional global configuration files, six existing shared Hook consumers and the protected dev-harness-next index/status/312 untracked-file hashes. Readback showed no pre-deployment drift. The fixed deployment plan binds both preimage digests, candidate commit/tree, normal core/full/full installation, Approval 2→3, independent DryRun, CAS registration, full installation/protocol checks and six-consumer preservation.

## Remaining gates

Exact deployment and budget approval, actual independent registration DryRun and registration, installed K1 replay and real desktop execution remain pending. Prior API DryRun exit 2 for missing architecture Approval and earlier policy/path denials remain in `.assistant/runtime/failed-writes`; no new grant, shared current pointer, business change or database permission change was made.

Shell commands retain the existing cwd-based policy path. The session grant covers file tools and direct patches only. Normal installation backups and failed evidence must be retained; rollback revokes through the new API before reverting to the baseline, which has no registration API.
