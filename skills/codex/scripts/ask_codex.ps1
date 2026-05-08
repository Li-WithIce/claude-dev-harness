#!/usr/bin/env powershell
# Windows PowerShell 5.1+ compatible script
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [Alias('t')]
    [string]$TaskText,

    [Alias('w')]
    [string]$Workspace = (Get-Location).Path,

    [Alias('f')]
    [string[]]$File,

    [string]$Session,

    [string]$Model,

    [ValidateSet('low', 'medium', 'high')]
    [string]$Reasoning = 'medium',

    [string]$Sandbox,

    [switch]$ReadOnly,

    [switch]$FullAuto,

    [switch]$Ephemeral,

    [Alias('o')]
    [string]$Output,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage:
  ask_codex.ps1 <task> [options]
  ask_codex.ps1 -Task <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -Task, -t <text>             Alias for positional task

File context (optional, repeatable):
  -File, -f <path>             Priority file path

Multi-turn:
  -Session <id>                Resume a previous session (thread_id from prior run)

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -Model <name>                Model override
  -Reasoning <level>           Reasoning effort: low, medium, high (default: medium)
  -Sandbox <mode>              Sandbox mode override
  -ReadOnly                    Read-only sandbox (no file changes)
  -FullAuto                    Full-auto mode (default)
  -Ephemeral                   Do not persist Codex session files (useful for one-shot smokes)
  -Output, -o <path>           Output file path
  -Help                        Show this help

Output (on success):
  session_id=<thread_id>       Use with -Session for follow-up calls
  output_path=<file>           Path to response markdown

Examples:
  # New task (positional)
  ask_codex.ps1 "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex.ps1 "Fix the bug" -w C:\other\repo

  # Continue conversation
  ask_codex.ps1 "Also add retry logic" -Session <id>
'@
}

function Test-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        $diag = @{
            status = "preflight_failed"
            tool = $Name
            reason = "Command '$Name' not found in PATH"
            suggestion = if ($Name -eq 'codex') { "Install with: npm install -g @openai/codex" } else { "Install '$Name' and ensure it is in PATH" }
        } | ConvertTo-Json -Compress
        Write-Output $diag
        exit 1
    }
}

function Test-CodexRunnable {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/c codex --version'
        } else {
            $psi.FileName = 'codex'
            $psi.Arguments = '--version'
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        try {
            $process.Start() | Out-Null
            $stdoutText = $process.StandardOutput.ReadToEnd().Trim()
            $stderrText = $process.StandardError.ReadToEnd().Trim()
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }

        if ($exitCode -ne 0) {
            $rawOutput = @($stdoutText, $stderrText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $diag = @{
                status = "preflight_failed"
                tool = "codex"
                reason = "codex --version returned exit code $exitCode"
                suggestion = "Reinstall Codex CLI or check PATH"
                raw_output = ($rawOutput -join [Environment]::NewLine)
            } | ConvertTo-Json -Compress
            Write-Output $diag
            exit 1
        }

        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host "[preflight] codex warnings: $stderrText" -ForegroundColor Yellow
        }

        $versionSummary = @($stdoutText, $stderrText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        Write-Host "[preflight] codex version: $versionSummary" -ForegroundColor Gray
    } catch {
        $diag = @{
            status = "preflight_failed"
            tool = "codex"
            reason = "codex --version threw: $($_.Exception.Message)"
            suggestion = "Check codex installation"
        } | ConvertTo-Json -Compress
        Write-Output $diag
        exit 1
    }
}

function Trim-Whitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim() -replace '\s+', ' '
}

function Resolve-FileRef {
    param(
        [string]$Workspace,
        [string]$RawPath
    )

    $cleaned = Trim-Whitespace $RawPath
    if ([string]::IsNullOrWhiteSpace($cleaned)) { return '' }

    # Remove line number suffixes (#L123 or :123-456)
    $cleaned = $cleaned -replace '#L\d+$', ''
    $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''

    # Make absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
        $cleaned = Join-Path $Workspace $cleaned
    }

    # Normalize path
    if (Test-Path $cleaned) {
        return (Resolve-Path $cleaned -ErrorAction SilentlyContinue).Path
    }
    return $cleaned
}

function Write-File-NoBOM {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-SourceCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw "USERPROFILE is required when CODEX_HOME is not set"
    }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Sync-OptionalFile {
    param(
        [string]$Source,
        [string]$Target
    )

    if (-not (Test-Path $Source -PathType Leaf)) {
        return
    }

    $shouldCopy = -not (Test-Path $Target -PathType Leaf)
    if (-not $shouldCopy) {
        $shouldCopy = (Get-Item $Source).LastWriteTimeUtc -gt (Get-Item $Target).LastWriteTimeUtc
    }

    if ($shouldCopy) {
        Copy-Item -Path $Source -Destination $Target -Force
    }
}

function Initialize-CodexRuntimeHome {
    param([string]$Workspace)

    $sourceHome = Resolve-SourceCodexHome
    $runtimeRoot = Join-Path $Workspace '.tmp'
    $codexHome = Join-Path $runtimeRoot 'codex-home'
    $tempDir = Join-Path $codexHome 'tmp'

    Ensure-Directory -Path $runtimeRoot
    Ensure-Directory -Path $codexHome
    Ensure-Directory -Path $tempDir
    Ensure-Directory -Path (Join-Path $codexHome 'skills')
    Ensure-Directory -Path (Join-Path $codexHome 'sessions')

    Sync-OptionalFile -Source (Join-Path $sourceHome 'auth.json') -Target (Join-Path $codexHome 'auth.json')
    Sync-OptionalFile -Source (Join-Path $sourceHome 'AGENTS.md') -Target (Join-Path $codexHome 'AGENTS.md')

    return @{
        codex_home = $codexHome
        temp_dir = $tempDir
    }
}

function Convert-CertificateToPem {
    param([byte[]]$RawData)

    $base64 = [System.Convert]::ToBase64String($RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
    return @(
        '-----BEGIN CERTIFICATE-----'
        $base64
        '-----END CERTIFICATE-----'
        ''
    ) -join [Environment]::NewLine
}

function Initialize-CodexCaBundle {
    param([string]$CodexHome)

    $caDir = Join-Path $CodexHome 'ca'
    $bundlePath = Join-Path $caDir 'current-user-root.pem'
    Ensure-Directory -Path $caDir

    $certs = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop)
    if ($certs.Count -eq 0) {
        throw "CurrentUser Root certificate store is empty"
    }

    $pemBlocks = foreach ($cert in $certs) {
        Convert-CertificateToPem -RawData $cert.RawData
    }

    Write-File-NoBOM -Path $bundlePath -Content (($pemBlocks -join '') + [Environment]::NewLine)
    return $bundlePath
}

# Show help if requested
if ($Help) {
    Show-Usage
    exit 0
}

# Resolve task text from either positional or named parameter
if ([string]::IsNullOrEmpty($Task) -and -not [string]::IsNullOrEmpty($TaskText)) {
    $Task = $TaskText
}

# Validate workspace
if (-not (Test-Path $Workspace -PathType Container)) {
    Write-Error "[ERROR] Workspace does not exist: $Workspace"
    exit 1
}
$Workspace = (Resolve-Path $Workspace).Path

$codexRuntimeState = Initialize-CodexRuntimeHome -Workspace $Workspace
$env:CODEX_HOME = $codexRuntimeState.codex_home
$env:TEMP = $codexRuntimeState.temp_dir
$env:TMP = $codexRuntimeState.temp_dir
try {
    $env:CODEX_CA_CERTIFICATE = Initialize-CodexCaBundle -CodexHome $codexRuntimeState.codex_home
} catch {
    Remove-Item Env:CODEX_CA_CERTIFICATE -ErrorAction SilentlyContinue
    Write-Host "[preflight] custom CA bundle unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Preflight checks
Test-Command 'codex'
Test-CodexRunnable

# Validate task
$Task = Trim-Whitespace $Task
if ([string]::IsNullOrEmpty($Task)) {
    Write-Error "[ERROR] Request text is empty. Pass a positional arg or -Task."
    exit 1
}

# Prepare output path
if ([string]::IsNullOrEmpty($Output)) {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $skillDir = Split-Path $PSScriptRoot -Parent
    $runtimeDir = Join-Path $skillDir '.runtime'
    if (-not (Test-Path $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    $Output = Join-Path $runtimeDir "$timestamp.md"
}

# Build file context block
$fileBlock = ''
if ($File -and $File.Count -gt 0) {
    $fileBlock = "`nPriority files (read these first before making changes):"
    foreach ($ref in $File) {
        $resolved = Resolve-FileRef -Workspace $Workspace -RawPath $ref
        if (-not [string]::IsNullOrEmpty($resolved)) {
            $existsTag = if (Test-Path $resolved) { 'exists' } else { 'missing' }
            $fileBlock += "`n- $resolved ($existsTag)"
        }
    }
}

# Build prompt
$prompt = $Task
if (-not [string]::IsNullOrEmpty($fileBlock)) {
    $prompt += $fileBlock
}

# Build codex command
$codexArgs = @()

if (-not [string]::IsNullOrEmpty($Session)) {
    # Resume mode: continue a previous session
    # Note: resume only supports -c/--config and --last flags (no --json, --sandbox, etc.)
    $codexArgs = @('exec', '--ignore-user-config', 'resume', '-c', "model_reasoning_effort=`"$Reasoning`"", '-c', 'skip_git_repo_check=true')
    if ($Ephemeral) {
        $codexArgs += '--ephemeral'
    }
    $codexArgs += $Session
} else {
    # New session
    $codexArgs = @('exec', '--ignore-user-config', '--cd', $Workspace, '--skip-git-repo-check', '--json', '-c', "model_reasoning_effort=`"$Reasoning`"")
    if ($ReadOnly) {
        $codexArgs += '--sandbox', 'read-only'
    } elseif (-not [string]::IsNullOrEmpty($Sandbox)) {
        $codexArgs += '--sandbox', $Sandbox
    } elseif ($FullAuto) {
        $codexArgs += '--full-auto'
    }
    if (-not [string]::IsNullOrEmpty($Model)) {
        $codexArgs += '-m', $Model
    }
    if ($Ephemeral) {
        $codexArgs += '--ephemeral'
    }
}

# Create temp files
$tempDir = [System.IO.Path]::GetTempPath()
$guid = [guid]::NewGuid().ToString()
$stderrFile = Join-Path $tempDir "codex_stderr_$guid.txt"
$jsonFile = Join-Path $tempDir "codex_json_$guid.txt"
$promptFile = Join-Path $tempDir "codex_prompt_$guid.txt"

# Cleanup function
$cleanupScript = {
    Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $jsonFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $promptFile -Force -ErrorAction SilentlyContinue
}

try {
    # Write prompt to temp file (UTF-8 without BOM)
    Write-File-NoBOM -Path $promptFile -Content $prompt

    # Initialize json file
    Write-File-NoBOM -Path $jsonFile -Content ''

    # Use synchronous stdout reads for reliable JSON capture on Windows. PowerShell
    # event jobs can drop fast final lines before the wrapper parses them.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $useCmdWrapper = $IsWindows -or $PSVersionTable.PSVersion.Major -le 5
    if ($useCmdWrapper) {
        $quotedPromptFile = '"' + $promptFile + '"'
        $quotedStderrFile = '"' + $stderrFile + '"'
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/c codex ' + ($codexArgs -join ' ') + ' < ' + $quotedPromptFile + ' 2> ' + $quotedStderrFile
    } else {
        $psi.FileName = 'codex'
        $psi.Arguments = $codexArgs -join ' '
    }
    $psi.WorkingDirectory = $Workspace
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = -not $useCmdWrapper
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = -not $useCmdWrapper
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    if ($psi.RedirectStandardError) {
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    # StringBuilder for collecting output
    $jsonOutput = New-Object System.Text.StringBuilder
    $isResumeMode = -not [string]::IsNullOrEmpty($Session)
    $textOutput = New-Object System.Text.StringBuilder
    $stderrText = ''
    $stderrTask = $null

    try {
        # Start process
        $process.Start() | Out-Null

        if (-not $useCmdWrapper) {
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }

        if (-not $useCmdWrapper) {
            # Non-Windows path still uses stdin directly.
            $process.StandardInput.Write($prompt)
            $process.StandardInput.Close()
        }

        while (($line = $process.StandardOutput.ReadLine()) -ne $null) {
            # Strip terminal artifacts
            $line = $line -replace "`r", ''
            $line = $line -replace [char]4, ''

            if ([string]::IsNullOrEmpty($line)) {
                continue
            }

            if ($isResumeMode) {
                $textOutput.AppendLine($line) | Out-Null
                $preview = $line
                if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                Write-Host "[codex] $preview" -ForegroundColor Gray
                continue
            }

            if (-not $line.StartsWith('{')) {
                continue
            }

            $jsonOutput.AppendLine($line) | Out-Null

            if ($line -match '"item\.started"' -and $line -match '"command_execution"') {
                try {
                    $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $cmd = $json.item.command
                    if ($cmd) {
                        $cmd = $cmd -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                        if ($cmd.Length -gt 100) { $cmd = $cmd.Substring(0, 100) }
                        Write-Host "[codex] > $cmd" -ForegroundColor Gray
                    }
                } catch {}
            }

            if ($line -match '"item\.completed"' -and $line -match '"agent_message"') {
                try {
                    $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    $text = $json.item.text
                    if ($text) {
                        $preview = $text.Split("`n")[0]
                        if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                        Write-Host "[codex] $preview" -ForegroundColor Gray
                    }
                } catch {}
            }
        }

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        if ($useCmdWrapper) {
            if (Test-Path -LiteralPath $stderrFile -PathType Leaf) {
                $stderrText = Get-Content -LiteralPath $stderrFile -Raw -Encoding utf8
            }
        } elseif ($null -ne $stderrTask) {
            $stderrText = $stderrTask.GetAwaiter().GetResult()
        }
        $process.Dispose()
    }

    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        foreach ($stderrLine in ($stderrText -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($stderrLine)) {
                Write-Host $stderrLine -ForegroundColor Yellow
            }
        }
    }

    # Process output based on mode
    $threadId = $null
    $outputContent = @()

    if ($isResumeMode) {
        # Resume mode: plain text output
        $textContent = $textOutput.ToString().Trim()

        # Check for errors
        $hasValidOutput = -not [string]::IsNullOrWhiteSpace($textContent)

        if ($stderrText -match '\[ERROR\]' -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex command failed"
            Write-Error $stderrText
            exit 1
        }

        if ($exitCode -ne 0 -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex exited with code $exitCode"
            exit 1
        }

        # Use session ID from parameter
        $threadId = $Session
        if (-not [string]::IsNullOrWhiteSpace($textContent)) {
            $outputContent += $textContent
        }
    } else {
        # New session mode: JSON output
        $jsonText = $jsonOutput.ToString()
        Write-File-NoBOM -Path $jsonFile -Content $jsonText

        # Check for errors - but only fail if no valid output was received
        $hasValidOutput = -not [string]::IsNullOrWhiteSpace($jsonText) -and $jsonText -match '"thread_id"'

        if ($stderrText -match '\[ERROR\]' -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex command failed"
            Write-Error $stderrText
            exit 1
        }

        if ($exitCode -ne 0 -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex exited with code $exitCode"
            exit 1
        }

        # Extract thread_id and messages from JSON stream
        if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
            # Find thread_id
            if ($jsonText -match '"thread_id"\s*:\s*"([^"]+)"') {
                $threadId = $matches[1]
            }

            # Parse JSON lines using PowerShell native parsing (more reliable on Windows)
            $jsonLines = $jsonText -split "`n" | Where-Object { $_.Trim() -and $_.TrimStart().StartsWith('{') }

            foreach ($line in $jsonLines) {
                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if (-not $obj) { continue }

                    # Process completed items
                    if ($obj.type -eq 'item.completed' -and $obj.item) {
                        $item = $obj.item

                        # Agent messages
                        if ($item.type -eq 'agent_message' -and $item.text) {
                            $outputContent += $item.text
                        }

                        # Command executions
                        if ($item.type -eq 'command_execution' -and $item.command) {
                            $cmd = $item.command -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                            $cmdPreview = $cmd.Substring(0, [Math]::Min(200, $cmd.Length))
                            $outPreview = ''
                            if ($item.aggregated_output) {
                                $outPreview = $item.aggregated_output.Substring(0, [Math]::Min(500, $item.aggregated_output.Length))
                            }
                            $outputContent += "### Shell: ``$cmdPreview```n$outPreview"
                        }

                        # Tool calls (file operations)
                        if ($item.type -eq 'tool_call' -and $item.name) {
                            $args = $null
                            try {
                                $args = $item.arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
                            } catch {}

                            if ($item.name -eq 'write_file' -and $args.path) {
                                $outputContent += "### File written: $($args.path)"
                            }
                            if ($item.name -eq 'patch_file' -and $args.path) {
                                $outputContent += "### File patched: $($args.path)"
                            }
                            if ($item.name -eq 'shell' -and $args.command) {
                                $cmdPreview = $args.command.Substring(0, [Math]::Min(200, $args.command.Length))
                                $outPreview = ''
                                if ($item.output) {
                                    $outPreview = $item.output.Substring(0, [Math]::Min(500, $item.output.Length))
                                }
                                $outputContent += "### Shell: ``$cmdPreview```n$outPreview"
                            }
                        }
                    }
                } catch {
                    # Skip malformed lines
                }
            }
        }
    }

    # Ensure output directory exists
    $outputDir = Split-Path $Output -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Write output
    if ($outputContent.Count -gt 0) {
        Write-File-NoBOM -Path $Output -Content ($outputContent -join "`n")
    } else {
        Write-File-NoBOM -Path $Output -Content "(no response from codex)"
    }

    # Output results
    if (-not [string]::IsNullOrEmpty($threadId)) {
        Write-Output "session_id=$threadId"
    }
    Write-Output "output_path=$Output"

} finally {
    & $cleanupScript
}
