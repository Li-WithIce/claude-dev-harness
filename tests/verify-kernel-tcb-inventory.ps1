[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure { param([string]$Message) $failures.Add($Message) }
function Check {
    param([bool]$Condition, [string]$Success, [string]$Failure)
    if ($Condition) { Write-Output "[PASS] $Success" } else { Write-Output "[FAIL] $Failure"; Add-Failure $Failure }
}
function Get-OrdinalStrings {
    param([object[]]$Values)
    [string[]]$result = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}
function Test-OrdinalSorted {
    param([string[]]$Values)
    for ($index = 1; $index -lt $Values.Count; $index++) {
        if ([StringComparer]::Ordinal.Compare($Values[$index - 1], $Values[$index]) -ge 0) { return $false }
    }
    return $true
}
function Invoke-InventoryGenerator {
    param(
        [string]$RootsPath,
        [string]$OutputPath = '',
        [switch]$CheckMode,
        [string]$WorkingDirectory = ''
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('-RepoRoot', $RepoRoot, '-RootsPath', $RootsPath)) { $arguments.Add($argument) }
    if ($CheckMode) { $arguments.Add('-Check') } else { $arguments.Add('-OutputPath'); $arguments.Add($OutputPath) }
    $started = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath (Join-Path $RepoRoot 'scripts\get-kernel-tcb-inventory.ps1') -Arguments $arguments.ToArray() -WorkingDirectory $WorkingDirectory
    try {
        $exited = $started.Process.WaitForExit(30000)
        if (-not $exited) { $started.Process.Kill($true); [void]$started.Process.WaitForExit(5000) }
        return [pscustomobject]@{
            Exited = $exited
            ExitCode = if ($exited) { $started.Process.ExitCode } else { -1 }
            StdOut = $started.StdOut.GetAwaiter().GetResult().Trim()
            StdErr = $started.StdErr.GetAwaiter().GetResult().Trim()
        }
    } finally {
        $started.Process.Dispose()
    }
}
function Get-StatusSnapshot {
    return @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all)
}
function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}
function ConvertTo-LfBytes {
    param([byte[]]$Bytes)
    $normalized = [System.Collections.Generic.List[byte]]::new($Bytes.Length)
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 0x0D) {
            if ($index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 0x0A) { $index++ }
            $normalized.Add(0x0A)
        } else {
            $normalized.Add($Bytes[$index])
        }
    }
    return ,$normalized.ToArray()
}
function Get-StringLeaves {
    param([object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { Write-Output $Value; return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { Get-StringLeaves -Value $Value[$key] }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Get-StringLeaves -Value $item }
    }
}
function Get-PowerShellSourceDensity {
    param([string[]]$Paths, [string]$Revision = '')

    $tokenCount = 0
    $statementCount = 0
    foreach ($path in $Paths) {
        if ($path -notmatch '\.psm?1$') { continue }
        if ($Revision) {
            $text = @(& git -C $RepoRoot show "$Revision`:$path" 2>$null) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "unable to read TK-07 Base source: $path" }
        } else {
            $text = [IO.File]::ReadAllText((Join-Path $RepoRoot $path))
        }
        $text = $text.TrimStart([char]0xFEFF)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw "PowerShell density parse failed: $path" }
        $tokenCount += @($tokens | Where-Object { $_.Kind -cnotin @('Comment','NewLine','LineContinuation','EndOfInput') }).Count
        $statementCount += @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.StatementAst] }, $true)).Count
    }
    return [pscustomobject]@{ Tokens=$tokenCount; Statements=$statementCount }
}
function Get-Tk07AddedLines {
    param([string]$BaseRevision, [string[]]$Paths)

    $added = [Collections.Generic.Dictionary[string,Collections.Generic.HashSet[int]]]::new([StringComparer]::Ordinal)
    $currentPath = ''
    $currentLine = 0
    $inHunk = $false
    foreach ($line in @(& git -C $RepoRoot diff --unified=0 --no-ext-diff $BaseRevision -- @Paths)) {
        if ($line.StartsWith('diff ',[StringComparison]::Ordinal)) {
            $inHunk = $false
            continue
        }
        if ($line -match '^\+\+\+ b/(.+)$') {
            $currentPath = $Matches[1].Replace('\','/')
            if (-not $added.ContainsKey($currentPath)) { $added[$currentPath] = [Collections.Generic.HashSet[int]]::new() }
            continue
        }
        if ($line -match '^@@ .* \+(\d+)(?:,\d+)? @@') {
            $currentLine = [int]$Matches[1]
            $inHunk = $true
            continue
        }
        if (-not $inHunk) { continue }
        if ($line.StartsWith('+',[StringComparison]::Ordinal) -and -not $line.StartsWith('+++',[StringComparison]::Ordinal)) {
            if ($currentPath) { [void]$added[$currentPath].Add($currentLine) }
            $currentLine++
            continue
        }
        if (-not $line.StartsWith('-',[StringComparison]::Ordinal)) { $currentLine++ }
    }

    return ,$added
}
function Get-Tk07AddedLineDensity {
    param([string]$BaseRevision, [string[]]$Paths)

    $added = Get-Tk07AddedLines -BaseRevision $BaseRevision -Paths $Paths

    $maximumLength = 0
    $maximumSeparators = 0
    foreach ($path in $Paths) {
        if ($path -notmatch '\.psm?1$' -or -not $added.ContainsKey($path)) { continue }
        $lines = [IO.File]::ReadAllLines((Join-Path $RepoRoot $path))
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $path), [ref]$tokens, [ref]$errors)
        if (@($errors).Count) { throw "PowerShell density parse failed: $path" }
        $separators = @{}
        foreach ($token in @($tokens | Where-Object Kind -eq 'Semi')) {
            $lineNumber = [int]$token.Extent.StartLineNumber
            $separators[$lineNumber] = 1 + $(if ($separators.ContainsKey($lineNumber)) { [int]$separators[$lineNumber] } else { 0 })
        }
        foreach ($lineNumber in $added[$path]) {
            $maximumLength = [Math]::Max($maximumLength, $lines[$lineNumber - 1].Length)
            $maximumSeparators = [Math]::Max($maximumSeparators, $(if ($separators.ContainsKey($lineNumber)) { [int]$separators[$lineNumber] } else { 0 }))
        }
    }
    return [pscustomobject]@{ MaximumLineLength=$maximumLength; MaximumStatementSeparators=$maximumSeparators }
}
function Get-Tk07LayoutIntegrity {
    param([string]$BaseRevision, [string[]]$BasePaths, [string[]]$CurrentPaths)

    $basePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $BasePaths) { [void]$basePathSet.Add($path) }
    $added = Get-Tk07AddedLines -BaseRevision $BaseRevision -Paths $CurrentPaths
    $paramSpans = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::OrdinalIgnoreCase)
    $paramShrink = [Collections.Generic.List[string]]::new()
    $packedStatements = [Collections.Generic.List[string]]::new()
    $packedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($path in $CurrentPaths) {
        if ($path -notmatch '\.psm?1$') { continue }
        $currentFullPath = Join-Path $RepoRoot $path
        $currentTokens = $null
        $currentErrors = $null
        $currentAst = [Management.Automation.Language.Parser]::ParseFile($currentFullPath, [ref]$currentTokens, [ref]$currentErrors)
        if (@($currentErrors).Count) { throw "PowerShell layout parse failed: $path" }

        if ($basePathSet.Contains($path)) {
            $baseText = (@(& git -C $RepoRoot show "$BaseRevision`:$path" 2>$null) -join "`n").TrimStart([char]0xFEFF)
            if ($LASTEXITCODE -ne 0) { throw "unable to read TK-07 Base source: $path" }
            $baseTokens = $null
            $baseErrors = $null
            $baseAst = [Management.Automation.Language.Parser]::ParseInput($baseText, [ref]$baseTokens, [ref]$baseErrors)
            if (@($baseErrors).Count) { throw "PowerShell Base layout parse failed: $path" }

            $baseParamBlocks = [Collections.Generic.List[object]]::new()
            if ($null -ne $baseAst.ParamBlock) {
                $baseParamBlocks.Add([pscustomobject]@{ Name='<script>'; ParamBlock=$baseAst.ParamBlock })
            }
            foreach ($function in @($baseAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
                if ($null -ne $function.Body.ParamBlock) {
                    $baseParamBlocks.Add([pscustomobject]@{ Name=$function.Name; ParamBlock=$function.Body.ParamBlock })
                }
            }
            foreach ($entry in $baseParamBlocks) {
                $signature = @($entry.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() }) -join ','
                $key = "$path`0$($entry.Name)`0$signature"
                $span = 1 + $entry.ParamBlock.Extent.EndLineNumber - $entry.ParamBlock.Extent.StartLineNumber
                if (-not $paramSpans.ContainsKey($key) -or $span -gt $paramSpans[$key]) { $paramSpans[$key] = $span }
            }

            $currentParamBlocks = [Collections.Generic.List[object]]::new()
            if ($null -ne $currentAst.ParamBlock) {
                $currentParamBlocks.Add([pscustomobject]@{ Name='<script>'; ParamBlock=$currentAst.ParamBlock })
            }
            foreach ($function in @($currentAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
                if ($null -ne $function.Body.ParamBlock) {
                    $currentParamBlocks.Add([pscustomobject]@{ Name=$function.Name; ParamBlock=$function.Body.ParamBlock })
                }
            }
            foreach ($entry in $currentParamBlocks) {
                $signature = @($entry.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() }) -join ','
                $key = "$path`0$($entry.Name)`0$signature"
                if (-not $paramSpans.ContainsKey($key)) { continue }
                $span = 1 + $entry.ParamBlock.Extent.EndLineNumber - $entry.ParamBlock.Extent.StartLineNumber
                if ($span -lt $paramSpans[$key]) {
                    $paramShrink.Add("$path::$($entry.Name) base=$($paramSpans[$key]) current=$span")
                }
            }
        }

        if (-not $added.ContainsKey($path)) { continue }
        $blocks = @($currentAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.NamedBlockAst] -or
                $node -is [Management.Automation.Language.StatementBlockAst]
        }, $true))
        foreach ($block in $blocks) {
            foreach ($group in @($block.Statements | Group-Object { $_.Extent.StartLineNumber })) {
                $lineNumber = [int]$group.Name
                if ($group.Count -le 1 -or -not $added[$path].Contains($lineNumber)) { continue }
                $packedKey = "$path`0$lineNumber"
                if ($packedKeys.Add($packedKey)) {
                    $packedStatements.Add("$path`:$lineNumber statements=$($group.Count)")
                }
            }
        }
    }

    return [pscustomobject]@{
        ParamBlockShrinkCount=$paramShrink.Count
        PackedSiblingStatementLineCount=$packedStatements.Count
        Details=@($paramShrink) + @($packedStatements)
    }
}

$generatorPath = Join-Path $RepoRoot 'scripts\get-kernel-tcb-inventory.ps1'
$rootsPath = Join-Path $RepoRoot 'kernel-tcb-roots.json'
$inventoryPath = Join-Path $RepoRoot 'kernel-tcb-inventory.json'
$classificationPath = Join-Path $RepoRoot 'kernel-component-classification.json'
$rootsSchemaPath = Join-Path $RepoRoot 'schemas\kernel-tcb-roots.schema.json'
$inventorySchemaPath = Join-Path $RepoRoot 'schemas\kernel-tcb.schema.json'
$classificationSchemaPath = Join-Path $RepoRoot 'schemas\kernel-component-classification.schema.json'

foreach ($path in @($generatorPath, $rootsPath, $inventoryPath, $classificationPath, $rootsSchemaPath, $inventorySchemaPath, $classificationSchemaPath)) {
    Check (Test-Path -LiteralPath $path -PathType Leaf) "$([IO.Path]::GetFileName($path)) exists" "$path is missing"
}

$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($generatorPath, [ref]$tokens, [ref]$parseErrors)
Check (@($parseErrors).Count -eq 0) 'TCB generator parses' "TCB generator parse failed: $(@($parseErrors | ForEach-Object Message) -join '; ')"
Check (Test-FileHasUtf8Bom -Path $generatorPath) 'TCB generator follows the PowerShell UTF-8 BOM convention' 'TCB generator lacks the required UTF-8 BOM'

$rootsText = Get-Content -LiteralPath $rootsPath -Raw -Encoding utf8
$inventoryText = Get-Content -LiteralPath $inventoryPath -Raw -Encoding utf8
$classificationText = Get-Content -LiteralPath $classificationPath -Raw -Encoding utf8
try { $rootsValid = Test-Json -Json $rootsText -SchemaFile $rootsSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $rootsValid = $false; Add-Failure $_.Exception.Message }
try { $inventoryValid = Test-Json -Json $inventoryText -SchemaFile $inventorySchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $inventoryValid = $false; Add-Failure $_.Exception.Message }
try { $classificationValid = Test-Json -Json $classificationText -SchemaFile $classificationSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $classificationValid = $false; Add-Failure $_.Exception.Message }
Check $rootsValid 'TCB roots satisfy the strict Schema' 'TCB roots failed Schema validation'
Check $inventoryValid 'tracked TCB inventory satisfies the strict Schema' 'tracked TCB inventory failed Schema validation'
Check $classificationValid 'component classification satisfies the strict Schema' 'component classification failed Schema validation'

$roots = $rootsText | ConvertFrom-Json -AsHashtable -Depth 100
$inventory = $inventoryText | ConvertFrom-Json -AsHashtable -Depth 100
$classification = $classificationText | ConvertFrom-Json -AsHashtable -Depth 100
[byte[]]$trackedBytes = ConvertTo-LfBytes -Bytes ([IO.File]::ReadAllBytes($inventoryPath))
$lineEndingLf = [Text.UTF8Encoding]::new($false).GetBytes("alpha`nbeta`n")
$lineEndingCrlf = [Text.UTF8Encoding]::new($false).GetBytes("alpha`r`nbeta`r`n")
Check (Test-BytesEqual -Left $lineEndingLf -Right (ConvertTo-LfBytes -Bytes $lineEndingCrlf)) 'inventory comparison normalizes checkout CRLF to canonical LF' 'inventory comparison is checkout-line-ending dependent'
$trackedDigestBefore = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash
$statusBeforeCheck = @(Get-StatusSnapshot)
$checkRun = Invoke-InventoryGenerator -RootsPath 'kernel-tcb-roots.json' -CheckMode
$statusAfterCheck = @(Get-StatusSnapshot)
$trackedDigestAfter = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash
Check ($checkRun.Exited -and $checkRun.ExitCode -eq 0 -and [string]::IsNullOrEmpty($checkRun.StdErr) -and $checkRun.StdOut -match '(?m)^STATUS: PASS\r?$') 'generator -Check matches tracked bytes' "generator -Check failed: exit=$($checkRun.ExitCode) stderr=[$($checkRun.StdErr)]"
Check ($trackedDigestBefore -ceq $trackedDigestAfter -and ($statusBeforeCheck -join "`n") -ceq ($statusAfterCheck -join "`n")) 'generator -Check performs zero repository writes' 'generator -Check changed tracked bytes or repository status'

$scratchRelative = ".assistant/runtime/tk00-inventory-verifier-$([guid]::NewGuid().ToString('N'))"
$scratch = Join-Path $RepoRoot $scratchRelative
[void][IO.Directory]::CreateDirectory($scratch)
$junctionPath = Join-Path $scratch 'fixture-link'
try {
    $canonicalA = "$scratchRelative/canonical-a.json"
    $canonicalB = "$scratchRelative/canonical-b.json"
    $runA = Invoke-InventoryGenerator -RootsPath 'kernel-tcb-roots.json' -OutputPath $canonicalA -WorkingDirectory $RepoRoot
    $runB = Invoke-InventoryGenerator -RootsPath 'kernel-tcb-roots.json' -OutputPath $canonicalB -WorkingDirectory (Join-Path $RepoRoot 'tests')
    $bytesA = if (Test-Path -LiteralPath (Join-Path $RepoRoot $canonicalA)) { [IO.File]::ReadAllBytes((Join-Path $RepoRoot $canonicalA)) } else { [byte[]]@() }
    $bytesB = if (Test-Path -LiteralPath (Join-Path $RepoRoot $canonicalB)) { [IO.File]::ReadAllBytes((Join-Path $RepoRoot $canonicalB)) } else { [byte[]]@() }
    Check ($runA.ExitCode -eq 0 -and $runB.ExitCode -eq 0) 'canonical inventory generates from repository and different cwd' "canonical generation failed: A=$($runA.StdErr) B=$($runB.StdErr)"
    Check ((Test-BytesEqual -Left $bytesA -Right $bytesB) -and (Test-BytesEqual -Left $bytesA -Right $trackedBytes)) 'same tree, different cwd, and different OutputPath are byte-identical' 'inventory generation is not byte-identical across cwd or OutputPath'

    $staticA = "$scratchRelative/static-a.json"
    $staticB = "$scratchRelative/static-b.json"
    $staticRunA = Invoke-InventoryGenerator -RootsPath 'tests/fixtures/tk00/tcb/roots-static.json' -OutputPath $staticA -WorkingDirectory $RepoRoot
    $staticRunB = Invoke-InventoryGenerator -RootsPath 'tests/fixtures/tk00/tcb/roots-static.json' -OutputPath $staticB -WorkingDirectory (Join-Path $RepoRoot 'tests')
    $staticBytesA = if (Test-Path -LiteralPath (Join-Path $RepoRoot $staticA)) { [IO.File]::ReadAllBytes((Join-Path $RepoRoot $staticA)) } else { [byte[]]@() }
    $staticBytesB = if (Test-Path -LiteralPath (Join-Path $RepoRoot $staticB)) { [IO.File]::ReadAllBytes((Join-Path $RepoRoot $staticB)) } else { [byte[]]@() }
    Check ($staticRunA.ExitCode -eq 0 -and $staticRunB.ExitCode -eq 0 -and (Test-BytesEqual -Left $staticBytesA -Right $staticBytesB)) 'AST fixture closure is deterministic across cwd' "static fixture generation drifted: A=$($staticRunA.StdErr) B=$($staticRunB.StdErr)"
    if ($staticBytesA.Length -gt 0) {
        $staticDoc = ([Text.UTF8Encoding]::new($false, $true).GetString($staticBytesA) | ConvertFrom-Json -AsHashtable -Depth 100)
        $staticPaths = @($staticDoc.files | ForEach-Object path)
        Check (($staticPaths -join '|') -ceq 'tests/fixtures/tk00/tcb/leaf.psm1|tests/fixtures/tk00/tcb/static-entry.ps1') 'AST Join-Path import produces the exact fixture closure' "static fixture closure was unexpected: $($staticPaths -join ', ')"
    }

    $locOutput = "$scratchRelative/loc.json"
    $locRun = Invoke-InventoryGenerator -RootsPath 'tests/fixtures/tk00/tcb/roots-loc.json' -OutputPath $locOutput
    $locDoc = if (Test-Path -LiteralPath (Join-Path $RepoRoot $locOutput)) { Get-Content -LiteralPath (Join-Path $RepoRoot $locOutput) -Raw | ConvertFrom-Json -AsHashtable -Depth 100 } else { $null }
    $locVector = @()
    if ($null -ne $locDoc) { $locVector = @($locDoc.files | Where-Object { [string]$_.path -ceq 'tests/fixtures/tk00/tcb/loc-vector.ps1' }) }
    Check ($locRun.ExitCode -eq 0 -and $locVector.Count -eq 1 -and [int]$locVector[0].physical_loc -eq 13 -and [int]$locVector[0].nonblank_loc -eq 12 -and [int]$locVector[0].executable_loc -eq 8) 'PowerShell LOC known vector is 13 physical, 12 nonblank, and 8 executable lines' "LOC vector drifted or failed: $($locRun.StdErr)"

    $negativeCases = @(
        [pscustomobject]@{ Name='dynamic'; Token='unresolved dynamic dependencies' },
        [pscustomobject]@{ Name='missing'; Token='does not exist' },
        [pscustomobject]@{ Name='cycle'; Token='unexpected dependency cycle' },
        [pscustomobject]@{ Name='duplicate-key'; Token='duplicate JSON key' },
        [pscustomobject]@{ Name='path-escape'; Token='TCB roots schema validation failed' }
    )
    foreach ($case in $negativeCases) {
        $output = "$scratchRelative/negative-$($case.Name).json"
        $run = Invoke-InventoryGenerator -RootsPath "tests/fixtures/tk00/tcb/roots-$($case.Name).json" -OutputPath $output
        Check ($run.Exited -and $run.ExitCode -ne 0 -and $run.StdErr.Contains($case.Token, [StringComparison]::OrdinalIgnoreCase) -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot $output))) "$($case.Name) fixture fails closed with zero partial output" "$($case.Name) fixture did not fail closed: exit=$($run.ExitCode) stderr=[$($run.StdErr)]"
    }

    $outsideTarget = "../tk00-inventory-escape-$([guid]::NewGuid().ToString('N')).json"
    $outsideFull = [IO.Path]::GetFullPath((Join-Path $RepoRoot $outsideTarget))
    $escapeRun = Invoke-InventoryGenerator -RootsPath 'tests/fixtures/tk00/tcb/roots-static.json' -OutputPath $outsideTarget
    Check ($escapeRun.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $outsideFull)) 'OutputPath escape fails closed without external output' "OutputPath escape was accepted or wrote outside RepoRoot: $($escapeRun.StdErr)"

    $fixtureTarget = (Resolve-Path -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00\tcb')).Path
    $junctionCreated = $false
    try {
        $junction = New-Item -ItemType Junction -Path $junctionPath -Target $fixtureTarget -ErrorAction Stop
        $junctionCreated = $true
        $classificationRelative = "$scratchRelative/reparse-classification.json"
        $rootsRelative = "$scratchRelative/reparse-roots.json"
        $aliasRelative = "$scratchRelative/fixture-link"
        $reparseClassification = [ordered]@{
            schema_version='kernel-component-classification/v1'
            components=@(
                [ordered]@{path="$aliasRelative/leaf.psm1";layer='k0-trust-primitive';current_role='Reparse leaf.';owner_candidate='trust-kernel';tcb_included=$true;reason='Reparse rejection fixture.';migration_target=$null;legacy_status='not-legacy'},
                [ordered]@{path="$aliasRelative/static-entry.ps1";layer='k1-runtime-kernel';current_role='Reparse entry.';owner_candidate='trust-kernel';tcb_included=$true;reason='Reparse rejection fixture.';migration_target=$null;legacy_status='not-legacy'}
            )
        }
        $reparseRoots = [ordered]@{
            schema_version='kernel-tcb-roots/v1';classification_path=$classificationRelative
            runtime_roots=@([ordered]@{id='reparse-entry';path="$aliasRelative/static-entry.ps1";role='Reparse root.';layer='k1-runtime-kernel';reason='Must fail closed.'})
            distribution_roots=@([ordered]@{id='reparse-leaf';path="$aliasRelative/leaf.psm1";role='Reparse leaf.';layer='k0-trust-primitive';reason='Must fail closed.'})
            trust_artifacts=@();manual_edges=@();external_dependencies=@();budget=[ordered]@{baseline_executable_loc=0;exceptions=@()}
        }
        [IO.File]::WriteAllText((Join-Path $RepoRoot $classificationRelative), ($reparseClassification | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $RepoRoot $rootsRelative), ($reparseRoots | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        $reparseOutput = "$scratchRelative/reparse-output.json"
        $reparseRun = Invoke-InventoryGenerator -RootsPath $rootsRelative -OutputPath $reparseOutput
        Check ($reparseRun.ExitCode -ne 0 -and $reparseRun.StdErr -match '(?i)reparse|physical|contained' -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot $reparseOutput))) 'reparse alias fails closed with zero output' "reparse alias was accepted or failed ambiguously: $($reparseRun.StdErr)"
    } catch {
        Check $false 'reparse alias fixture is available' "reparse alias fixture could not run: $($_.Exception.Message)"
    } finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionPath)) {
            $junctionItem = Get-Item -LiteralPath $junctionPath -Force
            $targetResolved = [IO.Path]::GetFullPath([string]$junctionItem.Target)
            if (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
                -not $targetResolved.Equals($fixtureTarget, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Failure 'reparse fixture target changed before cleanup'
            } else {
                Remove-Item -LiteralPath $junctionPath -Force
            }
        }
    }
} finally {
    $scratchFull = [IO.Path]::GetFullPath($scratch)
    $repoPrefix = $RepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($scratchFull.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-DirectoryWithRetry -Path $scratchFull
    } else {
        Add-Failure 'scratch cleanup target escaped RepoRoot'
    }
}

$filePaths = @($inventory.files | ForEach-Object { [string]$_.path })
$artifactPaths = @($inventory.artifacts | ForEach-Object { [string]$_.path })
$edgeKeys = @($inventory.edges | ForEach-Object { "$($_.from)`0$($_.to)`0$($_.kind)`0$($_.resolution)" })
$rootKeys = @($inventory.roots | ForEach-Object { "$($_.trust_path)`0$($_.path)`0$($_.id)" })
$externalIds = @($inventory.external_dependencies | ForEach-Object { [string]$_.id })
Check (Test-OrdinalSorted -Values $filePaths) 'inventory files are unique and Ordinal sorted' 'inventory file order or uniqueness drifted'
Check (Test-OrdinalSorted -Values $artifactPaths) 'inventory artifacts are unique and Ordinal sorted' 'inventory artifact order or uniqueness drifted'
Check (Test-OrdinalSorted -Values $edgeKeys) 'inventory edges are unique and Ordinal sorted' 'inventory edge order or uniqueness drifted'
Check (Test-OrdinalSorted -Values $rootKeys) 'inventory roots are unique and Ordinal sorted' 'inventory root order or uniqueness drifted'
Check (Test-OrdinalSorted -Values $externalIds) 'external dependency ids are unique and Ordinal sorted' 'external dependency order or uniqueness drifted'

$nestedOrderValid = $true
foreach ($file in @($inventory.files)) {
    if (-not (Test-OrdinalSorted -Values @($file.trust_paths)) -or -not (Test-OrdinalSorted -Values @($file.root_ids))) { $nestedOrderValid = $false }
}
foreach ($edge in @($inventory.edges)) { if (-not (Test-OrdinalSorted -Values @($edge.trust_paths))) { $nestedOrderValid = $false } }
Check $nestedOrderValid 'nested trust_paths and root_ids use unique Ordinal order' 'nested path or root id ordering drifted'

$classifiedIncluded = Get-OrdinalStrings -Values @($classification.components | Where-Object tcb_included | ForEach-Object path)
Check (($classifiedIncluded -join '|') -ceq ($filePaths -join '|')) 'classification tcb_included set exactly matches generated files' 'classification and generated TCB file sets differ'
Check (@($inventory.unresolved_dependencies).Count -eq 0) 'tracked inventory has zero unresolved dependency' 'tracked inventory contains unresolved dependencies'
Check (@($filePaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf) }).Count -eq 0) 'every inventory file exists' 'inventory contains a missing file'
Check (@($artifactPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf) }).Count -eq 0) 'every trust artifact exists' 'inventory contains a missing trust artifact'
$absoluteStrings = @(Get-StringLeaves -Value $inventory | Where-Object {
    $_ -match '(?i)(?:^|[\s''"=])[A-Z]:[\\/]' -or
    $_ -match '(?i)(?:^|[\s''"=])\\\\[A-Za-z0-9._-]+[\\/]'
})
Check ($absoluteStrings.Count -eq 0) 'inventory contains no absolute local or UNC path' "inventory leaks an absolute local or UNC path: $($absoluteStrings -join ', ')"

$runtimePaths = @($inventory.files | Where-Object { @($_.trust_paths) -ccontains 'runtime' } | ForEach-Object path)
Check ($runtimePaths -contains 'scripts/lib/Harness.Path.psm1' -and $runtimePaths -contains 'scripts/lib/Harness.AtomicWrite.psm1' -and $runtimePaths -contains 'scripts/lib/Harness.Hashing.psm1' -and $runtimePaths -notcontains 'scripts/lib/Harness.CanonicalJson.psm1') 'Runtime TCB contains its three reached K0 primitives while unreferenced CanonicalJson remains outside' 'K0 Runtime reachability or CanonicalJson isolation drifted'
$tk07Base = '3d9fc13e0cb54f022b33f290b86ec1d6d239f1ba'
$baseInventory = @(& git -C $RepoRoot show "$tk07Base`:kernel-tcb-inventory.json" 2>$null) -join "`n" | ConvertFrom-Json -Depth 30
$baseRuntimePaths = @($baseInventory.files | Where-Object { @($_.trust_paths) -ccontains 'runtime' } | ForEach-Object path)
$baseDensity = Get-PowerShellSourceDensity -Paths $baseRuntimePaths -Revision $tk07Base
$currentDensity = Get-PowerShellSourceDensity -Paths $runtimePaths
$addedDensity = Get-Tk07AddedLineDensity -BaseRevision $tk07Base -Paths $runtimePaths
$layoutIntegrity = Get-Tk07LayoutIntegrity -BaseRevision $tk07Base -BasePaths $baseRuntimePaths -CurrentPaths $runtimePaths
Check ($currentDensity.Tokens * 100 -le $baseDensity.Tokens * 65 -and $currentDensity.Statements * 100 -le $baseDensity.Statements * 65) 'TK-07 removes at least 35 percent of executable tokens and statement ASTs from the exact Base closure' "TK-07 executable source reduction is too weak: base=$($baseDensity | ConvertTo-Json -Compress) current=$($currentDensity | ConvertTo-Json -Compress)"
Check ($currentDensity.Tokens -le 35288 -and $currentDensity.Statements -le 10376) 'TK-07 final source improves tokens and statement ASTs from the 3123-line readable checkpoint' "TK-07 source did not preserve the readable-checkpoint density ratchet: current=$($currentDensity | ConvertTo-Json -Compress) limits={\"Tokens\":35288,\"Statements\":10376}"
Check ($addedDensity.MaximumLineLength -le 300 -and $addedDensity.MaximumStatementSeparators -le 2) 'TK-07 changed Runtime lines stay reviewable and do not pack statement separators' "TK-07 changed Runtime source is packed: $($addedDensity | ConvertTo-Json -Compress)"
Check ($layoutIntegrity.ParamBlockShrinkCount -eq 0 -and $layoutIntegrity.PackedSiblingStatementLineCount -eq 0) 'TK-07 preserves matching Base parameter layouts and keeps sibling statements on separate changed lines' "TK-07 Runtime layout compression detected: $($layoutIntegrity | ConvertTo-Json -Compress -Depth 5)"
$distributionPaths = @($inventory.files | Where-Object { @($_.trust_paths) -ccontains 'distribution' } | ForEach-Object path)
Check ($distributionPaths -ccontains 'scripts/lib/Harness.Distribution.psm1' -and $distributionPaths -ccontains 'scripts/lib/Harness.CanonicalJson.psm1' -and $runtimePaths -cnotcontains 'scripts/lib/Harness.Distribution.psm1' -and $distributionPaths -cnotcontains 'scripts/lib/Harness.ModuleManifest.psm1' -and $distributionPaths -cnotcontains 'scripts/lib/Harness.CapabilitySource.psm1') 'TK-06 adds only the D1 constructor and canonical primitive, without C2 imports or Runtime reachability' 'Distribution adoption crossed the Runtime or C2 boundary'
Check (@($runtimePaths | Where-Object { $_ -match '(?i)RolloutEvidence|Qualification|release-(?:model|host|full)|generate-v2-rollout' }).Count -eq 0) 'Runtime TCB excludes Release and Qualification producers' 'Release or Qualification leaked into Runtime TCB'
$budgetExceptions = @($inventory.budget.exceptions)
Check ([int]$inventory.budget.baseline_executable_loc -eq 2999 -and [int]$inventory.budget.current_executable_loc -eq 2999 -and [int]$inventory.budget.current_executable_loc -lt 3000 -and [int]$inventory.budget.delta -eq 0 -and [int]$inventory.budget.covered_growth -eq 0 -and [string]$inventory.budget.status -ceq 'within-baseline' -and $budgetExceptions.Count -eq 0) 'TK-07 ratchets Runtime to 2999, below the 3000-line target, with no exception' 'Runtime budget, Adapter Action closure, or exception state drifted'
Check (@($inventory.edges | Where-Object kind -ceq 'manual').Count -eq @($roots.manual_edges).Count -and @($roots.manual_edges | Where-Object kind -ceq 'dynamic-import').Count -eq 2) 'manual edges are exact and the two rendered Adapter imports are explicit' 'manual edge count or dynamic-import boundary drifted'
Check ([int]$inventory.totals.file_count -eq @($inventory.files).Count -and [int]$inventory.totals.artifact_count -eq @($inventory.artifacts).Count -and [int]$inventory.totals.runtime_executable_loc -eq 2999) 'inventory totals bind the current TK-07 Runtime measurement' 'inventory totals or Runtime measurement drifted'

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output "TCB inventory checks passed; files=$($inventory.files.Count); artifacts=$($inventory.artifacts.Count); runtime_executable_loc=$($inventory.totals.runtime_executable_loc)"
exit 0
