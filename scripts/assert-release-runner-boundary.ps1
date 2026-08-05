[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('producer','aggregator')][string]$Mode,
    [Parameter(Mandatory)][AllowEmptyString()][string]$ProducerRunnerLabel,
    [Parameter(Mandatory)][AllowEmptyString()][string]$AggregatorRunnerLabel,
    [string]$ModelProducerAccountDigest = '',
    [string]$HostProducerAccountDigest = '',
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$RunAttempt,
    [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
    [string]$RepoRoot = '',
    [AllowEmptyString()][string]$Role = '',
    [AllowEmptyString()][string]$CodexHome = '',
    [AllowEmptyString()][string]$ObservationOutputPath = '',
    [ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode = 'formal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'release runner account boundary requires Windows' }
if ([string]::IsNullOrWhiteSpace($ProducerRunnerLabel) -or [string]::IsNullOrWhiteSpace($AggregatorRunnerLabel)) { throw 'release runner labels must be non-empty' }
if ($ProducerRunnerLabel.Equals($AggregatorRunnerLabel,[StringComparison]::OrdinalIgnoreCase)) { throw 'producer and aggregator runner labels must be different' }
if ($RunId -cnotmatch '^[1-9][0-9]*$' -or $RunAttempt -cnotmatch '^[1-9][0-9]*$') { throw 'release workflow run identity is invalid' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { $sid = [string]$identity.User.Value } finally { $identity.Dispose() }
if ($sid -cnotmatch '^S-[0-9]+(?:-[0-9]+)+$') { throw 'release runner Windows account identity is unavailable' }
$identityText = "thin-v2-release-runner-account/v1`n$RunId`n$RunAttempt`n$sid"
$identityBytes = [Text.UTF8Encoding]::new($false).GetBytes($identityText)
$accountDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($identityBytes)).ToLowerInvariant()

function Write-RunnerObservation {
    if ([string]::IsNullOrWhiteSpace($ObservationOutputPath)) { return }
    $expectedRoles = if ($Mode -ceq 'producer') { @('model-producer','host-producer') } else { @('aggregator') }
    if ([string]$Role -cnotin $expectedRoles) { throw 'release runner observation role is invalid for the boundary mode' }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $script:RepoRoot = Split-Path -Parent $PSScriptRoot }
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $module = Import-Module (Join-Path $root 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
    $observation = & $module {
        param($Root,$BoundaryMode,$ObservationRole,$ProducerLabel,$AggregatorLabel,$Digest,$WorkflowRun,$Attempt,$Home,$ModeName,$Output)
        New-ReleaseRunnerObservationArtifact -RepoRoot $Root -Mode $BoundaryMode -Role $ObservationRole -ProducerRunnerLabel $ProducerLabel -AggregatorRunnerLabel $AggregatorLabel -AccountDigest $Digest -RunId $WorkflowRun -RunAttempt $Attempt -CodexHome $Home -ProducerMode $ModeName -OutputPath $Output
    } $root $Mode $Role $ProducerRunnerLabel $AggregatorRunnerLabel $accountDigest $RunId $RunAttempt $CodexHome $ProducerMode $ObservationOutputPath
    if ($ProducerMode -ceq 'formal' -and [string]$observation.status -cne 'pass') { throw 'release runner formal observation did not pass' }
}

if ($Mode -ceq 'producer') {
    if (-not [string]::IsNullOrWhiteSpace($ModelProducerAccountDigest) -or -not [string]::IsNullOrWhiteSpace($HostProducerAccountDigest)) { throw 'producer mode does not accept producer account digests' }
    if ([string]::IsNullOrWhiteSpace($GitHubOutputPath)) { throw 'producer mode requires GITHUB_OUTPUT' }
    Write-RunnerObservation
    Add-Content -LiteralPath $GitHubOutputPath -Value "runner_account_digest=$accountDigest" -Encoding utf8
    Write-Output "RELEASE_RUNNER_BOUNDARY=producer`nRUNNER_ACCOUNT_DIGEST=$accountDigest"
    exit 0
}

$producerAccountDigests = @($ModelProducerAccountDigest,$HostProducerAccountDigest)
if (@($producerAccountDigests | Where-Object { [string]$_ -cnotmatch '^sha256:[0-9a-f]{64}$' }).Count -ne 0) {
    throw 'aggregator requires two valid producer account digests'
}
if (@($producerAccountDigests | Where-Object { [string]$_ -ceq $accountDigest }).Count -ne 0) { throw 'aggregator must run under a different Windows account from both producers' }
$credentialFields = [Collections.Generic.List[string]]::new()
foreach ($name in @('HOST_BENCHMARK_CODEX_HOME','CODEX_HOME','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY')) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process))) { $credentialFields.Add($name) }
}
$defaultAuthPath = Join-Path $HOME '.codex\auth.json'
if (Test-Path -LiteralPath $defaultAuthPath) { $credentialFields.Add('default_codex_auth') }
if ($credentialFields.Count -ne 0) { throw ('aggregator credential boundary contains forbidden fields: ' + ($credentialFields -join ',')) }
Write-RunnerObservation
Write-Output "RELEASE_RUNNER_BOUNDARY=aggregator`nRUNNER_ACCOUNT_DIGEST=$accountDigest"
