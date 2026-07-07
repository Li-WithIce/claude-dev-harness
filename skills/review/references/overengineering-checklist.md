# Overengineering Checklist

## Delete Or Avoid

- new dependency for a small local rule
- interface with one implementation
- factory for one product
- config for a value that never changes
- speculative provider skill split
- adjacent refactor outside the plan

## Underengineering Check

Minimal code is wrong if it skips validation, security, data-loss protection, accessibility, error handling, root-cause fix, or required verification.
