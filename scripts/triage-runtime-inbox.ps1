[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$WorkspaceRoot = "",
    [switch]$List,
    [string]$RowId = "",
    [string]$RouteTaskId = "",
    [string]$CreatedAt = "",
    [string]$TaskId = "",
    [string]$Type = "",
    [string]$Source = "",
    [string]$Summary = "",
    [string]$Payload = "",
    [string]$SummaryContains = "",
    [string]$SetStatus = "cleared",
    [string]$ResolutionNote = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'triage-runtime-inbox.ps1'
& $scriptPath `
    -VaultRoot $VaultRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -List:$($List.IsPresent) `
    -RowId $RowId `
    -RouteTaskId $RouteTaskId `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -Summary $Summary `
    -Payload $Payload `
    -SummaryContains $SummaryContains `
    -SetStatus $SetStatus `
    -ResolutionNote $ResolutionNote
exit $LASTEXITCODE
