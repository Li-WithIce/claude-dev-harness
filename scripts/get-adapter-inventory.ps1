[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ClassificationPath = 'kernel-component-classification.json',
    [string]$OutputPath = 'adapter-inventory.json',
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.CanonicalJson.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Hashing.psm1') -Force -ErrorAction Stop

$script:Utf8Strict = [Text.UTF8Encoding]::new($false,$true)
$script:ExcludedPowerShellTokens = @(
    [Management.Automation.Language.TokenKind]::Comment,
    [Management.Automation.Language.TokenKind]::NewLine,
    [Management.Automation.Language.TokenKind]::LineContinuation,
    [Management.Automation.Language.TokenKind]::EndOfInput
)
$script:OperationCommands = [ordered]@{
    'Invoke-HarnessAdapterPreflightAction' = 'preflight_action'
    'Invoke-HarnessAdapterControlledWrite' = 'controlled_write'
    'Invoke-HarnessAdapterPrepareDelegation' = 'prepare_delegation'
    'Invoke-HarnessAdapterCommitDelegation' = 'commit_delegation'
}
$script:ExpectedOperations = [ordered]@{
    'runtime-hooks/claude/codex-pretooluse-launcher.ps1' = @()
    'runtime-hooks/claude/pretooluse.ps1' = @('preflight_action')
    'runtime-hooks/claude/stop.js' = @()
    'runtime-hooks/claude/userpromptsubmit.js' = @()
    'runtime-hooks/claude/workspace-resolver.js' = @()
    'scripts/harness-write-mcp.ps1' = @('controlled_write')
    'scripts/invoke-harness-skill-dispatcher.ps1' = @()
    'scripts/invoke-harness-skill-supervisor.ps1' = @()
    'scripts/invoke-harness-skill.ps1' = @('commit_delegation','prepare_delegation')
}

function Get-OrdinalSortedStrings {
    param([string[]]$Values)

    $items = [Collections.Generic.List[string]]::new()
    foreach ($value in $Values) { $items.Add($value) }
    $items.Sort([StringComparer]::Ordinal)
    return $items.ToArray()
}

function Get-NormalizedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalized = $Text.Replace("`r`n","`n").Replace("`r","`n")
    return $normalized.TrimEnd([char[]]"`r`n") + "`n"
}

function Read-StrictDocument {
    param([string]$Path,[string]$SchemaPath,[string]$Label)

    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $Path -Label $Label -MustExist File
    $schema = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $SchemaPath -Label "$Label Schema" -MustExist File
    $raw = [IO.File]::ReadAllText($fullPath,$script:Utf8Strict)
    try {
        if (-not (Test-Json -Json $raw -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue)) {
            throw "$Label failed Schema validation"
        }
        return $raw | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    } catch {
        throw "$Label is invalid: $($_.Exception.Message)"
    }
}

function Assert-WorktreeMatchesIndex {
    param([string]$Path,[string]$Label)

    $null = & git -c core.fsmonitor=false -C $RepoRoot diff --quiet --no-ext-diff -- $Path
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 1) { throw "$Label has unstaged bytes and cannot enter an index-bound inventory: $Path" }
    if ($exitCode -ne 0) { throw "$Label worktree/index comparison failed: $Path" }
}

function Get-IndexBlobSha256 {
    param([string]$Path)

    $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-c','core.fsmonitor=false','-C',$RepoRoot,'show',(':' + $Path))) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Unable to start Git for index blob: $Path" }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $buffer = [IO.MemoryStream]::new()
        try {
            $process.StandardOutput.BaseStream.CopyTo($buffer)
            [byte[]]$bytes = $buffer.ToArray()
        } finally { $buffer.Dispose() }
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read Git index blob: $Path`: $($stderr.Trim())" }
        return Get-HarnessSha256Bytes -Bytes $bytes
    } finally { $process.Dispose() }
}

function Get-SourceLines {
    param([string]$Path)

    $text = [IO.File]::ReadAllText($Path,$script:Utf8Strict).Replace("`r`n","`n").Replace("`r","`n")
    [string[]]$lines = $text.Split([char]10)
    if ($text.EndsWith("`n",[StringComparison]::Ordinal)) {
        $lines = if ($lines.Count -le 1) { @() } else { @($lines[0..($lines.Count - 2)]) }
    }
    return [pscustomobject]@{Text=$text;Lines=$lines}
}

function Get-PowerShellAdapterMetrics {
    param([string]$Path)

    $source = Get-SourceLines -Path $Path
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw "PowerShell parse failed: $(@($errors | ForEach-Object Message) -join '; ')" }
    $executable = [Collections.Generic.HashSet[int]]::new()
    $separatorsByLine = @{}
    foreach ($token in @($tokens)) {
        if ($token.Kind -eq [Management.Automation.Language.TokenKind]::Semi) {
            $lineKey = [int]$token.Extent.StartLineNumber
            $separatorsByLine[$lineKey] = 1 + $(if($separatorsByLine.ContainsKey($lineKey)){[int]$separatorsByLine[$lineKey]}else{0})
        }
        if ($script:ExcludedPowerShellTokens -contains $token.Kind) { continue }
        for ($line = $token.Extent.StartLineNumber; $line -le $token.Extent.EndLineNumber; $line++) {
            [void]$executable.Add($line)
        }
    }
    $operations = [Collections.Generic.List[string]]::new()
    foreach ($command in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true))) {
        $name = [string]$command.GetCommandName()
        if ($script:OperationCommands.Contains($name)) { $operations.Add([string]$script:OperationCommands[$name]) }
    }
    return [pscustomobject]@{
        Physical=$source.Lines.Count
        Nonblank=@($source.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Executable=$executable.Count
        MaximumLineLength=[int](($source.Lines | ForEach-Object Length | Measure-Object -Maximum).Maximum)
        MaximumStatementSeparators=[int](($separatorsByLine.Values | Measure-Object -Maximum).Maximum)
        Operations=Get-OrdinalSortedStrings -Values @($operations | Select-Object -Unique)
        Text=$source.Text
    }
}

function Get-JavaScriptAdapterMetrics {
    param([string]$Path)

    $source = Get-SourceLines -Path $Path
    $inBlockComment = $false
    $inString = $false
    [char]$quote = [char]0
    $executable = 0
    foreach ($line in $source.Lines) {
        $hasToken = $inString
        $escaped = $false
        for ($index = 0; $index -lt $line.Length; $index++) {
            $character = $line[$index]
            $next = if ($index + 1 -lt $line.Length) { $line[$index + 1] } else { [char]0 }
            if ($inBlockComment) {
                if ($character -eq '*' -and $next -eq '/') { $inBlockComment=$false;$index++ }
                continue
            }
            if ($inString) {
                $hasToken = $true
                if ($escaped) { $escaped=$false;continue }
                if ($character -eq '\') { $escaped=$true;continue }
                if ($character -eq $quote) { $inString=$false;$quote=[char]0 }
                continue
            }
            if ([char]::IsWhiteSpace($character)) { continue }
            if ($character -eq '/' -and $next -eq '/') { break }
            if ($character -eq '/' -and $next -eq '*') { $inBlockComment=$true;$index++;continue }
            $hasToken = $true
            if ($character -in @("'",'"','`')) { $inString=$true;$quote=$character }
        }
        if ($hasToken) { $executable++ }
    }
    if ($inBlockComment -or $inString) { throw 'JavaScript lexical scan ended inside an unterminated token' }
    return [pscustomobject]@{
        Physical=$source.Lines.Count
        Nonblank=@($source.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Executable=$executable
        MaximumLineLength=[int](($source.Lines | ForEach-Object Length | Measure-Object -Maximum).Maximum)
        MaximumStatementSeparators=0
        Operations=@()
        Text=$source.Text
    }
}

function Assert-AdapterAuthorityBoundary {
    param([string]$Path,[string]$Text,[string[]]$Operations)

    foreach ($forbidden in @(
        'Get-HarnessUtf8TextSha256','Get-HarnessSha256Bytes','Get-HarnessFileSha256',
        'Get-HarnessNormalizedTextSha256','Invoke-HarnessControlledWrite','Assert-HarnessProtectedAction',
        'Enter-LitePlanMutex','Write-LiteUtf8BomAtomic','Harness.Hashing.psm1','Harness.ProtectedAction.psm1'
    )) {
        if ($Text.Contains($forbidden,[StringComparison]::Ordinal)) { throw "$Path contains forbidden Adapter authority: $forbidden" }
    }
    if ($Text -match '(?im)^\s*(?:#|//)\s*(?:@generated|generated file|minified)') {
        throw "$Path is generated or compressed source"
    }
    $expected = [string[]]$script:ExpectedOperations[$Path]
    if (($expected -join "`0") -cne ($Operations -join "`0")) {
        throw "$Path Kernel API operation set is invalid"
    }
    if ($Path -ceq 'runtime-hooks/claude/pretooluse.ps1' -and -not $Text.Contains('Harness.AdapterAction.psm1',[StringComparison]::Ordinal)) {
        throw 'PreToolUse Adapter does not bind the K1 action API'
    }
    if ($Path -ceq 'scripts/invoke-harness-skill.ps1' -and
        (-not $Text.Contains('invoke-harness-skill-dispatcher.ps1',[StringComparison]::Ordinal) -or
         -not $Text.Contains('invoke-harness-skill-supervisor.ps1',[StringComparison]::Ordinal))) {
        throw 'skill Adapter process bridge is incomplete'
    }
}

$classificationRelative = (Get-HarnessRelativePath -WorkspaceRoot $RepoRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $ClassificationPath -Label 'Adapter classification' -MustExist File)).Replace('\','/')
Assert-WorktreeMatchesIndex -Path $classificationRelative -Label 'Adapter classification'
$classification = Read-StrictDocument -Path $classificationRelative -SchemaPath 'schemas/kernel-component-classification.schema.json' -Label 'Adapter classification'
$classified = @($classification.components | Where-Object { [string]$_.layer -ceq 'a3-adapter' })
if ($classified.Count -ne 9) { throw "adapter classification must contain exactly nine A3 paths; actual=$($classified.Count)" }
$pathList = Get-OrdinalSortedStrings -Values @($classified | ForEach-Object { [string]$_.path })
if (@($pathList | Select-Object -Unique).Count -ne $pathList.Count) { throw 'adapter classification contains duplicate paths' }
if (@(Compare-Object @($script:ExpectedOperations.Keys) $pathList -CaseSensitive).Count) {
    throw 'adapter classification does not match the checked nine-path contract'
}

$adapters = [Collections.Generic.List[object]]::new()
foreach ($path in $pathList) {
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $path -Label 'Adapter source' -MustExist File
    $null = & git -C $RepoRoot ls-files --error-unmatch -- $path 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Adapter source is not tracked: $path" }
    Assert-WorktreeMatchesIndex -Path $path -Label 'Adapter source'
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $metrics = switch ($extension) {
        '.ps1' { Get-PowerShellAdapterMetrics -Path $fullPath }
        '.js' { Get-JavaScriptAdapterMetrics -Path $fullPath }
        default { throw "unsupported Adapter source language: $path" }
    }
    Assert-AdapterAuthorityBoundary -Path $path -Text $metrics.Text -Operations $metrics.Operations
    if ($metrics.Executable -ge 200) { throw "$path has $($metrics.Executable) executable LOC; maximum is 199" }
    if ($metrics.MaximumLineLength -gt 300) { throw "$path contains a physical line longer than 300 characters" }
    if ($metrics.MaximumStatementSeparators -gt 2) { throw "$path uses statement packing that invalidates Adapter LOC accounting" }
    $component = @($classified | Where-Object { [string]$_.path -ceq $path })[0]
    $adapters.Add([ordered]@{
        path=$path
        layer='a3-adapter'
        language=$(if($extension -ceq '.ps1'){'powershell'}else{'javascript'})
        raw_sha256=Get-IndexBlobSha256 -Path $path
        physical_loc=[int]$metrics.Physical
        nonblank_loc=[int]$metrics.Nonblank
        executable_loc=[int]$metrics.Executable
        maximum_line_length=[int]$metrics.MaximumLineLength
        tcb_included=[bool]$component.tcb_included
        kernel_api_operations=@($metrics.Operations)
    })
}

$body = [ordered]@{
    schema_version='adapter-inventory/v1'
    generator_contract_version='adapter-inventory-generator/v1'
    source_basis='git-index-blob/v1'
    classification=[ordered]@{path=$classificationRelative;sha256=Get-IndexBlobSha256 -Path $classificationRelative}
    metric_contract=[ordered]@{
        powershell='powershell-token-lines/v1'
        javascript='javascript-lexical-token-lines/v1'
        maximum_executable_loc=199
        maximum_physical_line_length=300
    }
    adapters=$adapters.ToArray()
    totals=[ordered]@{
        adapter_count=$adapters.Count
        powershell_count=@($adapters | Where-Object language -ceq 'powershell').Count
        javascript_count=@($adapters | Where-Object language -ceq 'javascript').Count
        executable_loc=[int](($adapters | ForEach-Object executable_loc | Measure-Object -Sum).Sum)
        maximum_adapter_executable_loc=[int](($adapters | ForEach-Object executable_loc | Measure-Object -Maximum).Maximum)
        threshold_breaches=0
    }
    digest_algorithm='canonical-json/v1'
}
$document = [ordered]@{}
foreach ($key in $body.Keys) { $document[$key]=$body[$key] }
$document.inventory_digest = Get-HarnessCanonicalJsonSha256 -JsonBytes $script:Utf8Strict.GetBytes(($body | ConvertTo-Json -Depth 30 -Compress))
$json = Get-NormalizedText -Text ($document | ConvertTo-Json -Depth 30)
$schemaPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path 'schemas/adapter-inventory.schema.json' -Label 'Adapter inventory Schema' -MustExist File
if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
    throw 'generated adapter-inventory/v1 failed Schema validation'
}
$resolvedOutput = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $OutputPath -Label 'Adapter inventory output' -AllowMissing
if ($Check) {
    if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Leaf)) { throw 'tracked adapter inventory is missing' }
    $tracked = Get-NormalizedText -Text ([IO.File]::ReadAllText($resolvedOutput,$script:Utf8Strict))
    if ($tracked -cne $json) { throw 'tracked adapter inventory is stale' }
    Write-Output "Adapter inventory matches tracked content; adapters=$($adapters.Count); maximum_executable_loc=$($body.totals.maximum_adapter_executable_loc)"
    exit 0
}
[void](Write-HarnessAtomicText -WorkspaceRoot $RepoRoot -Path $resolvedOutput -Content $json)
Write-Output "Wrote adapter inventory: $resolvedOutput"
