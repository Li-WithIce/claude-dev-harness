[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param([string]$Message)
    $script:checks.Add($Message)
}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Success,
        [string]$Failure
    )

    if ($Condition) {
        Add-Check $Success
    } else {
        Add-Failure $Failure
    }
}

function Get-FileDigest {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ManagedBlock {
    param([string]$Path)

    $text = (Get-Content -LiteralPath $Path -Raw -Encoding utf8) -replace "`r`n?", "`n"
    $pattern = '(?ms)^<!-- BEGIN GENERATED ENTRY CONTRACT -->\n<!-- source-sha256: (?<digest>[0-9a-f]{64}) -->\n(?<body>.*?)\n<!-- END GENERATED ENTRY CONTRACT -->$'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -ne 1) {
        return $null
    }

    return [pscustomobject]@{
        Full = $matches[0].Value
        Digest = $matches[0].Groups['digest'].Value
        Body = $matches[0].Groups['body'].Value
        Overlay = $text.Remove($matches[0].Index, $matches[0].Length)
    }
}

function Invoke-GeneratorProcess {
    param(
        [string]$Root,
        [switch]$Check,
        [int]$FailAfterReplace = 0
    )

    $scriptPath = Join-Path $Root 'scripts\generate-entry-contract.ps1'
    $arguments = @('-RepoRoot', $Root)
    if ($Check) {
        $arguments += '-Check'
    }
    $faultVariable = 'DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE'
    $previousFault = [System.Environment]::GetEnvironmentVariable($faultVariable, [System.EnvironmentVariableTarget]::Process)
    try {
        $faultValue = if ($FailAfterReplace -gt 0) { [string]$FailAfterReplace } else { $null }
        [System.Environment]::SetEnvironmentVariable($faultVariable, $faultValue, [System.EnvironmentVariableTarget]::Process)
        $started = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $scriptPath -Arguments $arguments
    } finally {
        [System.Environment]::SetEnvironmentVariable($faultVariable, $previousFault, [System.EnvironmentVariableTarget]::Process)
    }
    $exited = $started.Process.WaitForExit(30000)
    if (-not $exited) {
        $started.Process.Kill($true)
        [void]$started.Process.WaitForExit(5000)
    }
    $stdout = $started.StdOut.GetAwaiter().GetResult()
    $stderr = $started.StdErr.GetAwaiter().GetResult()
    $exitCode = if ($started.Process.HasExited) { $started.Process.ExitCode } else { -1 }
    $started.Process.Dispose()
    return [pscustomobject]@{
        Exited = $exited
        ExitCode = $exitCode
        Output = (($stdout + $stderr).Trim())
    }
}

$generatorPath = Join-Path $RepoRoot 'scripts\generate-entry-contract.ps1'
$canonicalPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$fixturePath = Join-Path $RepoRoot 'tests\scenarios\entry-contract\v1-routing.json'
$targetRelativePaths = @(
    'agent-configs/workspace/AGENTS.md.template',
    'agent-configs/codex/AGENTS.md.template',
    'agent-configs/claude/CLAUDE.md.template',
    'vault-template/entry/AGENTS.md.template'
)
$baselineCommit = 'aee525f6b3b0638f11bf6ab278482aa5b8c79d11'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr02-' + [guid]::NewGuid().ToString('N'))
$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)

try {
    foreach ($scriptPath in @($generatorPath, $PSCommandPath)) {
        Assert-True -Condition (Test-FileHasUtf8Bom -Path $scriptPath) -Success ("{0} has UTF-8 BOM" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} must have UTF-8 BOM" -f (Split-Path -Leaf $scriptPath))
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True -Condition (@($parseErrors).Count -eq 0) -Success ("{0} parses as PowerShell" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} has PowerShell parse errors" -f (Split-Path -Leaf $scriptPath))
    }

    $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
    $canonicalText = (Get-Content -LiteralPath $canonicalPath -Raw -Encoding utf8) -replace "`r`n?", "`n"
    $canonicalBody = $canonicalText.TrimEnd([char[]]"`n")
    $canonicalDigest = Get-FileDigest -Path $canonicalPath
    $canonicalHasBom = $canonicalBytes.Length -ge 3 -and $canonicalBytes[0] -eq 0xEF -and $canonicalBytes[1] -eq 0xBB -and $canonicalBytes[2] -eq 0xBF
    Assert-True -Condition (-not $canonicalHasBom -and -not $canonicalText.Contains("`r")) -Success 'canonical entry contract is deterministic LF UTF-8 without BOM' -Failure 'canonical entry contract encoding is not deterministic'
    Assert-True -Condition ($canonicalText -match '`protocol_default`:\s*`auto`' -and $canonicalText -match '`auto_resolves_to`:\s*`existing-artifact-or-gated-v2-new`' -and $canonicalText -match '`v2_entry_activation`:\s*`explicit-new-or-existing-v2-or-eligible-auto-new`') -Success 'auto is artifact-first and requires an eligible report for a new v2 task' -Failure 'entry contract protocol detector rollout is invalid'
    Assert-True -Condition ($canonicalText -notmatch '\{(?:REPO_ROOT|VAULT_PATH|CODEX_HOME)\}' -and $canonicalText -notmatch '`auto_resolves_to`:\s*`v2`') -Success 'canonical body is host-neutral and never enables unconditional auto=v2' -Failure 'canonical body contains a host token or unconditional v2 default'

    $fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ([string]$fixture.schema_version -ceq 'thin-harness-entry-routing/v1' -and [string]$fixture.protocol.default -ceq 'auto' -and [string]$fixture.protocol.auto_resolves_to -ceq 'existing-artifact-or-gated-v2-new' -and [string]$fixture.protocol.v2_entry_activation -ceq 'explicit-new-or-existing-v2-or-eligible-auto-new') -Success 'route fixture preserves artifact-first gated auto' -Failure 'route fixture protocol metadata is invalid'
    $invariants = @($fixture.baseline.invariants)
    $invariantIds = @($invariants | ForEach-Object { [string]$_.id })
    Assert-True -Condition ([string]$fixture.baseline.commit -ceq $baselineCommit -and $invariants.Count -eq 6 -and @($invariantIds | Select-Object -Unique).Count -eq 6) -Success 'v1 fixture pins six unique behavior invariants to the immutable base commit' -Failure 'v1 baseline invariant catalog is incomplete or points at the wrong commit'
    foreach ($invariant in $invariants) {
        $baselineText = @(& git -C $RepoRoot show ("{0}:{1}" -f $baselineCommit, [string]$invariant.source_path) 2>&1) -join "`n"
        $baselineRead = $LASTEXITCODE -eq 0
        Assert-True -Condition ($baselineRead -and $baselineText.Contains([string]$invariant.baseline_contains, [System.StringComparison]::Ordinal)) -Success ("base contains v1 behavior invariant {0}" -f $invariant.id) -Failure ("v1 invariant {0} is not independently anchored in the base commit" -f $invariant.id)
        Assert-True -Condition ($canonicalBody.Contains([string]$invariant.canonical_contains, [System.StringComparison]::Ordinal)) -Success ("canonical preserves v1 behavior invariant {0}" -f $invariant.id) -Failure ("canonical dropped v1 behavior invariant {0}" -f $invariant.id)
    }
    $tableRows = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($canonicalText -split "`n")) {
        $match = [regex]::Match($line, '^\|\s*`(?<case>[^`]+)`\s*\|\s*(?<condition>.*?)\s*\|\s*`(?<route>[^`]+)`\s*\|\s*`(?<writes>[^`]+)`\s*\|\s*`(?<stage>[^`]+)`\s*\|$')
        if ($match.Success) {
            $tableRows.Add(("{0}|{1}|{2}|{3}|{4}" -f $match.Groups['case'].Value, $match.Groups['condition'].Value.Trim(), $match.Groups['route'].Value, $match.Groups['writes'].Value, $match.Groups['stage'].Value))
        }
    }
    $fixtureRows = @($fixture.cases | ForEach-Object { "{0}|{1}|{2}|{3}|{4}" -f $_.case_id,$_.condition,$_.route,$_.writes,$_.stage_skill })
    Assert-True -Condition ($tableRows.Count -eq 10 -and @(Compare-Object @($tableRows) $fixtureRows).Count -eq 0) -Success 'canonical route table and ten-case v1 fixture match exactly' -Failure 'canonical route table drifted from the v1 fixture'

    $realCheck = Invoke-GeneratorProcess -Root $RepoRoot -Check
    Assert-True -Condition ($realCheck.Exited -and $realCheck.ExitCode -eq 0 -and $realCheck.Output -match 'STATUS: PASS') -Success 'generator -Check passes without writing real targets' -Failure ("generator -Check failed: {0}" -f $realCheck.Output)

    $managedBlocks = @()
    $currentBytes = 0
    $currentLines = 0
    $baselineBytes = 0
    $baselineLines = 0
    foreach ($relativePath in $targetRelativePaths) {
        $path = Join-Path $RepoRoot $relativePath
        $block = Get-ManagedBlock -Path $path
        Assert-True -Condition ($null -ne $block -and $block.Digest -ceq $canonicalDigest -and $block.Body -ceq $canonicalBody) -Success ("{0} contains the canonical generated block" -f $relativePath) -Failure ("{0} generated block is missing or stale" -f $relativePath)
        if ($null -ne $block) {
            $managedBlocks += $block.Full
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $lines = @(Get-Content -LiteralPath $path).Count
        $currentBytes += $bytes.Length
        $currentLines += $lines
        Assert-True -Condition ($lines -le 250) -Success ("{0} stays within the 250-line entry budget" -f $relativePath) -Failure ("{0} exceeds the 250-line entry budget" -f $relativePath)

        $sizeText = @(& git -C $RepoRoot cat-file -s ("{0}:{1}" -f $baselineCommit, $relativePath) 2>&1)
        $baseText = @(& git -C $RepoRoot show ("{0}:{1}" -f $baselineCommit, $relativePath) 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $baselineBytes += [int]$sizeText[0]
            $baselineLines += $baseText.Count
        } else {
            Add-Failure ("cannot read PR-00 baseline target {0}" -f $relativePath)
        }
    }
    Assert-True -Condition ($managedBlocks.Count -eq 4 -and @($managedBlocks | Select-Object -Unique).Count -eq 1) -Success 'all four allowlisted targets carry one byte-identical managed block' -Failure 'allowlisted generated blocks are not identical'
    Assert-True -Condition ($baselineBytes -eq 22194 -and $baselineLines -eq 206) -Success 'fixed PR-00 entry baseline is reproducible at 22194 bytes and 206 lines' -Failure ("fixed entry baseline drifted: {0} bytes, {1} lines" -f $baselineBytes,$baselineLines)
    Assert-True -Condition ($currentBytes -lt $baselineBytes -and $currentLines -lt $baselineLines) -Success ("generated entries shrink to {0} bytes and {1} lines" -f $currentBytes,$currentLines) -Failure ("generated entries did not shrink: {0} bytes and {1} lines" -f $currentBytes,$currentLines)

    New-Item -ItemType Directory -Path $scratchRoot | Out-Null
    foreach ($relativePath in @('scripts/generate-entry-contract.ps1', 'policies/entry-contract.md') + $targetRelativePaths) {
        Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $scratchRoot -RelativePath $relativePath
    }
    $fifthPath = Join-Path $scratchRoot 'agent-configs\unmanaged\AGENTS.md.template'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fifthPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($fifthPath, "unmanaged`n<!-- BEGIN GENERATED ENTRY CONTRACT -->`nkeep`n<!-- END GENERATED ENTRY CONTRACT -->`n", (New-Object System.Text.UTF8Encoding($false)))
    $fifthBefore = Get-FileDigest -Path $fifthPath
    $overlayBefore = @{}
    foreach ($relativePath in $targetRelativePaths) {
        $overlayBefore[$relativePath] = (Get-ManagedBlock -Path (Join-Path $scratchRoot $relativePath)).Overlay
    }

    $firstApply = Invoke-GeneratorProcess -Root $scratchRoot
    $firstHashes = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $secondApply = Invoke-GeneratorProcess -Root $scratchRoot
    $secondHashes = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($firstApply.ExitCode -eq 0 -and $secondApply.ExitCode -eq 0 -and @(Compare-Object $firstHashes $secondHashes -SyncWindow 0).Count -eq 0) -Success 'two generator applications are byte-idempotent' -Failure 'generator application is not idempotent'
    $overlaysPreserved = @($targetRelativePaths | Where-Object { (Get-ManagedBlock -Path (Join-Path $scratchRoot $_)).Overlay -cne $overlayBefore[$_] }).Count -eq 0
    Assert-True -Condition $overlaysPreserved -Success 'generation preserves every host overlay outside the markers' -Failure 'generation changed a host overlay'

    $tempCanonical = Join-Path $scratchRoot 'policies\entry-contract.md'
    $changedCanonical = ((Get-Content -LiteralPath $tempCanonical -Raw -Encoding utf8) -replace "`r`n?", "`n").TrimEnd([char[]]"`n") + "`n<!-- verifier canonical mutation -->`n"
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $changedDigest = Get-FileDigest -Path $tempCanonical
    $changedApply = Invoke-GeneratorProcess -Root $scratchRoot
    $allChanged = @($targetRelativePaths | Where-Object { (Get-ManagedBlock -Path (Join-Path $scratchRoot $_)).Digest -cne $changedDigest }).Count -eq 0
    Assert-True -Condition ($changedApply.ExitCode -eq 0 -and $allChanged) -Success 'one canonical edit updates all four targets in one run' -Failure 'canonical edit did not update every allowlisted target'
    Assert-True -Condition ((Get-FileDigest -Path $fifthPath) -ceq $fifthBefore) -Success 'generator leaves an unmanaged fifth entry file untouched' -Failure 'generator wrote outside its hardcoded allowlist'

    $beforeReservedMarker = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    [System.IO.File]::WriteAllText($tempCanonical, ($changedCanonical.TrimEnd([char[]]"`n") + "`n<!-- BEGIN GENERATED ENTRY CONTRACT -->`n"), (New-Object System.Text.UTF8Encoding($false)))
    $reservedMarkerApply = Invoke-GeneratorProcess -Root $scratchRoot
    $afterReservedMarker = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($reservedMarkerApply.ExitCode -ne 0 -and @(Compare-Object $beforeReservedMarker $afterReservedMarker -SyncWindow 0).Count -eq 0) -Success 'canonical source rejects reserved markers before any target write' -Failure 'reserved source marker was accepted or changed a target'
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))

    $beforeInjectedFailure = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $faultCanonical = $changedCanonical.TrimEnd([char[]]"`n") + "`n<!-- verifier publish fault -->`n"
    [System.IO.File]::WriteAllText($tempCanonical, $faultCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $faultApply = Invoke-GeneratorProcess -Root $scratchRoot -FailAfterReplace 2
    $afterInjectedFailure = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $publishDebris = @(Get-ChildItem -LiteralPath $scratchRoot -Recurse -File | Where-Object { $_.Name -match '\.entry-contract\.(?:tmp|bak|rollback)$' })
    Assert-True -Condition ($faultApply.ExitCode -ne 0 -and $faultApply.Output -match 'rolled back' -and @(Compare-Object $beforeInjectedFailure $afterInjectedFailure -SyncWindow 0).Count -eq 0 -and $publishDebris.Count -eq 0) -Success 'mid-publish fault rolls back every replaced target without debris' -Failure ("mid-publish fault was not transactionally rolled back: {0}" -f $faultApply.Output)
    [System.IO.File]::WriteAllText($tempCanonical, $changedCanonical, (New-Object System.Text.UTF8Encoding($false)))
    $postRollbackCheck = Invoke-GeneratorProcess -Root $scratchRoot -Check
    Assert-True -Condition ($postRollbackCheck.ExitCode -eq 0) -Success 'targets remain current after injected rollback' -Failure 'injected rollback left generated targets inconsistent'

    $driftPath = Join-Path $scratchRoot $targetRelativePaths[0]
    $driftText = (Get-Content -LiteralPath $driftPath -Raw -Encoding utf8).Replace('# Entry Contract', '# Entry Contract drift')
    [System.IO.File]::WriteAllText($driftPath, $driftText, (New-Object System.Text.UTF8Encoding($false)))
    $driftBefore = Get-FileDigest -Path $driftPath
    $driftCheck = Invoke-GeneratorProcess -Root $scratchRoot -Check
    Assert-True -Condition ($driftCheck.ExitCode -ne 0 -and (Get-FileDigest -Path $driftPath) -ceq $driftBefore) -Success '-Check reports drift nonzero and performs no write' -Failure '-Check accepted drift or changed the target'
    [void](Invoke-GeneratorProcess -Root $scratchRoot)

    $brokenPath = Join-Path $scratchRoot $targetRelativePaths[0]
    $otherDriftPath = Join-Path $scratchRoot $targetRelativePaths[1]
    $brokenText = (Get-Content -LiteralPath $brokenPath -Raw -Encoding utf8).Replace('<!-- END GENERATED ENTRY CONTRACT -->', '<!-- BEGIN GENERATED ENTRY CONTRACT -->')
    [System.IO.File]::WriteAllText($brokenPath, $brokenText, (New-Object System.Text.UTF8Encoding($false)))
    $otherDriftText = (Get-Content -LiteralPath $otherDriftPath -Raw -Encoding utf8).Replace('# Entry Contract', '# Entry Contract pending')
    [System.IO.File]::WriteAllText($otherDriftPath, $otherDriftText, (New-Object System.Text.UTF8Encoding($false)))
    $beforeMalformed = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    $malformedApply = Invoke-GeneratorProcess -Root $scratchRoot
    $afterMalformed = @($targetRelativePaths | ForEach-Object { Get-FileDigest -Path (Join-Path $scratchRoot $_) })
    Assert-True -Condition ($malformedApply.ExitCode -ne 0 -and @(Compare-Object $beforeMalformed $afterMalformed -SyncWindow 0).Count -eq 0) -Success 'duplicate or malformed markers fail before any target write' -Failure 'malformed marker handling caused a partial write'
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'entry-contract verification performs no repository or runtime writes' -Failure 'entry-contract verification changed repository state'

foreach ($check in $script:checks) {
    Write-Output ("[PASS] {0}" -f $check)
}
foreach ($failure in $script:failures) {
    Write-Output ("[FAIL] {0}" -f $failure)
}

if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}

Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
