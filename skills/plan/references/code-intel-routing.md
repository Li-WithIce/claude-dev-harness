# Code Intel Routing

Use optional code-intel only when it reduces real uncertainty in PLAN.

## Allowed

- identify candidate affected paths
- inspect callers/dependencies
- suggest simpler implementation routes

## Required Grounding

Every provider hint must be checked against current repo files before it becomes a Plan TODO, Verification command, or Risk.

## Fallback

If code-intel is unavailable, stale, or conflicting, use `rg`/Read/manual inspection.
