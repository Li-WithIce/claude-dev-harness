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
        try{$request=$inputRaw|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{throw "core safety hook stdin envelope is invalid: $($_.Exception.Message)"}
        if($request-isnot[System.Collections.IDictionary]){throw 'core safety hook stdin envelope must be an object'}
        if($request.body-isnot[System.Collections.IDictionary]-or[string]$request.body.operation-cne'preflight_action'){throw 'core safety hook stdin envelope operation is invalid'}
        $body=$request.body
    }else{
        if(-not[string]::IsNullOrWhiteSpace($ChangedPathsJson)){
            if($ChangedPaths.Count-gt0){throw 'core safety hook received both ChangedPaths and ChangedPathsJson'}
            $decodedPaths=ConvertFrom-Json -InputObject $ChangedPathsJson -NoEnumerate -ErrorAction Stop
            if($decodedPaths-isnot[System.Collections.IList]){throw 'core safety hook ChangedPathsJson must be an array'}
            foreach($path in $decodedPaths){if($path-isnot[string]){throw 'core safety hook ChangedPathsJson values must be strings'}}
            $ChangedPaths=[string[]]@($decodedPaths)
        }
        if([string]::IsNullOrWhiteSpace($RepoRoot)){throw 'core safety hook requires RepoRoot'}
        $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
        if([string]::IsNullOrWhiteSpace($WorkspaceRoot)){$WorkspaceRoot=$RepoRoot}
        if($ActionMode-ceq'read'){
            $result=[ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null;operation_identity=$null;protected_operation=$null}
            if($AsJson){$result|ConvertTo-Json -Depth 20 -Compress}else{"allowed: true";"protected: false"}
            exit 0
        }
        $body=[ordered]@{
            repo_root=$RepoRoot
            workspace_root=$WorkspaceRoot
            workspace_root_fallback=''
            permission_mode=''
            session_mode=$SessionMode
            action_mode=$ActionMode
            action_kind='normalized_action'
            shell_text=$CommandText
            patch_text=''
            changed_paths=@($ChangedPaths)
            task_id=$TaskId
            expected_version=$ExpectedVersion
            environment=$Environment
            dry_run=[bool]$DryRun
            user_instruction=$UserInstruction
        }
    }
    if([string]::IsNullOrWhiteSpace($RepoRoot)){throw 'core safety hook requires RepoRoot'}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
    $module=Join-Path $RepoRoot 'scripts\lib\Harness.AdapterAction.psm1'
    if(-not(Test-Path -LiteralPath $module -PathType Leaf)){throw 'core safety hook module is unavailable'}
    Import-Module $module -Force -ErrorAction Stop
    $result=(Invoke-HarnessAdapterPreflightAction `
        -RepoRoot ([string]$body.repo_root) `
        -WorkspaceRoot ([string]$body.workspace_root) `
        -WorkspaceRootFallback ([string]$body.workspace_root_fallback) `
        -PermissionMode ([string]$body.permission_mode) `
        -SessionMode ([string]$body.session_mode) `
        -ActionMode ([string]$body.action_mode) `
        -ActionKind ([string]$body.action_kind) `
        -ShellText ([string]$body.shell_text) `
        -PatchText ([string]$body.patch_text) `
        -ChangedPaths ([string[]]@($body.changed_paths)) `
        -TaskId ([string]$body.task_id) `
        -ExpectedVersion $body.expected_version `
        -Environment ([string]$body.environment) `
        -DryRun:([bool]$body.dry_run) `
        -UserInstruction ([string]$body.user_instruction)).body
    if($AsJson){$result|ConvertTo-Json -Depth 20 -Compress}else{"allowed: $([string]$result.allowed)";"protected: $([string]$result.protected)"}
    exit 0
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 2}
