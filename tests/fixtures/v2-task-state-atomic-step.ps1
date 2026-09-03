[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$StepPath,
    [Parameter(Mandatory)][ValidatePattern('^txn_[0-9a-f]{32}$')][string]$TransactionId,
    [switch]$FailAfterPublish,
    [switch]$Replay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ($FailAfterPublish) { $env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_PUBLISH = '1' }
    $module = @(Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force -PassThru -ErrorAction Stop)[-1]
    $step = Get-Content -LiteralPath $StepPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    $result = & $module {
        param($Root,$Id,$TransactionStep,$IsReplay)
        $record = [pscustomobject]@{Journal=[ordered]@{transaction_id=$Id;task_id='atomic-step-fixture'};IntentDigest=('sha256:' + ('0' * 64))}
        $applied = Invoke-TransactionStep -WorkspaceRoot $Root -Record $record -Step $TransactionStep -AllowExistingClaim:$IsReplay
        Remove-TransactionStepClaim -WorkspaceRoot $Root -Record $record -Step $TransactionStep -Claim $applied.Claim
        return $applied.Result
    } $WorkspaceRoot $TransactionId $step ([bool]$Replay)
    Write-Output ([string]$result)
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
