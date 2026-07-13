# 共享运行时收件箱分诊脚本。
# 支持列出 open 项，或按字面条件更新匹配项状态。
# 该脚本只操作 runtime inbox，不修改其他编排产物。

[CmdletBinding()]
param(
    [string]$VaultRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$List,
    [string]$RowId = '',
    [string]$RouteTaskId = '',
    [string]$CreatedAt = '',
    [string]$TaskId = '',
    [string]$Type = '',
    [string]$Source = '',
    [string]$Summary = '',
    [string]$Payload = '',
    [string]$SummaryContains = '',
    [string]$SetStatus = 'cleared',
    [string]$ResolutionNote = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $PSScriptRoot 'runtime-inbox-common.ps1')
. (Join-Path $PSScriptRoot 'runtime-state-common.ps1')

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

if (@('cleared', 'resolved', 'closed', 'done') -cnotcontains $SetStatus) {
    Write-FailAndExit -Message "SetStatus must be one of: cleared, resolved, closed, done"
}
if (-not [string]::IsNullOrWhiteSpace($RowId) -and $RowId -cnotmatch '^row-[0-9a-f]{60}$') {
    Write-FailAndExit -Message "RowId must match row-<60 lowercase hex>: $RowId"
}
if (-not [string]::IsNullOrWhiteSpace($RouteTaskId) -and -not (Test-CanonicalRuntimeTaskId -TaskId $RouteTaskId)) {
    Write-FailAndExit -Message "RouteTaskId must be a canonical task id: $RouteTaskId"
}
if (-not $List.IsPresent -and
    [string]::IsNullOrWhiteSpace($RowId) -and
    [string]::IsNullOrWhiteSpace($RouteTaskId) -and
    [string]::IsNullOrWhiteSpace($CreatedAt) -and
    [string]::IsNullOrWhiteSpace($TaskId) -and
    [string]::IsNullOrWhiteSpace($Type) -and
    [string]::IsNullOrWhiteSpace($Source) -and
    [string]::IsNullOrWhiteSpace($Summary) -and
    [string]::IsNullOrWhiteSpace($Payload) -and
    [string]::IsNullOrWhiteSpace($SummaryContains)) {
    Write-FailAndExit -Message 'At least one selector is required: -RowId, -RouteTaskId, -CreatedAt, -TaskId, -Type, -Source, -Summary, -Payload, or -SummaryContains.'
}

<#
.SYNOPSIS
按选择器列出或更新共享运行时收件箱。

.DESCRIPTION
List 模式只输出 open 项。
更新模式要求至少一个选择器，并默认拒绝多条活动项的模糊匹配。
#>

$runtimeMutex = $null
try {
$vaultRequest = $VaultRoot
if ([string]::IsNullOrWhiteSpace($vaultRequest) -and -not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $vaultRequest = Join-Path ([System.IO.Path]::GetFullPath($WorkspaceRoot)) '.assistant'
}
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $vaultRequest -WorkspaceRoot $WorkspaceRoot
$runtimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $VaultRoot
$inbox = Read-RuntimeInbox -VaultRoot $VaultRoot

if ($List.IsPresent) {
    $openRows = Select-ActiveInboxRows -Rows $inbox.Rows
    $resolvedWorkspaceRoot = Resolve-WorkspaceRoot -WorkspaceRoot $WorkspaceRoot -VaultRoot $VaultRoot
    $listItems = @($openRows | ForEach-Object {
        $row = $_
        $routeTaskId = Get-InboxRouteTaskId -Row $row
        $planRelativePath = Join-Path (Join-Path 'docs\tasks' $routeTaskId) 'plan.md'
        $planPath = Resolve-CanonicalRuntimeContainedPath -Root $resolvedWorkspaceRoot -RelativePath $planRelativePath -Label 'inbox route plan'
        [pscustomobject][ordered]@{
            created_at       = $row.CreatedAt
            source           = $row.Source
            task_id          = $row.TaskId
            type             = $row.Type
            status           = $row.Status
            summary          = $row.Summary
            payload          = $row.Payload
            route_task_id    = $routeTaskId
            row_id           = Get-InboxRowId -Row $row
            task_plan_exists = [bool](Test-Path -LiteralPath $planPath -PathType Leaf)
        }
    })
    Write-Output ([ordered]@{ open_items = [object[]]$listItems } | ConvertTo-Json -Compress -Depth 4)
    Write-Output 'STATUS: PASS'
    exit 0
}

$matches = Select-ActiveInboxRows `
    -Rows $inbox.Rows `
    -RowId $RowId `
    -RouteTaskId $RouteTaskId `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -Summary $Summary `
    -Payload $Payload `
    -SummaryContains $SummaryContains

if ($matches.Count -eq 0) {
    Write-FailAndExit -Message 'Matched 0 active runtime inbox rows.'
}

$matchIdentitySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($match in $matches) {
    [void]$matchIdentitySet.Add((Format-InboxRow -Row $match))
}
if ($matchIdentitySet.Count -gt 1) {
    Write-FailAndExit -Message ('Matched {0} distinct active runtime inbox row identities; use -RowId from -List or the exact full-row selectors.' -f $matchIdentitySet.Count)
}

$matchKeys = @($matches | ForEach-Object { Format-InboxRow -Row $_ })
$updatedRows = foreach ($row in $inbox.Rows) {
    $rowKey = Format-InboxRow -Row $row
    if ($matchKeys -ccontains $rowKey) {
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
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output $_.Exception.Message
    exit 1
} finally {
    if ($null -ne $runtimeMutex) {
        Exit-CanonicalRuntimeMutex -Mutex $runtimeMutex
    }
}
exit 0
