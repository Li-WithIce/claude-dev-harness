[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [switch]$List,
    [string]$CreatedAt = "",
    [string]$TaskId = "",
    [string]$Type = "",
    [string]$Source = "",
    [string]$SummaryContains = "",
    [string]$SetStatus = "cleared",
    [string]$ResolutionNote = "",
    [switch]$ResolveAllMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'triage-runtime-inbox.ps1'
& $scriptPath `
    -VaultRoot $VaultRoot `
    -List:$($List.IsPresent) `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -SummaryContains $SummaryContains `
    -SetStatus $SetStatus `
    -ResolutionNote $ResolutionNote `
    -ResolveAllMatches:$($ResolveAllMatches.IsPresent)
exit $LASTEXITCODE
