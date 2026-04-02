[CmdletBinding()]
param(
    [string]$TaskRoot = "",
    [string]$CurrentFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Checks = @()
$script:Warnings = @()
$script:Errors = @()

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
}

function Add-Error {
    param([string]$Message)
    $script:Errors += $Message
}

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Normalize-ScalarValue {
    param([string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $trimmed = $Value.Trim()
    if (
        ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))
    ) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function Parse-SimpleYaml {
    param([string]$Content)

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $result
    }

    $stack = New-Object System.Collections.Generic.List[object]
    $lines = $Content -split "`r?`n"

    foreach ($rawLine in $lines) {
        $line = $rawLine -replace "`t", "    "
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match '^\s*-\s+') {
            continue
        }

        $match = [regex]::Match(
            $line,
            '^(?<indent>\s*)(?<key>[^:#][^:]*?)\s*:\s*(?<value>.*)$'
        )
        if (-not $match.Success) {
            continue
        }

        $indent = $match.Groups["indent"].Value.Length
        $key = $match.Groups["key"].Value.Trim()
        $value = $match.Groups["value"].Value

        while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
            $stack.RemoveAt($stack.Count - 1)
        }

        $prefix = if ($stack.Count -gt 0) {
            (($stack | ForEach-Object { $_.Key }) -join ".") + "."
        } else {
            ""
        }

        $fullKey = "{0}{1}" -f $prefix, $key
        if ([string]::IsNullOrWhiteSpace($value)) {
            $stack.Add([pscustomobject]@{
                    Indent = $indent
                    Key    = $key
                })
            continue
        }

        $result[$fullKey] = Normalize-ScalarValue -Value $value
    }

    return $result
}

function Get-YamlValue {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Map,
        [string]$Key
    )

    if ($null -eq $Map) {
        return $null
    }

    if ($Map.Contains($Key)) {
        return [string]$Map[$Key]
    }

    return $null
}

function Test-MeaningfulValue {
    param(
        [string]$Value,
        [bool]$AllowNone = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if (-not $AllowNone -and $Value -match '^(?i:none|null)$') {
        return $false
    }

    return $true
}

function Get-WorkspaceRootFromCurrentFlowPath {
    param([string]$Path)

    $orchestrationRoot = Split-Path -Parent $Path
    $assistantRoot = Split-Path -Parent $orchestrationRoot
    return Split-Path -Parent $assistantRoot
}

function Resolve-FlowPathValue {
    param(
        [string]$WorkspaceRoot,
        [string]$Value
    )

    if (-not (Test-MeaningfulValue -Value $Value -AllowNone $false)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return Get-NormalizedPath -Path $Value
    }

    return Get-NormalizedPath -Path (Join-Path $WorkspaceRoot $Value)
}

function Test-MetaKey {
    param(
        [string]$Content,
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    return [regex]::IsMatch($Content, "(?im)^\s*(?:>\s*)?$escapedKey\s*:\s*(.+?)\s*$")
}

function Get-MetaValue {
    param(
        [string]$Content,
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    $match = [regex]::Match($Content, "(?im)^\s*(?:>\s*)?$escapedKey\s*:\s*(.+?)\s*$")
    if (-not $match.Success) {
        return $null
    }

    return Normalize-ScalarValue -Value $match.Groups[1].Value
}

function Test-KeywordGroup {
    param(
        [string]$Content,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ([regex]::IsMatch($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-MarkdownSection {
    param(
        [string]$Content,
        [string]$SectionName
    )

    $escapedName = [regex]::Escape($SectionName)
    return [regex]::IsMatch($Content, "(?im)^\s*##\s+$escapedName\s*$")
}

function Test-TestConclusion {
    param([string]$Content)

    $sectionMatch = [regex]::Match(
        $Content,
        '(?ims)^\s*##\s+Conclusion\s*$\s*(?<body>.+?)(?=^\s*##\s+|\z)'
    )
    if (-not $sectionMatch.Success) {
        Add-Error "test.md is missing a usable ## Conclusion section"
        return
    }

    $verdictMatches = [regex]::Matches(
        $sectionMatch.Groups["body"].Value,
        '(?im)\b(pass|fail|blocked)\b'
    )

    $uniqueVerdicts = @($verdictMatches | ForEach-Object {
            $_.Groups[1].Value.ToLowerInvariant()
        } | Select-Object -Unique)

    if ($uniqueVerdicts.Count -ne 1) {
        Add-Error "test.md must contain exactly one conclusion verdict: pass | fail | blocked"
    }
}

function Assert-MarkdownArtifact {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$RequiredMetaKeys = @(),
        [object[]]$KeywordGroups = @(),
        [string]$ExpectedTaskId = "",
        [bool]$Required = $true,
        [scriptblock]$CustomValidator = $null
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) {
            Add-Error ("Missing required artifact {0}: {1}" -f $Label, $Path)
        }
        return
    }

    $content = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($content)) {
        Add-Error ("Cannot read artifact or artifact is empty: {0}" -f $Path)
        return
    }

    $errorsBefore = $script:Errors.Count
    $warningsBefore = $script:Warnings.Count

    foreach ($metaKey in $RequiredMetaKeys) {
        if (-not (Test-MetaKey -Content $content -Key $metaKey)) {
            Add-Error ('{0} is missing required meta key ''{1}'': {2}' -f $Label, $metaKey, $Path)
        }
    }

    if (Test-MeaningfulValue -Value $ExpectedTaskId -AllowNone $false) {
        $artifactTaskId = Get-MetaValue -Content $content -Key "task_id"
        if ($artifactTaskId -ne $ExpectedTaskId) {
            Add-Error ('{0} task_id does not match current-flow: expected ''{1}'', got ''{2}'' ({3})' -f $Label, $ExpectedTaskId, $artifactTaskId, $Path)
        }
    }

    $groupIndex = 1
    foreach ($keywordGroup in $KeywordGroups) {
        if (-not (Test-KeywordGroup -Content $content -Patterns $keywordGroup)) {
            Add-Error ("{0} is missing required content group #{1}: {2}" -f $Label, $groupIndex, $Path)
        }
        $groupIndex += 1
    }

    if ($null -ne $CustomValidator) {
        & $CustomValidator $content $Path $Label
    }

    if ($script:Errors.Count -eq $errorsBefore -and $script:Warnings.Count -eq $warningsBefore) {
        Add-Check ("{0} passed structural validation: {1}" -f $Label, $Path)
    }
}

function Assert-CurrentFlow {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Error ("Missing current-flow.md: {0}" -f $Path)
        return $null
    }

    $content = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($content)) {
        Add-Error ("Cannot read current-flow.md: {0}" -f $Path)
        return $null
    }

    $map = Parse-SimpleYaml -Content $content

    $requiredNonNoneKeys = @(
        "task_id",
        "task_name",
        "mode",
        "stage",
        "review_scope",
        "entry_tool",
        "tool_profile_id",
        "tool_profile_source",
        "runner_tool",
        "runner",
        "fallback_policy",
        "artifact_root",
        "current_doc",
        "plan_path",
        "gate.status",
        "gate.basis"
    )

    $requiredAllowNoneKeys = @(
        "next",
        "implementation_notes_path",
        "review_path",
        "test_path",
        "handoff_path"
    )

    foreach ($key in $requiredNonNoneKeys) {
        $value = Get-YamlValue -Map $map -Key $key
        if (-not (Test-MeaningfulValue -Value $value -AllowNone $false)) {
            Add-Error ('current-flow.md is missing required field ''{0}'': {1}' -f $key, $Path)
        }
    }

    foreach ($key in $requiredAllowNoneKeys) {
        $value = Get-YamlValue -Map $map -Key $key
        if (-not (Test-MeaningfulValue -Value $value -AllowNone $true)) {
            Add-Error ('current-flow.md is missing required field ''{0}'': {1}' -f $key, $Path)
        }
    }

    $validStages = @("INTAKE", "PLAN", "DEV", "REVIEW(implementation)", "TEST", "HANDOFF")
    $validModes = @("full", "fast-track")
    $validReviewScopes = @("implementation", "none")

    $stage = Get-YamlValue -Map $map -Key "stage"
    if ((Test-MeaningfulValue -Value $stage -AllowNone $false) -and $validStages -notcontains $stage) {
        Add-Error ("current-flow.md contains an invalid stage: {0}" -f $stage)
    }

    $mode = Get-YamlValue -Map $map -Key "mode"
    if ((Test-MeaningfulValue -Value $mode -AllowNone $false) -and $validModes -notcontains $mode) {
        Add-Warning ("current-flow.md contains a non-standard mode: {0}" -f $mode)
    }

    $reviewScope = Get-YamlValue -Map $map -Key "review_scope"
    if ((Test-MeaningfulValue -Value $reviewScope -AllowNone $false) -and $validReviewScopes -notcontains $reviewScope) {
        Add-Warning ("current-flow.md contains a non-standard review_scope: {0}" -f $reviewScope)
    }

    Add-Check ("current-flow.md passed baseline field validation: {0}" -f $Path)

    return [pscustomobject]@{
        Content = $content
        Map     = $map
    }
}

if ([string]::IsNullOrWhiteSpace($TaskRoot) -and [string]::IsNullOrWhiteSpace($CurrentFlowPath)) {
    throw "You must provide -TaskRoot or -CurrentFlowPath"
}

$TaskRoot = Get-NormalizedPath -Path $TaskRoot
$CurrentFlowPath = Get-NormalizedPath -Path $CurrentFlowPath

$flow = $null
$flowMap = $null
$flowContent = $null
$workspaceRoot = $null

if (-not [string]::IsNullOrWhiteSpace($CurrentFlowPath)) {
    $flow = Assert-CurrentFlow -Path $CurrentFlowPath
    if ($null -ne $flow) {
        $flowMap = $flow.Map
        $flowContent = $flow.Content
        $workspaceRoot = Get-WorkspaceRootFromCurrentFlowPath -Path $CurrentFlowPath
    }
}

if ($null -eq $flowMap -and [string]::IsNullOrWhiteSpace($TaskRoot)) {
    Add-Error "TaskRoot could not be resolved because current-flow validation failed"
}

$resolvedTaskRoot = $null
if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    $resolvedTaskRoot = Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "artifact_root")
}

if (-not [string]::IsNullOrWhiteSpace($TaskRoot) -and -not [string]::IsNullOrWhiteSpace($resolvedTaskRoot) -and $TaskRoot -ne $resolvedTaskRoot) {
    Add-Error ("Provided TaskRoot does not match current-flow artifact_root: {0} != {1}" -f $TaskRoot, $resolvedTaskRoot)
}

if ([string]::IsNullOrWhiteSpace($TaskRoot)) {
    $TaskRoot = $resolvedTaskRoot
}

if ([string]::IsNullOrWhiteSpace($TaskRoot)) {
    Add-Error "TaskRoot could not be resolved"
}

if (-not [string]::IsNullOrWhiteSpace($TaskRoot) -and -not (Test-Path -LiteralPath $TaskRoot -PathType Container)) {
    Add-Error ("TaskRoot does not exist: {0}" -f $TaskRoot)
}

if ($null -eq $flowMap) {
    Add-Warning "No current-flow.md was provided; only existing artifacts under TaskRoot will be validated"
}

$taskId = if ($null -ne $flowMap) {
    Get-YamlValue -Map $flowMap -Key "task_id"
} elseif (-not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    Split-Path -Leaf $TaskRoot
} else {
    $null
}

$stage = if ($null -ne $flowMap) {
    Get-YamlValue -Map $flowMap -Key "stage"
} else {
    $null
}

if (-not (Test-MeaningfulValue -Value $taskId -AllowNone $false)) {
    Add-Error "task_id could not be resolved"
}

$artifactRootFromFlow = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "artifact_root")
} else {
    $null
}

if (-not [string]::IsNullOrWhiteSpace($artifactRootFromFlow) -and -not (Test-Path -LiteralPath $artifactRootFromFlow -PathType Container)) {
    Add-Error ("artifact_root does not exist: {0}" -f $artifactRootFromFlow)
}

$currentDocPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "current_doc")
} else {
    $null
}

if (-not [string]::IsNullOrWhiteSpace($currentDocPath) -and -not (Test-Path -LiteralPath $currentDocPath -PathType Leaf)) {
    Add-Error ("current_doc does not exist: {0}" -f $currentDocPath)
}

$planPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "plan_path")
} else {
    $null
}
$implementationNotesPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "implementation_notes_path")
} else {
    $null
}
$reviewPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "review_path")
} else {
    $null
}
$testPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "test_path")
} else {
    $null
}
$handoffPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "handoff_path")
} else {
    $null
}
$specPath = if ($null -ne $flowMap -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
    Resolve-FlowPathValue -WorkspaceRoot $workspaceRoot -Value (Get-YamlValue -Map $flowMap -Key "delta_spec.path")
} else {
    $null
}

if ([string]::IsNullOrWhiteSpace($planPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $planPath = Join-Path $TaskRoot "plan.md"
}
if ([string]::IsNullOrWhiteSpace($implementationNotesPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $implementationNotesPath = Join-Path $TaskRoot "implementation-notes.md"
}
if ([string]::IsNullOrWhiteSpace($reviewPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $reviewPath = Join-Path $TaskRoot "review.md"
}
if ([string]::IsNullOrWhiteSpace($testPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $testPath = Join-Path $TaskRoot "test.md"
}
if ([string]::IsNullOrWhiteSpace($handoffPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $handoffPath = Join-Path $TaskRoot "handoff.md"
}
if ([string]::IsNullOrWhiteSpace($specPath) -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    $specPath = Join-Path $TaskRoot "spec.md"
}

$planKeywordGroups = @(
    @("approved inputs", "已批准输入", "需求评审", "ui review", "关联 Spec", "delta-spec"),
    @("任务拆解", "task breakdown", "TODO", "实施计划", "任务分解"),
    @("依赖", "dependencies"),
    @("验证", "verification", "测试标准", "验收标准"),
    @("handoff", "交付", "下游", "watchouts")
)

$implementationKeywordGroups = @(
    @("What Changed", "改了什么"),
    @("What Did Not Change", "没改什么"),
    @("Risks", "风险"),
    @("Reviewer Watchouts", "reviewer watchouts", "watchouts")
)

$reviewKeywordGroups = @(
    @("review_verdict"),
    @("findings", "发现", "问题"),
    @("\bP0\b", "\bP1\b", "\bP2\b", "no findings", "无问题", "无发现"),
    @("summary", "总结", "摘要")
)

$testKeywordGroups = @(
    @("# Test Report", "测试报告"),
    @("## Summary", "摘要"),
    @("## Findings", "发现"),
    @("## Conclusion", "结论"),
    @("\bpass\b", "\bfail\b", "\bblocked\b")
)

$handoffKeywordGroups = @(
    @("Consumed Inputs", "已消费输入", "consumed inputs"),
    @("Gate Basis", "门控依据", "gate basis"),
    @("Current Status", "当前状态"),
    @("Artifacts", "产物"),
    @("test_conclusion", "Test conclusion", "测试结论", "not-run", "\bpass\b", "\bfail\b", "\bblocked\b"),
    @("Risks", "风险", "Watchouts"),
    @("Downstream Notes", "下游", "交接")
)

$specKeywordGroups = @(
    @("insufficient", "不足", "缺少"),
    @("delta", "边界", "scope", "范围"),
    @("constraints", "约束", "assumptions", "假设"),
    @("verification", "验证", "验收")
)

$stageRequiresPlan = $stage -in @("PLAN", "DEV", "REVIEW(implementation)", "TEST", "HANDOFF")
$stageRequiresImplementationNotes = $stage -in @("REVIEW(implementation)", "TEST", "HANDOFF")
$stageRequiresReview = $stage -in @("REVIEW(implementation)", "TEST", "HANDOFF")
$stageRequiresTest = $stage -eq "HANDOFF"
$stageRequiresHandoff = $stage -eq "HANDOFF"

Assert-MarkdownArtifact `
    -Label "plan.md" `
    -Path $planPath `
    -RequiredMetaKeys @("task_id", "状态", "review_status") `
    -KeywordGroups $planKeywordGroups `
    -ExpectedTaskId $taskId `
    -Required ([bool]$stageRequiresPlan -or $null -eq $flowMap)

Assert-MarkdownArtifact `
    -Label "implementation-notes.md" `
    -Path $implementationNotesPath `
    -RequiredMetaKeys @("task_id", "task_name") `
    -KeywordGroups $implementationKeywordGroups `
    -ExpectedTaskId $taskId `
    -Required ([bool]$stageRequiresImplementationNotes)

Assert-MarkdownArtifact `
    -Label "review.md" `
    -Path $reviewPath `
    -RequiredMetaKeys @("task_id", "task_name", "review_scope", "review_verdict") `
    -KeywordGroups $reviewKeywordGroups `
    -ExpectedTaskId $taskId `
    -Required ([bool]$stageRequiresReview) `
    -CustomValidator {
        param($content, $path, $label)

        $reviewScopeValue = Get-MetaValue -Content $content -Key "review_scope"
        if ($reviewScopeValue -ne "implementation") {
            Add-Error ('{0} review_scope must be ''implementation'': {1}' -f $label, $path)
        }

        $reviewVerdictValue = Get-MetaValue -Content $content -Key "review_verdict"
        if ($reviewVerdictValue -notin @("pass", "revise")) {
            Add-Error ('{0} review_verdict must be ''pass'' or ''revise'': {1}' -f $label, $path)
        }
    }

Assert-MarkdownArtifact `
    -Label "test.md" `
    -Path $testPath `
    -RequiredMetaKeys @("task_id", "task_name") `
    -KeywordGroups $testKeywordGroups `
    -ExpectedTaskId $taskId `
    -Required ([bool]$stageRequiresTest) `
    -CustomValidator {
        param($content)

        foreach ($sectionName in @("Scope", "Inputs Reviewed", "Test Approach", "Risks / Gaps")) {
            if (-not (Test-MarkdownSection -Content $content -SectionName $sectionName)) {
                Add-Error ('test.md is missing required section ''## {0}''' -f $sectionName)
            }
        }

        Test-TestConclusion -Content $content
    }

Assert-MarkdownArtifact `
    -Label "handoff.md" `
    -Path $handoffPath `
    -RequiredMetaKeys @("task_id", "task_name", "stage", "next_stage", "handoff_reason") `
    -KeywordGroups $handoffKeywordGroups `
    -ExpectedTaskId $taskId `
    -Required ([bool]$stageRequiresHandoff)

$deltaSpecRequired = if ($null -ne $flowMap) {
    Get-YamlValue -Map $flowMap -Key "delta_spec.required"
} else {
    $null
}

if ($deltaSpecRequired -match '^(?i:true)$' -and -not (Test-Path -LiteralPath $specPath -PathType Leaf)) {
    Add-Error "delta_spec.required=true but spec.md is missing"
}

if (Test-Path -LiteralPath $specPath -PathType Leaf) {
    Assert-MarkdownArtifact `
        -Label "spec.md" `
        -Path $specPath `
        -RequiredMetaKeys @("task_id", "task_name", "状态", "review_status") `
        -KeywordGroups $specKeywordGroups `
        -ExpectedTaskId $taskId `
        -Required $false
}

if ($null -ne $flowMap -and $stage -eq "HANDOFF" -and -not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    Add-Error "stage=HANDOFF but test.md is missing"
}

$status = if ($script:Errors.Count -gt 0) {
    "FAIL"
} elseif ($script:Warnings.Count -gt 0) {
    "WARN"
} else {
    "PASS"
}

$exitCode = switch ($status) {
    "PASS" { 0 }
    "WARN" { 1 }
    default { 2 }
}

Write-Output ("STATUS: {0}" -f $status)
if (-not [string]::IsNullOrWhiteSpace($TaskRoot)) {
    Write-Output ("TaskRoot: {0}" -f $TaskRoot)
}
if (-not [string]::IsNullOrWhiteSpace($CurrentFlowPath)) {
    Write-Output ("CurrentFlowPath: {0}" -f $CurrentFlowPath)
}

Write-Output ""
Write-Output "Checks:"
if ($script:Checks.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ""
Write-Output "Warnings:"
if ($script:Warnings.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($item in $script:Warnings) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ""
Write-Output "Errors:"
if ($script:Errors.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($item in $script:Errors) {
        Write-Output ("- {0}" -f $item)
    }
}

exit $exitCode
