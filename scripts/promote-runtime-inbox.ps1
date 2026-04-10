[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$WorkspaceRoot = "",
    [string]$Target = '',
    [string]$CreatedAt = "",
    [string]$TaskId = "",
    [string]$Type = "inbox-first",
    [string]$Source = "",
    [string]$SummaryContains = "",
    [string]$TargetTaskId = "",
    [string]$TargetTaskName = "",
    [string]$Priority = 'P2',
    [string]$TaskStage = 'PLAN',
    [string]$NextStep = '',
    [string]$ArtifactRoot = '',
    [string]$PrimaryArtifact = '',
    [string]$DecisionSummary = '',
    [string]$BlockingReason = '',
    [string]$OptionA = '',
    [string]$OptionB = '',
    [string]$RecommendedPath = '',
    [string]$NeededFromUser = '',
    [string]$ResumeWhenResolved = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'promote-runtime-inbox.ps1'
& $scriptPath `
    -VaultRoot $VaultRoot `
    -WorkspaceRoot $WorkspaceRoot `
    -Target $Target `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -SummaryContains $SummaryContains `
    -TargetTaskId $TargetTaskId `
    -TargetTaskName $TargetTaskName `
    -Priority $Priority `
    -TaskStage $TaskStage `
    -NextStep $NextStep `
    -ArtifactRoot $ArtifactRoot `
    -PrimaryArtifact $PrimaryArtifact `
    -DecisionSummary $DecisionSummary `
    -BlockingReason $BlockingReason `
    -OptionA $OptionA `
    -OptionB $OptionB `
    -RecommendedPath $RecommendedPath `
    -NeededFromUser $NeededFromUser `
    -ResumeWhenResolved $ResumeWhenResolved
exit $LASTEXITCODE
