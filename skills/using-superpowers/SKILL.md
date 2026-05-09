---
name: using-superpowers
description: Legacy compatibility alias for the canonical entry-router skill. Use only for older explicit /using-superpowers calls; immediately load entry-router.
---

# using-superpowers Legacy Alias

`using-superpowers` is retained only as a compatibility wrapper for older explicit invocations.
The canonical entry skill is `entry-router` at `../entry-router/SKILL.md`.

When this skill is invoked:

1. Stop using this file as the source of routing rules.
2. Load or invoke `/entry-router`.
3. Follow the current `entry-router` instructions for shared memory, task routing, lazy loading, and harness-lite workflow behavior.

Do not copy `entry-router` rules back into this file. Do not add this alias to `agent-configs/workflows/harness-lite.yaml`, default profiles, role prompts, team presets, skill manifests, or skills-index outputs.

This alias may remain in Codex managed config only as a disabled legacy explicit compatibility path.
