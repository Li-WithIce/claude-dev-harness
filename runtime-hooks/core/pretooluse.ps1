[CmdletBinding()]
param(
    [ValidateSet('read-only','write')][string]$SessionMode='write',
    [ValidateSet('read','write')][string]$ActionMode='read',
    [string]$TaskId='',
    [Nullable[int]]$ExpectedVersion=$null,
    [string]$CommandText='',
    [string[]]$ChangedPaths=@(),
    [string]$ChangedPathsJson='',
    [string]$Environment='',
    [switch]$DryRun,
    [string]$UserInstruction='',
    [string]$RepoRoot='',
    [string]$WorkspaceRoot='',
    [switch]$InputJsonFromStdin,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try{
    if($InputJsonFromStdin){
        $inputRaw=[Console]::In.ReadToEnd()
        if([string]::IsNullOrWhiteSpace($inputRaw)){throw 'core safety hook stdin envelope is empty'}
        try{$inputDocument=$inputRaw|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{throw "core safety hook stdin envelope is invalid: $($_.Exception.Message)"}
        if($inputDocument-isnot[System.Collections.IDictionary]){throw 'core safety hook stdin envelope must be an object'}
        $expectedInputKeys=@('session_mode','action_mode','task_id','expected_version','command_text','changed_paths','environment','dry_run','user_instruction')
        $actualInputKeys=@($inputDocument.Keys|ForEach-Object{[string]$_})
        if(@($expectedInputKeys|Where-Object{$actualInputKeys-cnotcontains$_}).Count-gt0-or
            @($actualInputKeys|Where-Object{$expectedInputKeys-cnotcontains$_}).Count-gt0){throw 'core safety hook stdin envelope keys are invalid'}
        foreach($key in @('session_mode','action_mode','task_id','command_text','environment','user_instruction')){
            if($inputDocument[$key]-isnot[string]){throw "core safety hook stdin envelope $key must be a string"}
        }
        if($inputDocument['changed_paths']-isnot[System.Collections.IList]-or$inputDocument['changed_paths']-is[string]){throw 'core safety hook stdin envelope changed_paths must be an array'}
        foreach($path in @($inputDocument['changed_paths'])){if($path-isnot[string]){throw 'core safety hook stdin envelope changed_paths values must be strings'}}
        if($inputDocument['dry_run']-isnot[bool]){throw 'core safety hook stdin envelope dry_run must be a boolean'}
        $inputExpectedVersion=$inputDocument['expected_version']
        if($null-ne$inputExpectedVersion-and$inputExpectedVersion-isnot[int]-and$inputExpectedVersion-isnot[long]){throw 'core safety hook stdin envelope expected_version must be an integer or null'}
        if($null-ne$inputExpectedVersion-and([long]$inputExpectedVersion-lt[int]::MinValue-or[long]$inputExpectedVersion-gt[int]::MaxValue)){throw 'core safety hook stdin envelope expected_version is out of range'}
        $SessionMode=[string]$inputDocument['session_mode']
        $ActionMode=[string]$inputDocument['action_mode']
        if($SessionMode-cnotin@('read-only','write')-or$ActionMode-cnotin@('read','write')){throw 'core safety hook stdin envelope mode is invalid'}
        $TaskId=[string]$inputDocument['task_id']
        $ExpectedVersion=$(if($null-eq$inputExpectedVersion){$null}else{[int]$inputExpectedVersion})
        $CommandText=[string]$inputDocument['command_text']
        $ChangedPaths=[string[]]@($inputDocument['changed_paths'])
        $Environment=[string]$inputDocument['environment']
        $DryRun=[bool]$inputDocument['dry_run']
        $UserInstruction=[string]$inputDocument['user_instruction']
    }
    if(-not[string]::IsNullOrWhiteSpace($ChangedPathsJson)){
        if($ChangedPaths.Count-gt0){throw 'core safety hook received both ChangedPaths and ChangedPathsJson'}
        $decodedPaths=ConvertFrom-Json -InputObject $ChangedPathsJson -NoEnumerate -ErrorAction Stop
        if($decodedPaths-isnot[System.Collections.IList]){throw 'core safety hook ChangedPathsJson must be an array'}
        foreach($path in $decodedPaths){if($path-isnot[string]){throw 'core safety hook ChangedPathsJson values must be strings'}}
        $ChangedPaths=[string[]]@($decodedPaths)
    }
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
