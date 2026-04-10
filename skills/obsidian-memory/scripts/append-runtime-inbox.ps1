# 共享运行时收件箱追加脚本。
# 负责创建规范化 inbox，并追加新的 open 项。
# 任务 ID 未显式传入时，优先从 current-flow 解析。

[CmdletBinding()]
param(
    [string]$VaultRoot = '',
    [string]$TaskId = '',
    [Parameter(Mandatory = $true)]
    [string]$Type,
    [string]$Status = 'open',
    [Parameter(Mandatory = $true)]
    [string]$Summary,
    [string]$Payload = '-',
    [string]$Source = 'manual'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $PSScriptRoot 'runtime-inbox-common.ps1')

<#
.SYNOPSIS
追加一条共享运行时收件箱记录。

.DESCRIPTION
该入口会确保 inbox 文件是标准格式，并在追加前清理占位行。
当调用方未提供 TaskId 时，脚本会优先使用 current-flow.task_id。

.OUTPUTS
标准状态行，供 wrapper 和测试读取。
#>

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot
$inbox = Read-RuntimeInbox -VaultRoot $VaultRoot -NormalizeExisting
$entryTaskId = $TaskId
if ([string]::IsNullOrWhiteSpace($entryTaskId)) {
    $entryTaskId = Resolve-EntryTaskId -VaultRoot $VaultRoot
}

$activeRows = @($inbox.Rows | Where-Object {
    $_.CreatedAt -ne '-' -and $_.Summary -ne $script:RuntimeInboxPlaceholderSummary
})
$activeRows += [pscustomobject]@{
    CreatedAt = Get-CurrentTimestamp
    Source    = $Source
    TaskId    = $(if ([string]::IsNullOrWhiteSpace($entryTaskId)) { 'unknown' } else { $entryTaskId })
    Type      = $Type
    Status    = $Status
    Summary   = $Summary
    Payload   = $Payload
}

Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $activeRows

Write-Output 'STATUS: PASS'
Write-Output ('InboxPath: {0}' -f $inbox.Path)
Write-Output ('EntryTaskId: {0}' -f $(if ([string]::IsNullOrWhiteSpace($entryTaskId)) { 'unknown' } else { $entryTaskId }))
exit 0
