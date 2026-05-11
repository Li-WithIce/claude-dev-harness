---
task_id: md-html-fixture
stage: PLAN
tool: codex
updated: 2026-05-11
---

# Review HTML Fixture

This fixture exercises the paired reading renderer with headings, decisions, a table, code, lists, and blockquotes.

## Context

The Markdown document remains the canonical source of truth. The generated HTML is only a reading artifact.

## Decisions

Reviewers need fast access to the decisions that shape the implementation.

| Decision | Rationale | Owner |
|---|---|---|
| Keep Markdown canonical | Avoids two editable sources | Entry agent |
| Generate fixed HTML | Makes long reviews easier | Renderer |

## Risks

| Risk | Level | Impact | Mitigation |
|---|---|---|---|
| Generated artifacts can drift | High | Reviewers trust stale HTML | Regenerate from Markdown |
| Wide tables are hard to inspect | Medium | Decisions are missed | Use visual risk cards |

## Verification

The renderer must produce deterministic output and preserve code language classes.

```powershell
pwsh -File .\scripts\render-review-html.ps1 -Source .\docs\tasks\demo\spec.md
```

## Handoff

The next reviewer should inspect the generated table and anchor links.

## Appendix A

Additional section for table of contents depth.

### Detail A1

The table of contents should include third-level headings.

## Appendix B

Additional section for stable H2 section wrappers.

## Appendix C

> The HTML reading version must not replace the source Markdown.
