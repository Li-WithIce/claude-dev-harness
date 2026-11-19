[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$kernel = '{REPO_ROOT}\scripts\lib\Harness.RuntimeKernel.ps1'
$launcherStage = 'startup'

function Write-CodexDeny {
    param([string]$Reason)
    $message = if ([string]::IsNullOrWhiteSpace($Reason)) { 'Harness PreToolUse launcher failed closed' } else { $Reason.Trim() }
    if ($message.Length -gt 4000) { $message = $message.Substring(0,4000) }
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":' + ($message | ConvertTo-Json -Compress) + '}}')
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $kernel -PathType Leaf) -or -not (Test-Path -LiteralPath '{PWSH_EXE}' -PathType Leaf)) { Write-CodexDeny -Reason 'Harness PreToolUse launcher startup dependency unavailable' }
    . $kernel
    # Codex writes raw UTF-8 to the hook process. Decode Console.In explicitly so
    # the active Windows console code page cannot corrupt non-ASCII target paths.
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $launcherStage = 'input'
    $inputText = [Console]::In.ReadToEnd()
    if ($inputText.Length -gt 0 -and [int]$inputText[0] -eq 0xFEFF) { $inputText = $inputText.Substring(1) }
    if ($inputText.Length -eq 0) { Write-CodexDeny -Reason 'Harness PreToolUse input is empty' }
    $launcherStage = 'adapter-invoke'
    $result = Invoke-HarnessKernelProcess -FilePath '{PWSH_EXE}' -WorkingDirectory ([IO.Path]::GetTempPath()) -Arguments @('-NoProfile','-NonInteractive','-File','{CLAUDE_HOME}\hooks-memory\pretooluse.ps1') -TimeoutMilliseconds 9000 -StandardInput $inputText
    $launcherStage = 'decision'
    if (-not $result.Complete) { Write-CodexDeny -Reason 'Harness PreToolUse adapter timed out' }
    elseif ($result.ExitCode -ne 0 -or $result.StdErr.Length -ne 0) {
        $denyPattern = '\AHARNESS_DENY:(?<category>input|permission-mode|workspace-binding|patch-path|patch-syntax|path-boundary|read-only|shell-form|policy-requirement|policy-unavailable|startup|unknown)'
        $denyPattern += '(?:;stage=(?<stage>input|tool|workspace|module|preflight|action-input|target|policy);'
        $denyPattern += 'action=(?<action>unknown|shell|apply_patch|file_mutation))?\z'
        $known = [regex]::Match($result.StdErr.Trim(),$denyPattern)
        if ($result.ExitCode -eq 2 -and $result.StdOut.Length -eq 0 -and $known.Success) {
            $context = if ($known.Groups['stage'].Success) { '; stage=' + $known.Groups['stage'].Value + '; action=' + $known.Groups['action'].Value } else { '; stage=unknown; action=unknown' }
            if ($known.Groups['category'].Value -ceq 'unknown') { Write-CodexDeny -Reason ('Harness PreToolUse unclassified adapter exception' + $context) }
            Write-CodexDeny -Reason ('Harness PreToolUse denied: ' + $known.Groups['category'].Value + $context)
        }
        Write-CodexDeny -Reason 'Harness PreToolUse adapter returned invalid error output'
    }
    elseif ($result.StdOut.Trim() -cne '{}') { Write-CodexDeny -Reason 'Harness PreToolUse adapter returned an unsupported decision' }
    [Console]::Out.Write('{}')
    exit 0
} catch {
    Write-CodexDeny -Reason ('Harness PreToolUse launcher exception; stage=' + $launcherStage)
}
