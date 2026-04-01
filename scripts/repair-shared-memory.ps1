[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PassThruArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'repair-shared-memory.ps1'
if ($null -eq $PassThruArgs -or $PassThruArgs.Count -eq 0) {
    & $scriptPath
} else {
    & $scriptPath @PassThruArgs
}
exit $LASTEXITCODE
