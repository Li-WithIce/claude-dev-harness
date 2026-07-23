[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-InnerProcessTree {
    param([System.Diagnostics.Process]$TargetProcess)

    if ($null -eq $TargetProcess -or $TargetProcess.HasExited) { return }
    $taskkill = $null
    try {
        $taskkillInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $taskkillInfo.FileName = '{TASKKILL_EXE}'
        $taskkillInfo.Arguments = '/PID ' + $TargetProcess.Id + ' /T /F'
        $taskkillInfo.UseShellExecute = $false
        $taskkillInfo.RedirectStandardOutput = $true
        $taskkillInfo.RedirectStandardError = $true
        $taskkill = [System.Diagnostics.Process]::new()
        $taskkill.StartInfo = $taskkillInfo
        [void]$taskkill.Start()
        if (-not $taskkill.WaitForExit(1500)) {
            $taskkill.Kill()
            [void]$taskkill.WaitForExit(500)
        }
    } catch {
        try { $TargetProcess.Kill() } catch {}
    } finally {
        if ($null -ne $taskkill) { $taskkill.Dispose() }
    }
    if (-not $TargetProcess.HasExited) {
        try { $TargetProcess.Kill() } catch {}
        try { [void]$TargetProcess.WaitForExit(500) } catch {}
    }
}

function Write-CodexDeny {
    param([string]$Reason)

    $message = if ([string]::IsNullOrWhiteSpace($Reason)) {
        'Harness PreToolUse launcher failed closed'
    } else {
        $Reason.Trim()
    }
    if ($message.Length -gt 4000) {
        $message = $message.Substring(0,4000)
    }
    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $message
        }
    } | ConvertTo-Json -Depth 4 -Compress
    [Console]::Out.Write($output)
    exit 0
}

$process = $null
try {
    # Codex writes raw UTF-8 to the hook process. Decode Console.In explicitly so
    # the active Windows console code page cannot corrupt non-ASCII target paths.
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    $inputText = [Console]::In.ReadToEnd()
    if ($inputText.Length -gt 0 -and [int]$inputText[0] -eq 0xFEFF) {
        $inputText = $inputText.Substring(1)
    }
    if ($inputText.Length -eq 0) {
        Write-CodexDeny -Reason 'Harness PreToolUse input is empty'
    }
    $inputBytes = $utf8.GetBytes($inputText)

    $adapterPath = '{CLAUDE_HOME}\hooks-memory\pretooluse.ps1'
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = '{PWSH_EXE}'
    $processInfo.Arguments = '-NoProfile -NonInteractive -File "' + $adapterPath + '"'
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(9000)) {
        Stop-InnerProcessTree -TargetProcess $process
        Write-CodexDeny -Reason 'Harness PreToolUse adapter timed out'
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        Write-CodexDeny -Reason 'Harness PreToolUse policy denied or failed closed'
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-CodexDeny -Reason 'Harness PreToolUse policy denied or failed closed'
    }
    if ($stdout.Trim() -cne '{}') {
        Write-CodexDeny -Reason 'Harness PreToolUse adapter returned an unsupported decision'
    }
    [Console]::Out.Write('{}')
    exit 0
} catch {
    Write-CodexDeny -Reason 'Harness PreToolUse launcher failed closed'
} finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
}
