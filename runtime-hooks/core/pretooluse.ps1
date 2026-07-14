[CmdletBinding()]
param(
    [ValidateSet('read-only','write')][string]$SessionMode='write',
    [ValidateSet('read','write')][string]$ActionMode='read',
    [string]$TaskId='',
    [Nullable[int]]$ExpectedVersion=$null,
    [string]$CommandText='',
    [string[]]$ChangedPaths=@(),
    [string]$Environment='',
    [switch]$DryRun,
    [string]$UserInstruction='',
    [string]$RepoRoot='',
    [string]$WorkspaceRoot='',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){throw 'core safety hook requires RepoRoot'}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
    if([string]::IsNullOrWhiteSpace($WorkspaceRoot)){$WorkspaceRoot=$RepoRoot}else{$WorkspaceRoot=(Resolve-Path -LiteralPath $WorkspaceRoot).Path}
    if($ActionMode-ceq'read'){$result=[ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null};if($AsJson){$result|ConvertTo-Json -Depth 20 -Compress}else{"allowed: true";"protected: false"};exit 0}
    $module=Join-Path $RepoRoot 'scripts\lib\Harness.ProtectedAction.psm1'
    if(-not(Test-Path -LiteralPath $module -PathType Leaf)){throw 'core safety hook module is unavailable'}
    Import-Module $module -Force -ErrorAction Stop
    $result=Assert-HarnessProtectedAction -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -SessionMode $SessionMode -ActionMode $ActionMode -TaskId $TaskId -ExpectedVersion $ExpectedVersion -CommandText $CommandText -ChangedPaths $ChangedPaths -Environment $Environment -DryRun:$DryRun -UserInstruction $UserInstruction
    if($AsJson){$result|ConvertTo-Json -Depth 20 -Compress}else{"allowed: $([string]$result.allowed)";"protected: $([string]$result.protected)"}
    exit 0
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 2}
