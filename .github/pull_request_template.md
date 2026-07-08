## Summary
-

## Workflow Impact
-

## Files Changed
-

## Validation Run

- [ ] `pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite quick`
- [ ] `pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite core`

## Provider Impact
-

## Install / Uninstall Impact
-

## Risks / Rollback
-

## Checklist

- [ ] `.assistant/` and `docs/tasks/<task-id>/` local artifacts are not committed.
- [ ] Provider integrations remain optional/advisory and are not installed or connected by default.
- [ ] User-private config and runtime pointers are not modified unless explicitly required.
