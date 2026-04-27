function Resolve-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $normalizedPath = Resolve-NormalizedPath -Path $Path
    $normalizedRoot = Resolve-NormalizedPath -Path $Root
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return $false
    }

    $trimmedPath = $normalizedPath.TrimEnd('\', '/')
    $trimmedRoot = $normalizedRoot.TrimEnd('\', '/')
    return $trimmedPath.Equals($trimmedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $trimmedPath.StartsWith(($trimmedRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)
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

function Get-FlowWorkspaceVaultRoot {
    param([string]$OrchestratorFlowPath)

    if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -or -not (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
        return $null
    }

    $flowDirectory = Split-Path -Parent (Resolve-NormalizedPath -Path $OrchestratorFlowPath)
    if ([string]::IsNullOrWhiteSpace($flowDirectory)) {
        return $null
    }

    $assistantDirectory = Split-Path -Parent $flowDirectory
    if ((Split-Path -Leaf $flowDirectory) -ieq 'orchestration' -and (Split-Path -Leaf $assistantDirectory) -ieq '.assistant') {
        return $assistantDirectory
    }

    return $null
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

function Assert-ProjectLocalVault {
    param([string]$VaultRoot)

    $normalizedVaultRoot = Resolve-NormalizedPath -Path $VaultRoot
    if ([string]::IsNullOrWhiteSpace($normalizedVaultRoot)) {
        return $normalizedVaultRoot
    }

    $runtimeDirectory = Join-Path $normalizedVaultRoot '运行时'
    if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
        return $normalizedVaultRoot
    }

    foreach ($agentRoot in Get-DefaultAgentRoots) {
        if (Test-PathUnderRoot -Path $normalizedVaultRoot -Root $agentRoot) {
            throw "[vault-layer-violation] user-level agent home cannot host runtime layer: $normalizedVaultRoot"
        }
    }

    return $normalizedVaultRoot
}

function Resolve-SharedMemoryVaultRoot {
    param(
        [string]$VaultRoot = "",
        [string]$OrchestratorFlowPath = "",
        [string]$WorkspaceRoot = ""
    )

    function New-CandidateBucket {
        return [pscustomobject]@{
            Set   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Items = [System.Collections.Generic.List[string]]::new()
        }
    }

    function Add-CandidateToBucket {
        param(
            [pscustomobject]$Bucket,
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $normalized = Resolve-NormalizedPath -Path $Value
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            return
        }

        if ($Bucket.Set.Add($normalized)) {
            $Bucket.Items.Add($normalized)
        }
    }

    $tierA = New-CandidateBucket
    $tierB = New-CandidateBucket
    $fallback = New-CandidateBucket

    Add-CandidateToBucket -Bucket $tierA -Value $VaultRoot
    Add-CandidateToBucket -Bucket $tierA -Value $env:CLAUDE_DEV_HARNESS_VAULT_PATH
    Add-CandidateToBucket -Bucket $tierA -Value $env:OBSIDIAN_SHARED_VAULT
    Add-CandidateToBucket -Bucket $tierA -Value (Get-FlowSharedVaultRoot -OrchestratorFlowPath $OrchestratorFlowPath)

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $WorkspaceRoot '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSPACE_ROOT)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $env:WORKSPACE_ROOT '.assistant')
    }
    Add-CandidateToBucket -Bucket $tierB -Value (Get-FlowWorkspaceVaultRoot -OrchestratorFlowPath $OrchestratorFlowPath)

    try {
        Add-CandidateToBucket -Bucket $fallback -Value (Join-Path (Get-Location).Path '.assistant')
        Add-CandidateToBucket -Bucket $fallback -Value (Find-ParentDirectoryNamed -StartPath (Get-Location).Path -DirectoryName '.assistant')
    } catch {
        # Ignore location resolution failures.
    }

    if ($tierA.Items.Count -gt 1) {
        $uniqueTierA = @($tierA.Items | Sort-Object -Unique)
        if ($uniqueTierA.Count -gt 1) {
            [Console]::Error.WriteLine(
                "[vault-ambiguous] multiple explicit shared-memory vault candidates resolved; using {0} (others: {1})" -f
                $tierA.Items[0],
                (($uniqueTierA | Select-Object -Skip 1) -join ', ')
            )
        }
    }

    if ($tierA.Items.Count -gt 0) {
        return $tierA.Items[0]
    }

    if ($tierB.Items.Count -gt 0) {
        return $tierB.Items[0]
    }

    if ($fallback.Items.Count -gt 0) {
        return $fallback.Items[0]
    }

    throw 'Unable to resolve shared memory vault root. Pass -VaultRoot, set CLAUDE_DEV_HARNESS_VAULT_PATH, or provide -OrchestratorFlowPath.'
}
