# Changelog

## Unreleased

- Add fail-closed canonical v2 rollout discovery and an explicit offline promotion command that preserves v1 artifact precedence and rollback.
- Keep `.assistant/` as local user/workspace state and remove tracked vault/runtime files from the repository surface.
- Keep provider integrations optional/advisory and out of default install/validation paths.
- Remove the required Node.js command dependency from the harness installation path.
- Add Windows quick/core validation in GitHub Actions.
- Harden workflow descriptor validation for stage order, required fields, and provider-like stage/skill drift.
- Add governance documents for contribution, security reporting, and pull request review.
