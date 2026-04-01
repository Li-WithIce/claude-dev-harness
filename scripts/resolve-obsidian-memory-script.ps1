$sharedPathsHelper = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1'
if (Test-Path -LiteralPath $sharedPathsHelper) {
    . $sharedPathsHelper
}

function Resolve-ObsidianMemoryScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidates = @(
        (Join-Path $repoRoot ("skills\obsidian-memory\scripts\{0}" -f $ScriptName))
    )

    $agentRoots = if (Get-Command Get-DefaultAgentRoots -ErrorAction SilentlyContinue) {
        Get-DefaultAgentRoots
    } else {
        @(
            (Join-Path $env:USERPROFILE '.claude'),
            (Join-Path $env:USERPROFILE '.codex'),
            (Join-Path $env:USERPROFILE '.gemini')
        )
    }

    foreach ($agentRoot in $agentRoots) {
        if ([string]::IsNullOrWhiteSpace($agentRoot)) {
            continue
        }

        $candidates += Join-Path $agentRoot ("skills\obsidian-memory\scripts\{0}" -f $ScriptName)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Missing obsidian-memory script in repo or configured agent homes: $ScriptName"
}
