# IMPLEMENT Code Intel Routing

Sequence:

1. Read plan/read_first.
2. Use provider hints only when helpful.
3. Read current files before editing.
4. Make the minimal safe change.
5. Record provider grounding in `- risks:` or `- next:` when it matters.

Provider unavailable or stale means use `rg`/Read. Provider output must not decide TEST, review verdict, or stage.
