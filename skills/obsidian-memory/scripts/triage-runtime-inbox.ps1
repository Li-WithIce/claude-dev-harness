# 共享运行时收件箱分诊脚本。
# 支持列出 open 项，或按字面条件更新匹配项状态。
# 该脚本只操作 runtime inbox，不修改其他编排产物。

[CmdletBinding()]
param(
    [string]$VaultRoot = '',
    [switch]$List,
    [string]$CreatedAt = '',
    [string]$TaskId = '',
    [string]$Type = '',
    [string]$Source = '',
    [string]$SummaryContains = '',
    [string]$SetStatus = 'cleared',
    [string]$ResolutionNote = '',
    [switch]$ResolveAllMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $PSScriptRoot 'runtime-inbox-common.ps1')

function Write-FailAndExit {
    <#
    .SYNOPSIS
    输出失败信息并退出。

    .PARAMETER Message
    要输出的失败消息。
    #>
    param([string]$Message)

    Write-Output 'STATUS: FAIL'
    Write-Output $Message
    exit 1
}

<#
.SYNOPSIS
按选择器列出或更新共享运行时收件箱。

.DESCRIPTION
List 模式只输出 open 项。
更新模式要求至少一个选择器，并默认拒绝多条活动项的模糊匹配。
#>

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot
$inbox = Read-RuntimeInbox -VaultRoot $VaultRoot

if ($List.IsPresent) {
    $openRows = Select-ActiveInboxRows -Rows $inbox.Rows
    Write-Output 'STATUS: PASS'
    Write-Output ('OpenItems: {0}' -f $openRows.Count)
    foreach ($row in $openRows) {
        Write-Output ('created_at={0}; source={1}; task_id={2}; type={3}; status={4}; summary={5}; payload={6}' -f `
            $row.CreatedAt, $row.Source, $row.TaskId, $row.Type, $row.Status, $row.Summary, $row.Payload)
    }
    exit 0
}

if (
    [string]::IsNullOrWhiteSpace($CreatedAt) -and
    [string]::IsNullOrWhiteSpace($TaskId) -and
    [string]::IsNullOrWhiteSpace($Type) -and
    [string]::IsNullOrWhiteSpace($Source) -and
    [string]::IsNullOrWhiteSpace($SummaryContains)
) {
    Write-FailAndExit -Message 'At least one selector is required: -CreatedAt, -TaskId, -Type, -Source, or -SummaryContains.'
}

$matches = Select-ActiveInboxRows `
    -Rows $inbox.Rows `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -SummaryContains $SummaryContains

if ($matches.Count -eq 0) {
    Write-FailAndExit -Message 'Matched 0 active runtime inbox rows.'
}

if ($matches.Count -gt 1 -and -not $ResolveAllMatches.IsPresent) {
    Write-FailAndExit -Message ('Matched {0} active runtime inbox rows; narrow the selectors or add -ResolveAllMatches.' -f $matches.Count)
}

$matchKeys = @($matches | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.CreatedAt, $_.Source, $_.TaskId, $_.Summary })
$updatedRows = foreach ($row in $inbox.Rows) {
    $rowKey = '{0}|{1}|{2}|{3}' -f $row.CreatedAt, $row.Source, $row.TaskId, $row.Summary
    if ($matchKeys -contains $rowKey) {
        $newPayload = $row.Payload
        if (-not [string]::IsNullOrWhiteSpace($ResolutionNote)) {
            $newPayload = '{0} resolution: {1}' -f $newPayload, $ResolutionNote
        }

        [pscustomobject]@{
            CreatedAt = $row.CreatedAt
            Source    = $row.Source
            TaskId    = $row.TaskId
            Type      = $row.Type
            Status    = $SetStatus
            Summary   = $row.Summary
            Payload   = $newPayload
        }
        continue
    }

    $row
}

Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $updatedRows
Write-Output 'STATUS: PASS'
Write-Output ('ResolvedItems: {0}' -f $matches.Count)
exit 0
