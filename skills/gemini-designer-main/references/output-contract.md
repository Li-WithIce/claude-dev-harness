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

`## Conclusion` must contain exactly one verdict word: `pass`, `fail`, or `blocked`.

## Invalid Output Conditions

Treat Gemini output as insufficient for TEST gate if any of the following is true:

- API access failed
- Output is not a valid markdown test report
- Required sections are missing
- `Conclusion` is missing or not one of `pass / fail / blocked`
- Findings are clearly not grounded in the provided inputs

If any invalid-output condition is met, do not use Gemini output as the sole TEST gate basis. Return to orchestrator and follow the current tool profile's fallback policy.
