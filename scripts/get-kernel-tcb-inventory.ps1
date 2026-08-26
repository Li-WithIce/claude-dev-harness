[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$RootsPath = 'kernel-tcb-roots.json',
    [string]$OutputPath = '',
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Path.psm1') -Force -ErrorAction Stop

$script:RepoRootResolved = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $RepoRoot
$script:Utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$script:DependenciesByPath = @{}
$script:ManualByFrom = @{}

function ConvertTo-PosixPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Replace([char]92, [char]47)
}

function Get-OrdinalStrings {
    param([object[]]$Values)
    [string[]]$result = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}

function Resolve-RepoFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    return Resolve-HarnessContainedPath -WorkspaceRoot $script:RepoRootResolved -Path $Path -Label $Label -MustExist File
}

function Get-RepoRelativePath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $relative = ConvertTo-PosixPath -Path ([IO.Path]::GetRelativePath($script:RepoRootResolved, $fullPath))
    if ($relative -eq '..' -or $relative.StartsWith('../', [StringComparison]::Ordinal) -or
        [IO.Path]::IsPathRooted($relative)) {
        throw "dependency escapes RepoRoot: $Path"
    }
    return $relative
}

function Get-InventoryNormalizedTextBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $fullPath = Resolve-RepoFile -Path $Path -Label $Label
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    try {
        [void]$script:Utf8Strict.GetString($bytes)
    } catch {
        throw "$Label is not strict UTF-8: $($_.Exception.Message)"
    }

    $normalized = [System.Collections.Generic.List[byte]]::new($bytes.Length)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0D) {
            if ($index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 0x0A) { $index++ }
            $normalized.Add(0x0A)
        } else {
            $normalized.Add($bytes[$index])
        }
    }
    return ,$normalized.ToArray()
}

function Get-InventoryNormalizedTextDigest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    [byte[]]$bytes = Get-InventoryNormalizedTextBytes -Path $Path -Label $Label
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-NoDuplicateJsonKeys {
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string]$Location
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "duplicate JSON key at ${Location}: $($property.Name)"
            }
            Assert-NoDuplicateJsonKeys -Element $property.Value -Location "$Location.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonKeys -Element $item -Location "$Location[$index]"
            $index++
        }
    }
}

function Read-StrictJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$Label
    )

    $fullPath = Resolve-RepoFile -Path $Path -Label $Label
    $schemaFullPath = Resolve-RepoFile -Path $SchemaPath -Label "$Label schema"
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$Label must be UTF-8 without BOM"
    }
    try {
        $text = $script:Utf8Strict.GetString($bytes)
    } catch {
        throw "$Label is not strict UTF-8: $($_.Exception.Message)"
    }

    $jsonDocument = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.AllowTrailingCommas = $false
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text, $options)
        Assert-NoDuplicateJsonKeys -Element $jsonDocument.RootElement -Location '$'
    } catch {
        throw "$Label is not strict JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }

    try {
        $valid = Test-Json -Json $text -SchemaFile $schemaFullPath -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "$Label schema validation failed: $($_.Exception.Message)"
    }
    if (-not $valid) { throw "$Label schema validation failed" }

    try {
        return ($text | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop)
    } catch {
        throw "$Label conversion failed after strict parsing: $($_.Exception.Message)"
    }
}

function Resolve-StaticPathExpression {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory)][string]$SourceFullPath
    )

    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $value = [string]$Node.Value
        if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
        return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($SourceFullPath)) $value))
    }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        $nested = @($Node.NestedExpressions)
        if ($nested.Count -eq 1 -and
            $nested[0] -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $variableName = [string]$nested[0].VariablePath.UserPath
            $prefix = '$' + $variableName
            if ([string]$Node.Value -notlike "$prefix*") { return $null }
            $base = if ($variableName -ceq 'PSScriptRoot') {
                [IO.Path]::GetDirectoryName($SourceFullPath)
            } elseif ($variableName -ceq 'RepoRoot') {
                $script:RepoRootResolved
            } else {
                return $null
            }
            $child = ([string]$Node.Value).Substring($prefix.Length).TrimStart([char]92, [char]47)
            if ([string]::IsNullOrWhiteSpace($child)) { return $base }
            return [IO.Path]::GetFullPath((Join-Path $base $child))
        }
        if ($nested.Count -ne 0) { return $null }
        $value = [string]$Node.Value
        if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
        return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($SourceFullPath)) $value))
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = [string]$Node.VariablePath.UserPath
        if ($name -ceq 'PSScriptRoot') { return [IO.Path]::GetDirectoryName($SourceFullPath) }
        if ($name -ceq 'RepoRoot') { return $script:RepoRootResolved }
        return $null
    }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        return Resolve-StaticPathExpression -Node $Node.Pipeline -SourceFullPath $SourceFullPath
    }
    if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($Node.PipelineElements)
        if ($elements.Count -ne 1) { return $null }
        return Resolve-StaticPathExpression -Node $elements[0] -SourceFullPath $SourceFullPath
    }
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Resolve-StaticPathExpression -Node $Node.Expression -SourceFullPath $SourceFullPath
    }
    if ($Node -is [System.Management.Automation.Language.CommandAst] -and
        [string]$Node.GetCommandName() -ieq 'Join-Path') {
        $elements = @($Node.CommandElements)
        if ($elements.Count -ne 3 -or
            $elements[1] -is [System.Management.Automation.Language.CommandParameterAst] -or
            $elements[2] -is [System.Management.Automation.Language.CommandParameterAst]) {
            return $null
        }
        $base = Resolve-StaticPathExpression -Node $elements[1] -SourceFullPath $SourceFullPath
        if ([string]::IsNullOrWhiteSpace($base)) { return $null }
        $childNode = $elements[2]
        if ($childNode -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $childNode -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return $null
        }
        if ($childNode -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            @($childNode.NestedExpressions).Count -ne 0) {
            return $null
        }
        return [IO.Path]::GetFullPath((Join-Path $base ([string]$childNode.Value)))
    }
    return $null
}

function Get-SourceDependencies {
    param([Parameter(Mandatory)][string]$SourcePath)

    if ($script:DependenciesByPath.ContainsKey($SourcePath)) {
        return $script:DependenciesByPath[$SourcePath]
    }

    $sourceFullPath = Resolve-RepoFile -Path $SourcePath -Label 'TCB source'
    $extension = [IO.Path]::GetExtension($sourceFullPath)
    $edges = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $duplicateCount = 0
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $manualEdges = if ($script:ManualByFrom.ContainsKey($SourcePath)) {
        @($script:ManualByFrom[$SourcePath])
    } else {
        @()
    }

    if ($extension -cin @('.ps1', '.psm1')) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $sourceFullPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw "PowerShell parse failed for ${SourcePath}: $(@($parseErrors | ForEach-Object Message) -join '; ')"
        }

        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))
        foreach ($command in $commands) {
            $commandName = [string]$command.GetCommandName()
            $kind = $null
            $pathNode = $null
            if ($commandName -ieq 'Import-Module') {
                $kind = 'import-module'
                if (@($command.CommandElements).Count -ge 2) { $pathNode = $command.CommandElements[1] }
            } elseif ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
                $kind = 'dot-source'
                if (@($command.CommandElements).Count -ge 1) { $pathNode = $command.CommandElements[0] }
            } else {
                continue
            }

            $expression = $command.Extent.Text.Trim()
            $targetFullPath = if ($null -eq $pathNode) { $null } else {
                Resolve-StaticPathExpression -Node $pathNode -SourceFullPath $sourceFullPath
            }
            if ([string]::IsNullOrWhiteSpace($targetFullPath)) {
                $matchingManual = @($manualEdges | Where-Object {
                    [string]$_.kind -ceq 'dynamic-import' -and [string]$_.expression -ceq $expression
                })
                if ($matchingManual.Count -ne 1) {
                    $unresolved.Add([ordered]@{
                        from = $SourcePath
                        expression = $expression
                        reason = 'unresolved_dynamic_dependency'
                    })
                }
                continue
            }

            $targetResolved = Resolve-HarnessContainedPath -WorkspaceRoot $script:RepoRootResolved -Path $targetFullPath -Label "dependency from $SourcePath" -MustExist File
            $targetPath = Get-RepoRelativePath -Path $targetResolved
            if ([IO.Path]::GetExtension($targetPath) -cnotin @('.ps1', '.psm1')) {
                throw "unsupported repository dependency type: $SourcePath -> $targetPath"
            }
            $edge = [ordered]@{
                from = $SourcePath
                to = $targetPath
                kind = $kind
                resolution = "ast-static:$expression"
            }
            $edgeKey = "$SourcePath`0$targetPath`0$kind`0$expression"
            if ($edges.ContainsKey($edgeKey)) { $duplicateCount++ } else { $edges.Add($edgeKey, $edge) }
        }
    }

    foreach ($manual in $manualEdges) {
        $targetPath = [string]$manual.to
        [void](Resolve-RepoFile -Path $targetPath -Label "manual edge target from $SourcePath")
        $staticDuplicate = @($edges.Values | Where-Object { [string]$_.to -ceq $targetPath })
        if ($staticDuplicate.Count -ne 0) {
            throw "manual edge duplicates a statically resolved dependency: $SourcePath -> $targetPath"
        }
        $resolution = "manual:$([string]$manual.kind):$([string]$manual.expression)"
        $edge = [ordered]@{
            from = $SourcePath
            to = $targetPath
            kind = 'manual'
            resolution = $resolution
        }
        $edgeKey = "$SourcePath`0$targetPath`0manual`0$resolution"
        if ($edges.ContainsKey($edgeKey)) { $duplicateCount++ } else { $edges.Add($edgeKey, $edge) }
    }

    $result = [pscustomobject]@{
        Edges = @($edges.Values)
        Unresolved = @($unresolved)
        DuplicateCount = $duplicateCount
    }
    $script:DependenciesByPath[$SourcePath] = $result
    return $result
}

function Get-PowerShellMetrics {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Resolve-RepoFile -Path $Path -Label 'TCB metric source'
    $text = [IO.File]::ReadAllText($fullPath, $script:Utf8Strict)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [string[]]$lines = $normalized.Split([char]10)
    if ($normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
        if ($lines.Count -le 1) { $lines = @() } else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    $physicalLoc = $lines.Count
    $nonblankLoc = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $fullPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        throw "PowerShell parse failed for metric source ${Path}: $(@($parseErrors | ForEach-Object Message) -join '; ')"
    }
    $excludedKinds = @(
        [System.Management.Automation.Language.TokenKind]::Comment,
        [System.Management.Automation.Language.TokenKind]::NewLine,
        [System.Management.Automation.Language.TokenKind]::LineContinuation,
        [System.Management.Automation.Language.TokenKind]::EndOfInput
    )
    $executableLines = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($token in @($tokens)) {
        if ($excludedKinds -contains $token.Kind) { continue }
        $start = [Math]::Max(1, [int]$token.Extent.StartLineNumber)
        $end = [Math]::Min($physicalLoc, [Math]::Max($start, [int]$token.Extent.EndLineNumber))
        for ($lineNumber = $start; $lineNumber -le $end; $lineNumber++) {
            [void]$executableLines.Add($lineNumber)
        }
    }
    return [pscustomobject]@{
        PhysicalLoc = $physicalLoc
        NonblankLoc = $nonblankLoc
        ExecutableLoc = $executableLines.Count
    }
}

function Get-TextPhysicalLoc {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Resolve-RepoFile -Path $Path -Label 'TCB artifact'
    $text = [IO.File]::ReadAllText($fullPath, $script:Utf8Strict)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($normalized.Length -eq 0) { return 0 }
    $count = $normalized.Split([char]10).Count
    if ($normalized.EndsWith("`n", [StringComparison]::Ordinal)) { $count-- }
    return $count
}

function Assert-AcyclicGraph {
    param(
        [Parameter(Mandatory)][string[]]$Nodes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edges
    )

    $adjacency = @{}
    foreach ($node in $Nodes) { $adjacency[$node] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
    foreach ($edge in $Edges) { [void]$adjacency[[string]$edge.from].Add([string]$edge.to) }
    $state = @{}
    $stack = [System.Collections.Generic.List[string]]::new()
    function Visit-TcbNode {
        param([Parameter(Mandatory)][string]$Node)
        $currentState = if ($state.ContainsKey($Node)) { [int]$state[$Node] } else { 0 }
        if ($currentState -eq 2) { return }
        if ($currentState -eq 1) {
            throw "unexpected dependency cycle: $((@($stack) + $Node) -join ' -> ')"
        }
        $state[$Node] = 1
        $stack.Add($Node)
        foreach ($target in Get-OrdinalStrings -Values @($adjacency[$Node])) { Visit-TcbNode -Node $target }
        $stack.RemoveAt($stack.Count - 1)
        $state[$Node] = 2
    }
    foreach ($node in Get-OrdinalStrings -Values $Nodes) { Visit-TcbNode -Node $node }
}

function ConvertTo-StableJsonText {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 100
    return $json.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
}

if ($Check -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
    throw '-Check and -OutputPath are mutually exclusive'
}
if (-not $Check -and [string]::IsNullOrWhiteSpace($OutputPath)) {
    throw 'generation requires an explicit -OutputPath; use -Check for zero-write comparison'
}

$rootsFullPath = Resolve-RepoFile -Path $RootsPath -Label 'TCB roots'
$rootsRelativePath = Get-RepoRelativePath -Path $rootsFullPath
$roots = Read-StrictJson -Path $rootsRelativePath -SchemaPath 'schemas/kernel-tcb-roots.schema.json' -Label 'TCB roots'
$classification = Read-StrictJson -Path ([string]$roots.classification_path) -SchemaPath 'schemas/kernel-component-classification.schema.json' -Label 'kernel component classification'

$classificationByPath = @{}
foreach ($component in @($classification.components)) {
    $path = [string]$component.path
    if ($classificationByPath.ContainsKey($path)) { throw "duplicate component classification: $path" }
    [void](Resolve-RepoFile -Path $path -Label 'component classification path')
    $classificationByPath[$path] = $component
}

$rootIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$rootPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$rootOutputByKey = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
$rootContexts = [System.Collections.Generic.List[object]]::new()
foreach ($rootSet in @(
    [pscustomobject]@{ TrustPath = 'runtime'; Items = @($roots.runtime_roots) },
    [pscustomobject]@{ TrustPath = 'distribution'; Items = @($roots.distribution_roots) }
)) {
    foreach ($root in @($rootSet.Items)) {
        $id = [string]$root.id
        $path = [string]$root.path
        if (-not $rootIds.Add($id)) { throw "duplicate TCB root id: $id" }
        if (-not $rootPaths.Add("$($rootSet.TrustPath):$path")) { throw "duplicate TCB root path: $($rootSet.TrustPath):$path" }
        [void](Resolve-RepoFile -Path $path -Label 'TCB root')
        if (-not $classificationByPath.ContainsKey($path)) { throw "TCB root is unclassified: $path" }
        if ([string]$classificationByPath[$path].layer -cne [string]$root.layer) { throw "TCB root layer conflicts with classification: $path" }
        if (-not [bool]$classificationByPath[$path].tcb_included) { throw "TCB root classification is not included: $path" }
        $output = [ordered]@{
            id = $id
            path = $path
            trust_path = [string]$rootSet.TrustPath
            role = [string]$root.role
            layer = [string]$root.layer
            reason = [string]$root.reason
        }
        $rootOutputByKey.Add("$($rootSet.TrustPath)`0$path`0$id", $output)
        $rootContexts.Add([pscustomobject]@{ Path = $path; TrustPath = [string]$rootSet.TrustPath; RootId = $id })
    }
}

foreach ($manual in @($roots.manual_edges)) {
    $from = [string]$manual.from
    $to = [string]$manual.to
    $fromFull = Resolve-RepoFile -Path $from -Label 'manual edge source'
    [void](Resolve-RepoFile -Path $to -Label 'manual edge target')
    $sourceText = [IO.File]::ReadAllText($fromFull, $script:Utf8Strict)
    if (-not $sourceText.Contains([string]$manual.expression, [StringComparison]::Ordinal)) {
        throw "manual edge expression is absent from source: $from -> $to"
    }
    if (-not $script:ManualByFrom.ContainsKey($from)) { $script:ManualByFrom[$from] = [System.Collections.Generic.List[object]]::new() }
    $script:ManualByFrom[$from].Add($manual)
}

$script:Reach = @{}
$script:ContextQueue = [System.Collections.Generic.List[object]]::new()
$script:SeenContexts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
function Add-ReachContext {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustPath,
        [Parameter(Mandatory)][string]$RootId
    )

    if (-not $script:Reach.ContainsKey($Path)) {
        $script:Reach[$Path] = [pscustomobject]@{
            TrustPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            RootIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        }
    }
    [void]$script:Reach[$Path].TrustPaths.Add($TrustPath)
    [void]$script:Reach[$Path].RootIds.Add($RootId)
    $contextKey = "$Path`0$TrustPath`0$RootId"
    if ($script:SeenContexts.Add($contextKey)) {
        $script:ContextQueue.Add([pscustomobject]@{ Path = $Path; TrustPath = $TrustPath; RootId = $RootId })
    }
}

foreach ($context in $rootContexts) {
    Add-ReachContext -Path $context.Path -TrustPath $context.TrustPath -RootId $context.RootId
}

$edgeOutputByKey = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
$unresolved = [System.Collections.Generic.List[object]]::new()
$duplicateEdgeCount = 0
$countedDuplicateSources = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$queueIndex = 0
while ($queueIndex -lt $script:ContextQueue.Count) {
    $context = $script:ContextQueue[$queueIndex]
    $queueIndex++
    $dependencyResult = Get-SourceDependencies -SourcePath ([string]$context.Path)
    if ($countedDuplicateSources.Add([string]$context.Path)) {
        $duplicateEdgeCount += [int]$dependencyResult.DuplicateCount
    }
    foreach ($item in @($dependencyResult.Unresolved)) { $unresolved.Add($item) }
    foreach ($edge in @($dependencyResult.Edges)) {
        $edgeKey = "$([string]$edge.from)`0$([string]$edge.to)`0$([string]$edge.kind)`0$([string]$edge.resolution)"
        if (-not $edgeOutputByKey.ContainsKey($edgeKey)) {
            $edgeOutputByKey.Add($edgeKey, [pscustomobject]@{
                From = [string]$edge.from
                To = [string]$edge.to
                Kind = [string]$edge.kind
                Resolution = [string]$edge.resolution
                TrustPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            })
        }
        [void]$edgeOutputByKey[$edgeKey].TrustPaths.Add([string]$context.TrustPath)
        Add-ReachContext -Path ([string]$edge.to) -TrustPath ([string]$context.TrustPath) -RootId ([string]$context.RootId)
    }
}

if ($unresolved.Count -ne 0) {
    $summary = @($unresolved | ForEach-Object { "$($_.from): $($_.expression)" }) -join '; '
    throw "unresolved dynamic dependencies: $summary"
}

$edgeOutput = @($edgeOutputByKey.Values | ForEach-Object {
    [ordered]@{
        from = $_.From
        to = $_.To
        kind = $_.Kind
        resolution = $_.Resolution
        trust_paths = @(Get-OrdinalStrings -Values @($_.TrustPaths))
    }
})
$reachedPaths = Get-OrdinalStrings -Values @($script:Reach.Keys)
Assert-AcyclicGraph -Nodes $reachedPaths -Edges $edgeOutput

$fileOutput = [System.Collections.Generic.List[object]]::new()
foreach ($path in $reachedPaths) {
    if (-not $classificationByPath.ContainsKey($path)) { throw "TCB dependency is unclassified: $path" }
    $component = $classificationByPath[$path]
    if (-not [bool]$component.tcb_included) { throw "TCB dependency classification is not included: $path" }
    $metrics = Get-PowerShellMetrics -Path $path
    $fileOutput.Add([ordered]@{
        path = $path
        sha256 = Get-InventoryNormalizedTextDigest -Path $path -Label 'TCB digest source'
        layer = [string]$component.layer
        trust_paths = @(Get-OrdinalStrings -Values @($script:Reach[$path].TrustPaths))
        root_ids = @(Get-OrdinalStrings -Values @($script:Reach[$path].RootIds))
        physical_loc = [int]$metrics.PhysicalLoc
        nonblank_loc = [int]$metrics.NonblankLoc
        executable_loc = [int]$metrics.ExecutableLoc
    })
}

$artifactPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$artifactByKey = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
foreach ($artifact in @($roots.trust_artifacts)) {
    $path = [string]$artifact.path
    if (-not $artifactPaths.Add($path)) { throw "duplicate trust artifact path: $path" }
    [void](Resolve-RepoFile -Path $path -Label 'trust artifact')
    [byte[]]$normalizedArtifactBytes = Get-InventoryNormalizedTextBytes -Path $path -Label 'TCB artifact byte source'
    $artifactByKey.Add($path, [ordered]@{
        path = $path
        sha256 = Get-InventoryNormalizedTextDigest -Path $path -Label 'TCB artifact digest source'
        kind = [string]$artifact.kind
        owner_layer = [string]$artifact.owner_layer
        trust_paths = @(Get-OrdinalStrings -Values @($artifact.trust_paths))
        reason = [string]$artifact.reason
        physical_loc = Get-TextPhysicalLoc -Path $path
        bytes = $normalizedArtifactBytes.Length
    })
}

$trustReferencePattern = '(?<![A-Za-z0-9._/\\-])(?<path>(?:agent-configs|policies|runtime-hooks|schemas|scripts[/\\]lib|templates[/\\]v2|vault-template)[/\\][A-Za-z0-9._/\\-]+)'
foreach ($path in $reachedPaths) {
    if (-not $script:Reach[$path].TrustPaths.Contains('runtime')) { continue }
    $sourceText = [IO.File]::ReadAllText((Resolve-RepoFile -Path $path -Label 'runtime trust reference source'), $script:Utf8Strict)
    foreach ($match in [regex]::Matches($sourceText, $trustReferencePattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        $reference = ConvertTo-PosixPath -Path ([string]$match.Groups['path'].Value)
        if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRootResolved $reference) -PathType Leaf)) {
            throw "runtime source has a missing trust reference: $path -> $reference"
        }
        if (-not $script:Reach.ContainsKey($reference) -and -not $artifactPaths.Contains($reference)) {
            throw "untracked_trust_reference: $path -> $reference"
        }
    }
}

$externalByKey = [System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
foreach ($external in @($roots.external_dependencies)) {
    $id = [string]$external.id
    if ($externalByKey.ContainsKey($id)) { throw "duplicate external dependency id: $id" }
    $externalByKey.Add($id, [ordered]@{
        id = $id
        name = [string]$external.name
        reason = [string]$external.reason
        trust_paths = @(Get-OrdinalStrings -Values @($external.trust_paths))
    })
}

$runtimeFiles = @($fileOutput | Where-Object { @($_['trust_paths']) -ccontains 'runtime' })
$distributionFiles = @($fileOutput | Where-Object { @($_['trust_paths']) -ccontains 'distribution' })
$currentRuntimeLoc = [int](($runtimeFiles | ForEach-Object { [int]$_['executable_loc'] } | Measure-Object -Sum).Sum)
$baseline = [int]$roots.budget.baseline_executable_loc
$delta = $currentRuntimeLoc - $baseline
$coveredGrowth = [int]((@($roots.budget.exceptions) | ForEach-Object { [int]$_['added_lines'] } | Measure-Object -Sum).Sum)
$budgetStatus = if ($delta -le 0) {
    'within-baseline'
} elseif ($coveredGrowth -ge $delta) {
    'covered-by-exception'
} else {
    'uncovered-growth'
}

$inventory = [ordered]@{
    schema_version = 'kernel-tcb/v1'
    generator_contract_version = 'kernel-tcb-generator/v1'
    roots = @($rootOutputByKey.Values)
    files = @($fileOutput)
    artifacts = @($artifactByKey.Values)
    edges = $edgeOutput
    external_dependencies = @($externalByKey.Values)
    unresolved_dependencies = @()
    totals = [ordered]@{
        file_count = $fileOutput.Count
        physical_loc = [int](($fileOutput | ForEach-Object { [int]$_['physical_loc'] } | Measure-Object -Sum).Sum)
        nonblank_loc = [int](($fileOutput | ForEach-Object { [int]$_['nonblank_loc'] } | Measure-Object -Sum).Sum)
        executable_loc = [int](($fileOutput | ForEach-Object { [int]$_['executable_loc'] } | Measure-Object -Sum).Sum)
        runtime_file_count = $runtimeFiles.Count
        runtime_executable_loc = $currentRuntimeLoc
        distribution_file_count = $distributionFiles.Count
        distribution_executable_loc = [int](($distributionFiles | ForEach-Object { [int]$_['executable_loc'] } | Measure-Object -Sum).Sum)
        duplicate_edge_count = $duplicateEdgeCount
        artifact_count = $artifactByKey.Count
        artifact_bytes = [int](($artifactByKey.Values | ForEach-Object { [int]$_['bytes'] } | Measure-Object -Sum).Sum)
    }
    budget = [ordered]@{
        baseline_executable_loc = $baseline
        current_executable_loc = $currentRuntimeLoc
        delta = $delta
        covered_growth = $coveredGrowth
        status = $budgetStatus
        exceptions = @($roots.budget.exceptions)
    }
}

$inventoryText = ConvertTo-StableJsonText -Value $inventory
try {
    $inventoryValid = Test-Json -Json $inventoryText -SchemaFile (Resolve-RepoFile -Path 'schemas/kernel-tcb.schema.json' -Label 'TCB inventory schema') -ErrorAction Stop -WarningAction SilentlyContinue
} catch {
    throw "generated TCB inventory schema validation failed: $($_.Exception.Message)"
}
if (-not $inventoryValid) { throw 'generated TCB inventory schema validation failed' }

if ($Check) {
    if ($budgetStatus -ceq 'uncovered-growth') {
        throw "Runtime TCB budget has uncovered growth: baseline=$baseline current=$currentRuntimeLoc delta=$delta covered=$coveredGrowth"
    }
    $trackedPath = Resolve-RepoFile -Path 'kernel-tcb-inventory.json' -Label 'tracked TCB inventory'
    [byte[]]$trackedBytes = Get-InventoryNormalizedTextBytes -Path 'kernel-tcb-inventory.json' -Label 'tracked TCB inventory'
    $generatedBytes = [Text.UTF8Encoding]::new($false).GetBytes($inventoryText)
    $equal = $trackedBytes.Length -eq $generatedBytes.Length
    $firstDifference = -1
    if ($equal) {
        for ($index = 0; $index -lt $trackedBytes.Length; $index++) {
            if ($trackedBytes[$index] -ne $generatedBytes[$index]) { $firstDifference = $index; $equal = $false; break }
        }
    } else {
        $limit = [Math]::Min($trackedBytes.Length, $generatedBytes.Length)
        for ($index = 0; $index -lt $limit; $index++) {
            if ($trackedBytes[$index] -ne $generatedBytes[$index]) { $firstDifference = $index; break }
        }
        if ($firstDifference -lt 0) { $firstDifference = $limit }
    }
    if (-not $equal) {
        throw "kernel TCB inventory drift: tracked_bytes=$($trackedBytes.Length) generated_bytes=$($generatedBytes.Length) first_difference=$firstDifference"
    }
    Write-Output "STATUS: PASS"
    Write-Output "TCB inventory matches tracked bytes; runtime_executable_loc=$currentRuntimeLoc; unresolved=0"
    exit 0
}

$outputResolved = Resolve-HarnessContainedPath -WorkspaceRoot $script:RepoRootResolved -Path $OutputPath -Label 'TCB inventory output' -AllowMissing
[void](Write-HarnessAtomicText -WorkspaceRoot $script:RepoRootResolved -Path $outputResolved -Content $inventoryText)
Write-Output "STATUS: GENERATED"
Write-Output "Output: $(Get-RepoRelativePath -Path $outputResolved)"
Write-Output "Runtime executable LOC: $currentRuntimeLoc"
Write-Output "Budget status: $budgetStatus"
