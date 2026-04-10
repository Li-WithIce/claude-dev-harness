function Resolve-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Find-ParentDirectoryNamed {
    param(
        [string]$StartPath,
        [string]$DirectoryName
    )

    if ([string]::IsNullOrWhiteSpace($StartPath) -or [string]::IsNullOrWhiteSpace($DirectoryName)) {
        return $null
    }

    $current = Resolve-NormalizedPath -Path $StartPath
    if ([string]::IsNullOrWhiteSpace($current)) {
        return $null
    }

    if (Test-Path -LiteralPath $current -PathType Leaf) {
        $current = Split-Path -Parent $current
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ((Split-Path -Leaf $current) -ieq $DirectoryName) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }

        $current = $parent
    }

    return $null
}

function Get-FlowSharedVaultRoot {
    param([string]$OrchestratorFlowPath)

    if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -or -not (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
        return $null
    }

    $match = Select-String -Path $OrchestratorFlowPath -Pattern '^shared_vault_root:\s*(.+)$' -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    $value = $match.Matches[0].Groups[1].Value.Trim()
    if (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'")) -or
        ($value.StartsWith('`') -and $value.EndsWith('`'))
    ) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    return Resolve-NormalizedPath -Path $value
}

function Resolve-SharedMemoryVaultRoot {
    param(
        [string]$VaultRoot = "",
        [string]$OrchestratorFlowPath = "",
        [string]$WorkspaceRoot = ""
    )

    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-Candidate {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $normalized = Resolve-NormalizedPath -Path $Value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            return
        }

        if ($candidateSet.Add($normalized)) {
            $candidates.Add($normalized)
        }
    }

    Add-Candidate -Value $VaultRoot
    Add-Candidate -Value $env:CLAUDE_DEV_HARNESS_VAULT_PATH
    Add-Candidate -Value $env:OBSIDIAN_SHARED_VAULT

    $flowSharedVaultRoot = Get-FlowSharedVaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
    Add-Candidate -Value $flowSharedVaultRoot

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Add-Candidate -Value (Join-Path $WorkspaceRoot '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT)) {
        Add-Candidate -Value (Join-Path $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSPACE_ROOT)) {
        Add-Candidate -Value (Join-Path $env:WORKSPACE_ROOT '.assistant')
    }

    $flowVaultRoot = Find-ParentDirectoryNamed -StartPath $OrchestratorFlowPath -DirectoryName '.assistant'
    Add-Candidate -Value $flowVaultRoot

    try {
        $cwdVaultRoot = Find-ParentDirectoryNamed -StartPath (Get-Location).Path -DirectoryName '.assistant'
        Add-Candidate -Value $cwdVaultRoot
        Add-Candidate -Value (Join-Path (Get-Location).Path '.assistant')
    } catch {
        # Ignore location resolution failures.
    }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    throw 'Unable to resolve shared memory vault root. Pass -VaultRoot, set CLAUDE_DEV_HARNESS_VAULT_PATH, or provide -OrchestratorFlowPath.'
}

function Get-DefaultAgentRoots {
    $candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-AgentRoot {
        param([string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $normalized = Resolve-NormalizedPath -Path $Value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            return
        }

        if ($candidateSet.Add($normalized)) {
            $candidates.Add($normalized)
        }
    }

    Add-AgentRoot -Value $env:CLAUDE_HOME
    Add-AgentRoot -Value $env:CODEX_HOME
    Add-AgentRoot -Value $env:GEMINI_HOME

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-AgentRoot -Value (Join-Path $env:USERPROFILE '.claude')
        Add-AgentRoot -Value (Join-Path $env:USERPROFILE '.codex')
        Add-AgentRoot -Value (Join-Path $env:USERPROFILE '.gemini')
    }

    return @($candidates)
}
