# Minimal Safe Change Policy

Minimal Safe Change means the smallest change that satisfies the accepted plan and preserves safety.

## Ladder

1. Does this need to exist at all?
2. Is there already a repo helper, pattern, type, or doc surface?
3. Does stdlib or native platform cover it?
4. Does an already-installed dependency solve it?
5. Can it be one line?
6. Only then write the minimum code that works.

## Never Simplify Away

- trust-boundary validation
- security checks
- data-loss protection
- accessibility
- error handling that prevents silent corruption
- root-cause fix
- required verification

## Root Cause Rule

One root-cause guard in a shared path beats repeated guards in sibling callers. A symptom patch is not a minimal safe change when a shared cause is visible.

## Implementation Rule

IMPLEMENT records any deliberate simplification in `- risks:` or `- next:` when the ceiling matters. No new abstraction, dependency, config, or adjacent refactor unless the plan explicitly needs it.

## Review Rule

CODE_REVIEW checks both overengineering and underengineering. Less code is not acceptable if it skips verification, safety, error handling, or the accepted root-cause constraint.
