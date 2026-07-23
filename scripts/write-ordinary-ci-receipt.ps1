[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PullRequestNumber,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$RunAttempt,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHeadSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$BaseSha,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string]$JobId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,127}$')][string]$CheckName,
    [Parameter(Mandatory)][ValidateSet('success','failure','cancelled','skipped')][string]$Outcome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop

$OutputRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $OutputRoot
$existing = @(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction Stop)
if ($existing.Count -ne 0) { throw 'ordinary CI receipt output root must be empty' }

$checkoutLines = @(& git -C $RepoRoot rev-parse HEAD 2>$null | ForEach-Object { [string]$_ })
if ($LASTEXITCODE -ne 0 -or $checkoutLines.Count -ne 1 -or $checkoutLines[0] -cnotmatch '^[0-9a-fA-F]{40}$') {
    throw 'ordinary CI receipt checkout revision is unavailable'
}
$checkoutSha = $checkoutLines[0].ToLowerInvariant()
$headSha = $ExpectedHeadSha.ToLowerInvariant()
$baseShaNormalized = $BaseSha.ToLowerInvariant()
if ($checkoutSha -cne $headSha) { throw 'ordinary CI checkout is not the expected pull request head' }

$null = @(& git -C $RepoRoot cat-file -e "$baseShaNormalized^{commit}" 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'ordinary CI base revision is unavailable' }

$document = [ordered]@{
    schema_version = 'thin-harness-ordinary-ci-receipt/v1'
    pull_request_number = $PullRequestNumber
    run_id = $RunId
    run_attempt = $RunAttempt
    head_sha = $headSha
    base_sha = $baseShaNormalized
    checkout_sha = $checkoutSha
    job_id = $JobId
    check_name = $CheckName
    outcome = $Outcome
    created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
}
$json = ($document | ConvertTo-Json -Depth 10) + "`n"
$schemaPath = Join-Path $RepoRoot 'schemas\ordinary-ci-receipt.schema.json'
if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
    throw 'ordinary CI receipt failed schema validation'
}

$relativePath = 'ordinary-ci-receipt.json'
$target = Resolve-HarnessContainedPath -WorkspaceRoot $OutputRoot -Path $relativePath -Label 'ordinary CI receipt' -AllowMissing
if (Test-Path -LiteralPath $target) { throw 'ordinary CI receipt already exists' }
$digest = Write-HarnessAtomicText -WorkspaceRoot $OutputRoot -Path $relativePath -Content $json
$published = [System.IO.File]::ReadAllText($target,[System.Text.UTF8Encoding]::new($false,$true))
if (-not (Test-Json -Json $published -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
    throw 'published ordinary CI receipt failed schema validation'
}

[ordered]@{
    operation = 'ordinary-ci-receipt'
    receipt_path = $relativePath
    digest = $digest
    outcome = $Outcome
} | ConvertTo-Json -Depth 10 -Compress
