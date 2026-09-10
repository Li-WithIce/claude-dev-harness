[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('harness-index-flags-中文 space-' + [guid]::NewGuid().ToString('N'))
$manifestRoot = 'tests/fixtures/tk04/index-flags'
$relative = "$manifestRoot/sample-capability/source.psm1"
$manifestPath = "$manifestRoot/sample-capability/module.manifest.json"
$testPath = 'tests/verify-provider-usage-recording.ps1'
$original = "`$script:SourceMarker = 'index'`n"
$blobBytes = [ordered]@{
    'empty.bin' = [byte[]]@()
    'bom.bin' = [byte[]]@(239,187,191,65,13,10)
    'binary.bin' = [byte[]]@(0,255,128,10,13,98,108,111,98,32,49,10,0)
    'utf8.bin' = [Text.Encoding]::UTF8.GetBytes("原始 UTF-8 字节`n")
    'large.bin' = [byte[]]::new(65537)
}
$blobBytes['large.bin'][65536] = 255
$locksBefore = $env:GIT_OPTIONAL_LOCKS
$env:GIT_OPTIONAL_LOCKS = '0'

function Git-Fixture {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $output = @(& git -c core.fsmonitor=false -c core.safecrlf=false -C $fixture @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join ' | ')" }
    return $output
}
function Write-FixtureFile {
    param([string]$Path,[string]$Text)
    $full = Join-Path $fixture $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    [IO.File]::WriteAllText($full,$Text,$utf8)
}
function Get-FixtureSnapshot {
    $paths = @('.git/index','.git/config') + @(Git-Fixture ls-files)
    return [ordered]@{
        flags=@(Git-Fixture ls-files -v)
        files=@(foreach ($path in $paths) {
            $full = Join-Path $fixture $path
            [ordered]@{path=$path;bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($full));ticks=(Get-Item -LiteralPath $full).LastWriteTimeUtc.Ticks}
        })
    } | ConvertTo-Json -Depth 6 -Compress
}

try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $null = Git-Fixture init --quiet
    $null = Git-Fixture config core.autocrlf false
    foreach ($schema in @('module-manifest-v1','capability-source','capability-source-catalog')) {
        Write-FixtureFile "schemas/$schema.schema.json" ([IO.File]::ReadAllText((Join-Path $RepoRoot "schemas/$schema.schema.json")))
    }
    $manifest = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/fixtures/tk04/valid/sample-capability/module.manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $manifest.ownership.owned_paths = @("$manifestRoot/sample-capability/**",$testPath)
    $manifest.package.code = @($relative) + @($blobBytes.Keys | ForEach-Object { "$manifestRoot/sample-capability/$_" })
    $manifest.exports.commands = @()
    $manifest.exports.libraries = @($relative)
    Write-FixtureFile $manifestPath ($manifest | ConvertTo-Json -Depth 20)
    Write-FixtureFile $relative $original
    Write-FixtureFile $testPath "# Unexecuted package test metadata.`n"
    foreach ($name in $blobBytes.Keys) {
        [IO.File]::WriteAllBytes((Join-Path $fixture "$manifestRoot/sample-capability/$name"),$blobBytes[$name])
    }
    Write-FixtureFile 'unrelated.txt' "not in the source closure`n"
    Write-FixtureFile '.gitattributes' "* text eol=lf`n*.bin -text`n"
    $null = Git-Fixture add --all
    Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.ModuleManifest.psm1') -Force
    $baselineDigest = $null
    foreach ($case in @('clean','plain-edit','assume-clean','assume-edit','skip-clean','skip-edit','crlf-equivalent','unrelated-flag')) {
        # These are owned fixture flags, never caller/workspace index flags. Clear separately.
        $null = Git-Fixture update-index --no-assume-unchanged -- $relative
        $null = Git-Fixture update-index --no-skip-worktree -- $relative
        Write-FixtureFile $relative $original
        if ($case.StartsWith('assume')) { $null = Git-Fixture update-index --assume-unchanged -- $relative }
        if ($case.StartsWith('skip')) { $null = Git-Fixture update-index --skip-worktree -- $relative }
        if ($case.EndsWith('-edit')) { Write-FixtureFile $relative ($original + "`$script:SourceMarker = 'worktree-only'`n") }
        if ($case -ceq 'crlf-equivalent') { Write-FixtureFile $relative ($original.Replace("`n","`r`n")) }
        if ($case -ceq 'unrelated-flag') {
            $null = Git-Fixture update-index --skip-worktree -- unrelated.txt
            Write-FixtureFile 'unrelated.txt' "unrelated hidden edit`n"
        }
        & git -c core.fsmonitor=false -c core.safecrlf=false -C $fixture diff --quiet --no-ext-diff -- $relative
        $gitExit = $LASTEXITCODE
        $before = Get-FixtureSnapshot
        $accepted = $false
        $errorText = ''
        $digest = $null
        try {
            $catalog = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $fixture -ManifestRoot $manifestRoot
            $accepted = $true
            $digest = $catalog.CapabilitySourceCatalog.sources[0].source_digest
        } catch { $errorText = $_.Exception.Message }
        $after = Get-FixtureSnapshot
        $blobDigestsMatch = $null
        if ($accepted) {
            $blobDigestsMatch = $true
            foreach ($name in $blobBytes.Keys) {
                $blobPath = "$manifestRoot/sample-capability/$name"
                $actual = @($catalog.CapabilitySourceCatalog.sources[0].files | Where-Object { $_.path -ceq $blobPath })
                $expected = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$blobBytes[$name])).ToLowerInvariant()
                if ($actual.Count -ne 1 -or $actual[0].sha256 -cne $expected) { $blobDigestsMatch = $false }
            }
        }
        if ($case -ceq 'clean') { $baselineDigest = $digest }
        $flagCase = $case.StartsWith('assume') -or $case.StartsWith('skip')
        $expectedAccept = $case -cin @('clean','crlf-equivalent','unrelated-flag')
        $correctError = if ($expectedAccept) { $accepted -and $digest -ceq $baselineDigest } elseif ($flagCase) {
            -not $accepted -and $errorText -match 'assume-unchanged or skip-worktree' -and $errorText -notmatch 'unstaged bytes'
        } else { -not $accepted -and $errorText -match 'unstaged bytes' }
        $gitExpected = if ($case -ceq 'plain-edit') { 1 } else { 0 }
        [pscustomobject]@{case=$case;pass=($correctError -and $gitExit -eq $gitExpected -and $before -ceq $after)
            git_exit=$gitExit;accepted=$accepted;zero_write=($before -ceq $after);blob_digests_match=$blobDigestsMatch;error=$errorText;fixture=$fixture}
    }
} finally {
    if ($null -eq $locksBefore) { Remove-Item -LiteralPath Env:GIT_OPTIONAL_LOCKS -ErrorAction Ignore }
    else { $env:GIT_OPTIONAL_LOCKS = $locksBefore }
    # Preserve the isolated observations for diagnosis; never clean the caller repository.
}
