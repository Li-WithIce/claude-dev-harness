function Resolve-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

if (-not (Get-Command -Name Assert-CanonicalRuntimeVaultRoot -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'runtime-state-common.ps1')
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

        $childDirectory = Join-Path $current $DirectoryName
        if (Test-Path -LiteralPath $childDirectory -PathType Container) {
            return (Resolve-NormalizedPath -Path $childDirectory)
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

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-AgentRoot -Value (Join-Path $env:USERPROFILE '.claude')
        Add-AgentRoot -Value (Join-Path $env:USERPROFILE '.codex')
    }

    return @($candidates)
}

function Assert-ProjectLocalVault {
    param([string]$VaultRoot)

    return Assert-CanonicalRuntimeVaultRoot -VaultRoot $VaultRoot -AgentRoots (Get-DefaultAgentRoots)
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

    $explicitVaultRoot = Resolve-NormalizedPath -Path $VaultRoot
    $explicitWorkspaceVaultRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        ''
    } else {
        Resolve-NormalizedPath -Path (Join-Path $WorkspaceRoot '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($explicitVaultRoot) -and
        -not [string]::IsNullOrWhiteSpace($explicitWorkspaceVaultRoot) -and
        -not $explicitVaultRoot.Equals($explicitWorkspaceVaultRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Explicit VaultRoot and WorkspaceRoot disagree: vault=$explicitVaultRoot workspace=$WorkspaceRoot"
    }
    if (-not [string]::IsNullOrWhiteSpace($explicitVaultRoot)) {
        return (Assert-ProjectLocalVault -VaultRoot $explicitVaultRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($explicitWorkspaceVaultRoot)) {
        return (Assert-ProjectLocalVault -VaultRoot $explicitWorkspaceVaultRoot)
    }

    $tierA = New-CandidateBucket
    $tierB = New-CandidateBucket
    $fallback = New-CandidateBucket

    Add-CandidateToBucket -Bucket $tierA -Value $env:DEV_HARNESS_VAULT_PATH
    Add-CandidateToBucket -Bucket $tierA -Value $env:CLAUDE_DEV_HARNESS_VAULT_PATH
    Add-CandidateToBucket -Bucket $tierA -Value $env:OBSIDIAN_SHARED_VAULT
    Add-CandidateToBucket -Bucket $tierA -Value (Get-FlowSharedVaultRoot -OrchestratorFlowPath $OrchestratorFlowPath)

    if (-not [string]::IsNullOrWhiteSpace($env:DEV_HARNESS_WORKSPACE_ROOT)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $env:DEV_HARNESS_WORKSPACE_ROOT '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT '.assistant')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSPACE_ROOT)) {
        Add-CandidateToBucket -Bucket $tierB -Value (Join-Path $env:WORKSPACE_ROOT '.assistant')
    }
    Add-CandidateToBucket -Bucket $tierB -Value (Get-FlowWorkspaceVaultRoot -OrchestratorFlowPath $OrchestratorFlowPath)

    try {
        $locationVault = Join-Path (Get-Location).Path '.assistant'
        if (Test-Path -LiteralPath $locationVault -PathType Container) {
            Add-CandidateToBucket -Bucket $fallback -Value $locationVault
        }
        Add-CandidateToBucket -Bucket $fallback -Value (Find-ParentDirectoryNamed -StartPath (Get-Location).Path -DirectoryName '.assistant')
    } catch {
        # Ignore location resolution failures.
    }

    foreach ($tier in @(
            [pscustomobject]@{ Name = 'vault'; Bucket = $tierA },
            [pscustomobject]@{ Name = 'workspace'; Bucket = $tierB }
        )) {
        $uniqueCandidates = @($tier.Bucket.Items | Sort-Object -Unique)
        if ($uniqueCandidates.Count -gt 1) {
            throw ("[vault-ambiguous] conflicting {0} candidates: {1}" -f $tier.Name, ($uniqueCandidates -join ', '))
        }
    }

    if ($tierA.Items.Count -gt 0 -and
        $tierB.Items.Count -gt 0 -and
        -not $tierA.Items[0].Equals($tierB.Items[0], [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("[vault-ambiguous] vault and workspace candidates disagree: vault={0}, workspace={1}" -f $tierA.Items[0], $tierB.Items[0])
    }

    if ($tierA.Items.Count -gt 0 -and
        $tierB.Items.Count -eq 0 -and
        $fallback.Items.Count -gt 0 -and
        -not $tierA.Items[0].Equals($fallback.Items[0], [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("[vault-ambiguous] vault and cwd workspace candidates disagree: vault={0}, workspace={1}" -f $tierA.Items[0], $fallback.Items[0])
    }

    if ($tierA.Items.Count -gt 0) {
        return (Assert-ProjectLocalVault -VaultRoot $tierA.Items[0])
    }

    if ($tierB.Items.Count -gt 0) {
        return (Assert-ProjectLocalVault -VaultRoot $tierB.Items[0])
    }

    if ($fallback.Items.Count -gt 0) {
        return (Assert-ProjectLocalVault -VaultRoot $fallback.Items[0])
    }

    throw 'Unable to resolve shared memory vault root. Pass -VaultRoot, set DEV_HARNESS_VAULT_PATH, or provide -OrchestratorFlowPath.'
}
