# Minimal Safe Change Policy

## Ladder

1. Skip what does not need to exist.
2. Reuse existing repo patterns.
3. Use stdlib/native features.
4. Use already-installed dependencies.
5. Prefer one line when it is correct.
6. Write only the minimum code that works.

## Safety Floor

Do not simplify away validation, security, data-loss protection, accessibility, error handling, root-cause fixes, or required verification.

## Evidence

If a shortcut has a known ceiling, record it in Implementation Notes `- risks:` or `- next:`.
