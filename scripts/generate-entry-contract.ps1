[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)

. (Join-Path $PSScriptRoot 'lib\Harness.RuntimeKernel.ps1')

$beginMarker,$endMarker = '<!-- BEGIN GENERATED ENTRY CONTRACT -->','<!-- END GENERATED ENTRY CONTRACT -->'
$sourceRelativePath = 'policies/entry-contract.md'

$resolvedRepoRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $RepoRoot
$sourceState = Read-HarnessKernelUtf8File -Path (Resolve-HarnessContainedPath -WorkspaceRoot $resolvedRepoRoot -Path $sourceRelativePath -Label 'Canonical entry contract' -MustExist File) -Label 'Canonical entry contract' -AllowBom
    Assert-HarnessKernelCondition (-not $sourceState.HasBom) "Canonical entry contract must be UTF-8 without BOM: $sourceRelativePath"
$sourceBody = ($sourceState.Text -replace "`r`n?", "`n").TrimEnd([char[]]"`r`n")
    Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace($sourceBody)) "Canonical entry contract is empty: $sourceRelativePath"
foreach ($reservedMarker in @($beginMarker, $endMarker, '<!-- source-sha256:')) {
    Assert-HarnessKernelCondition (-not $sourceBody.Contains($reservedMarker, [System.StringComparison]::Ordinal)) "Canonical entry contract contains a reserved generated marker: $reservedMarker"
}
$generatedBody = "<!-- source-sha256: $((Get-HarnessNormalizedTextSha256 -Text $sourceState.Text).Substring(7)) -->`n$sourceBody"

$plans = @()
foreach ($relativePath in @('agent-configs/workspace/AGENTS.md.template','agent-configs/claude/CLAUDE.md.template','vault-template/entry/AGENTS.md.template')) {
    $state = Read-HarnessKernelUtf8File -Path (Resolve-HarnessContainedPath -WorkspaceRoot $resolvedRepoRoot -Path $relativePath -Label 'Allowlisted entry template' -MustExist File) -Label 'Entry template' -AllowBom
    $text = $state.Text -replace "`r`n?", "`n"
    $beginMatches,$endMatches = [regex]::Matches($text,[regex]::Escape($beginMarker)),[regex]::Matches($text,[regex]::Escape($endMarker))
    Assert-HarnessKernelCondition ($beginMatches.Count -eq 1 -and $endMatches.Count -eq 1 -and $endMatches[0].Index -gt $beginMatches[0].Index) "Entry template must contain one ordered marker pair: $relativePath"

    $desiredBytes = [Text.UTF8Encoding]::new($false).GetBytes(($text.Substring(0,$beginMatches[0].Index+$beginMarker.Length) + "`n" + $generatedBody + "`n" + $text.Substring($endMatches[0].Index)).TrimEnd([char[]]"`r`n") + "`n")
    $plans += [pscustomobject]@{RelativePath = $relativePath
        OriginalBytes = $state.Bytes
        OriginalDigest = Get-HarnessSha256Bytes -Bytes $state.Bytes
        DesiredBytes = $desiredBytes
        DesiredDigest = Get-HarnessSha256Bytes -Bytes $desiredBytes
        IsCurrent = [Linq.Enumerable]::SequenceEqual[byte]($state.Bytes,$desiredBytes)}
}

$drifted = @($plans | Where-Object { -not $_.IsCurrent })
if ($Check) {
    Assert-HarnessKernelCondition (-not $drifted.Count) ("Generated entry contract drift: " + (($drifted | ForEach-Object { $_.RelativePath }) -join ', '))
    Write-Host ("STATUS: PASS ({0} allowlisted templates are current)" -f $plans.Count)
    exit 0
}

$testFailAfterReplace = [int]($env:DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE -as [int])
Assert-HarnessKernelCondition ([string]::IsNullOrWhiteSpace([string]$env:DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE) -or $testFailAfterReplace -ge 1) 'DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE must be a positive integer'

$published = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($plan in $drifted) {
        [void](Write-HarnessKernelBytesCas -WorkspaceRoot $resolvedRepoRoot -Path $plan.RelativePath -Bytes $plan.DesiredBytes -SourceDigest $plan.DesiredDigest -CurrentDigest $plan.OriginalDigest)
        $published.Add($plan)
        Assert-HarnessKernelCondition ($testFailAfterReplace -ne $published.Count) ("Injected entry-contract publish failure after {0} replacement(s)" -f $published.Count)
    }
}
catch {
    $publishFailure = $_.Exception.Message
    $rollbackFailures = [System.Collections.Generic.List[string]]::new()
    for ($index = $published.Count - 1; $index -ge 0; $index--) {
        $plan = $published[$index]
        try {
            [void](Write-HarnessKernelBytesCas -WorkspaceRoot $resolvedRepoRoot -Path $plan.RelativePath -Bytes $plan.OriginalBytes -SourceDigest $plan.OriginalDigest -CurrentDigest $plan.DesiredDigest)
        } catch {
            $rollbackFailures.Add(("{0}: {1}" -f $plan.RelativePath,$_.Exception.Message))
        }
    }
    Assert-HarnessKernelCondition (-not $rollbackFailures.Count) ("Entry contract publish failed ({0}); rollback also failed ({1}). K0 recovery files were retained." -f $publishFailure,($rollbackFailures -join '; '))
    throw ("Entry contract publish failed; all published targets were rolled back: {0}" -f $publishFailure)
}

Write-Host ("STATUS: PASS ({0} updated, {1} already current)" -f $drifted.Count, ($plans.Count - $drifted.Count))
