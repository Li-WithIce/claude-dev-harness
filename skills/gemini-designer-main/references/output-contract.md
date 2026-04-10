# Output Contract

Gemini output must include:

- `# Test Report`
- `## Summary`
- `## Scope`
- `## Inputs Reviewed`
- `## Test Approach`
- `## Findings`
- `## Risks / Gaps`
- `## Conclusion`
- `## Handoff`

`## Conclusion` must contain exactly one verdict word on the first non-empty line: `pass`, `fail`, or `blocked`.

## Invalid Output Conditions

Treat Gemini output as insufficient for TEST gate if any of the following is true:

- API access failed
- Output is not a valid markdown test report
- Required sections are missing
- `Conclusion` is missing or not one of `pass / fail / blocked`
- `Handoff` is missing
- Findings are clearly not grounded in the provided inputs
