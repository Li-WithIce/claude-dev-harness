[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$kernel = '{REPO_ROOT}\scripts\lib\Harness.RuntimeKernel.ps1'
. $kernel

function Write-CodexDeny {
    param([string]$Reason)
    $message = if ([string]::IsNullOrWhiteSpace($Reason)) { 'Harness PreToolUse launcher failed closed' } else { $Reason.Trim() }
    if ($message.Length -gt 4000) { $message = $message.Substring(0,4000) }
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":' + ($message | ConvertTo-Json -Compress) + '}}')
    exit 0
}

try {
    # Codex writes raw UTF-8 to the hook process. Decode Console.In explicitly so
    # the active Windows console code page cannot corrupt non-ASCII target paths.
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $inputText = [Console]::In.ReadToEnd()
    if ($inputText.Length -gt 0 -and [int]$inputText[0] -eq 0xFEFF) { $inputText = $inputText.Substring(1) }
    if ($inputText.Length -eq 0) { Write-CodexDeny -Reason 'Harness PreToolUse input is empty' }
    $result = Invoke-HarnessKernelProcess -FilePath '{PWSH_EXE}' -WorkingDirectory ([IO.Path]::GetTempPath()) -Arguments @('-NoProfile','-NonInteractive','-File','{CLAUDE_HOME}\hooks-memory\pretooluse.ps1') -TimeoutMilliseconds 9000 -StandardInput $inputText
    if (-not $result.Complete) { Write-CodexDeny -Reason 'Harness PreToolUse adapter timed out' }
    elseif ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.StdErr)) { Write-CodexDeny -Reason 'Harness PreToolUse policy denied or failed closed' }
    elseif ($result.StdOut.Trim() -cne '{}') { Write-CodexDeny -Reason 'Harness PreToolUse adapter returned an unsupported decision' }
    [Console]::Out.Write('{}')
    exit 0
} catch {
    Write-CodexDeny -Reason 'Harness PreToolUse launcher failed closed'
}
