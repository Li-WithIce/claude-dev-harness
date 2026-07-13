# Shared fixture helpers; consumers that call failure-reporting helpers must provide Add-Failure.

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Convert-CodePointsToString {
    param([int[]]$CodePoints)

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function Get-LastExitCodeOrZero {
    $variable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $variable -and $variable.Value -is [int]) {
        return $variable.Value
    }

    return 0
}

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments = @{},
        [string]$WorkingDirectory = ''
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLocation = $null
    try {
        $env:USERPROFILE = $UserProfile
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{
            Output   = @($output | ForEach-Object { [string]$_ })
            ExitCode = (Get-LastExitCodeOrZero)
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }
        $env:USERPROFILE = $originalUserProfile
    }
}

function Start-RepoProcess {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['USERPROFILE'] = $UserProfile
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + $Arguments) {
        $psi.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut  = $process.StandardOutput.ReadToEndAsync()
        StdErr  = $process.StandardError.ReadToEndAsync()
    }
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8)
}

function Get-StatusLineValue {
    param(
        $Output,
        [string]$Prefix
    )

    $line = @($Output | Where-Object { [string]$_ -match ("^{0}:\s+" -f [regex]::Escape($Prefix)) } | Select-Object -First 1)
    if ($line.Count -eq 0) {
        return $null
    }

    return ([string]$line[0] -replace ("^{0}:\s+" -f [regex]::Escape($Prefix)), '')
}

function Assert-SingleLineJson {
    param(
        [string]$JsonText,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($JsonText) -or $JsonText -match "\r?\n") {
        Add-Failure ("{0} stdout should be a single JSON line" -f $Label)
        return $null
    }

    try {
        return ($JsonText | ConvertFrom-Json)
    } catch {
        Add-Failure ("{0} stdout should be valid JSON: {1}" -f $Label, $_.Exception.Message)
        return $null
    }
}

function Copy-RepoPathToFixture {
    param(
        [string]$SourceRoot,
        [string]$FixtureRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $destinationPath = Join-Path $FixtureRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function Test-FileHasUtf8Bom {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}
