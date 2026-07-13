$sharedPathsHelper = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1'
if (Test-Path -LiteralPath $sharedPathsHelper) {
    . $sharedPathsHelper
}

$script:RuntimeTouchingScripts = @(
    'append-runtime-inbox.ps1',
    'triage-runtime-inbox.ps1',
    'repair-shared-memory.ps1',
    'archive-memory-candidates.ps1',
    'maintain-shared-memory.ps1',
    'run-memory-health.ps1',
    'write-memory-health-report.ps1'
)

function Resolve-ObsidianMemoryScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $repoCandidate = Join-Path $repoRoot ("skills\obsidian-memory\scripts\{0}" -f $ScriptName)
    if (Test-Path -LiteralPath $repoCandidate) {
        return $repoCandidate
    }

    $isRuntimeTouching = $ScriptName -in $script:RuntimeTouchingScripts
    $allowAgentHomeFallback = $env:DEV_HARNESS_ALLOW_AGENT_HOME -eq '1' -or $env:CLAUDE_DEV_HARNESS_ALLOW_AGENT_HOME -eq '1'
    if ($isRuntimeTouching -and -not $allowAgentHomeFallback) {
        throw "Missing obsidian-memory script in repo (agent-home fallback disabled for runtime-touching scripts): $ScriptName"
    }

    $agentRoots = if (Get-Command Get-DefaultAgentRoots -ErrorAction SilentlyContinue) {
        Get-DefaultAgentRoots
    } else {
        @(
            (Join-Path $env:USERPROFILE '.claude'),
            (Join-Path $env:USERPROFILE '.codex')
        )
    }

    foreach ($agentRoot in $agentRoots) {
        if ([string]::IsNullOrWhiteSpace($agentRoot)) {
            continue
        }

        $candidate = Join-Path $agentRoot ("skills\obsidian-memory\scripts\{0}" -f $ScriptName)
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Missing obsidian-memory script in repo or configured agent homes: $ScriptName"
}
