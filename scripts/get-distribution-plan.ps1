[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [ValidateSet('core','governed','full')][string]$Preset = 'core',
    [string]$PlanPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=Split-Path -Parent $PSScriptRoot }
    Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Distribution.psm1') -Force -ErrorAction Stop
    $plan = Get-HarnessDistributionPlan -RepoRoot $RepoRoot -Preset $Preset
    if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
        Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Path.psm1') -ErrorAction Stop
        Import-Module (Join-Path $PSScriptRoot 'lib\Harness.CanonicalJson.psm1') -ErrorAction Stop
        $path = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $PlanPath -Label 'Distribution plan input' -MustExist File
        $bytes = ConvertTo-HarnessCanonicalJsonBytes -JsonBytes ([IO.File]::ReadAllBytes($path))
        $provided = ConvertFrom-HarnessJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
        if ($provided.profile_id -cne $Preset) { throw 'Distribution plan preset differs from the requested preset' }
        Assert-HarnessDistributionPlanCurrent -RepoRoot $RepoRoot -Plan $provided
    }
    $outputBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes((ConvertTo-HarnessDistributionJson -Document $plan) + "`n")
    $output=[Console]::OpenStandardOutput()
    $output.Write($outputBytes,0,$outputBytes.Length)
    $output.Flush()
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
