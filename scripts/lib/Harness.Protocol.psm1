Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function Get-HarnessV1Frontmatter {
    param([Parameter(Mandatory)][string]$Content)

    $match = [regex]::Match($Content,'\A---\r?\n(?<body>.*?)\r?\n---\r?\n',[System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'v1 plan is missing frontmatter' }
    $fields = [ordered]@{}
    foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cnotmatch '^([a-z_]+):\s*(.+)$') { throw "v1 plan has an invalid frontmatter line: $line" }
        $key = [string]$Matches[1]
        if ($fields.Contains($key)) { throw "v1 plan has a duplicate frontmatter field: $key" }
        $fields[$key] = $Matches[2].Trim()
    }
    return $fields
}

function Assert-HarnessV1Frontmatter {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][string]$TaskId
    )

    $required = @('task_id','stage','tool','updated')
    $optional = @('tool_profile','model')
    $actual = @($Fields.Keys | ForEach-Object { [string]$_ })
    $unknown = @($actual | Where-Object { $_ -cnotin @($required + $optional) })
    $requiredInOrder = @($actual | Where-Object { $_ -cin $required })
    if ($unknown.Count -gt 0 -or ($requiredInOrder -join '|') -cne ($required -join '|')) {
        throw 'v1 plan frontmatter field set or order is invalid'
    }
    $toolIndex = [array]::IndexOf($actual,'tool')
    $updatedIndex = [array]::IndexOf($actual,'updated')
    foreach ($name in $optional) {
        $index = [array]::IndexOf($actual,$name)
        if ($index -ge 0 -and ($index -le $toolIndex -or $index -ge $updatedIndex)) {
            throw "v1 plan optional frontmatter field is out of order: $name"
        }
    }
    if ([string]$Fields['task_id'] -cne $TaskId) { throw 'v1 plan task_id does not match TaskId' }
    $stage = [string]$Fields['stage']
    if ($stage -cnotin @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')) { throw 'v1 plan stage is invalid' }
    if ($stage -ceq 'DONE') {
        if ([string]$Fields['tool'] -cne 'none') { throw 'v1 DONE plan requires tool: none' }
    } elseif ([string]$Fields['tool'] -cnotin @('claudecode','codex')) {
        throw 'v1 plan tool is invalid'
    }
    if ([string]$Fields['updated'] -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw 'v1 plan updated date is invalid' }
}

function Assert-HarnessV2TaskArtifact {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TaskId
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'task.json is not a file' }
        $json = [System.IO.File]::ReadAllText($Path,[System.Text.UTF8Encoding]::new($false,$true))
        $document = $json | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $schemaPath = Join-Path $RepoRoot 'schemas\task-state.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'task-state schema is unavailable' }
        if (-not (Test-Json -Json ($document | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'task.json failed task-state/v2 schema validation' }
        if ([string]$document.task_id -cne $TaskId) { throw 'task.json task_id does not match TaskId' }
    } catch {
        $detail = [string]$_.Exception.Message
        if ($detail.StartsWith('invalid-v2-artifact:',[StringComparison]::Ordinal)) { throw }
        throw "invalid-v2-artifact: $detail"
    }
}

function Assert-HarnessRolloutKeys {
    param([System.Collections.IDictionary]$Value,[string[]]$Expected,[string]$Label)
    if ($Value -isnot [System.Collections.IDictionary]) { throw "rollout-report-invalid-$Label" }
    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    if (@(Compare-Object @($Expected | Sort-Object) @($actual | Sort-Object)).Count -ne 0) { throw "rollout-report-invalid-$Label" }
}

function Get-HarnessRolloutSourcePaths {
    param([string]$RepoRoot)
    $roots = @('agent-configs','policies','runtime-hooks','schemas','scripts','skills','templates','tests','vault-template')
    $entryFiles = @('harness.ps1','install.ps1','uninstall.ps1')
    foreach ($relativeRoot in $roots) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativeRoot) -PathType Container)) { throw 'rollout-source-directory-missing' }
    }
    $tracked = @(& git -C $RepoRoot -c core.quotepath=false ls-files -- @roots @entryFiles 2>$null | ForEach-Object { ([string]$_).Replace('\','/') })
    if ($LASTEXITCODE -ne 0) { throw 'rollout-source-tracked-files-unavailable' }
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($relative in $tracked) {
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $inRoot = @($roots | Where-Object { $relative.StartsWith($_ + '/',[StringComparison]::Ordinal) }).Count -gt 0
        if (-not $inRoot -and $relative -cnotin $entryFiles) { throw 'rollout-source-tracked-path-invalid' }
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relative) -PathType Leaf)) { throw 'rollout-source-file-missing' }
        [void]$paths.Add($relative)
    }
    foreach ($relative in $entryFiles) {
        if (-not $paths.Contains($relative)) { throw 'rollout-source-entry-untracked' }
    }
    return @($paths | Sort-Object)
}

function Get-HarnessRolloutSourceDigest {
    param([string]$RepoRoot)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in Get-HarnessRolloutSourcePaths -RepoRoot $RepoRoot) {
        $records.Add([ordered]@{path=$relative;digest=(Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $relative)})
    }
    return Get-HarnessSha256Text -Content ($records | ConvertTo-Json -Depth 10 -Compress)
}

function Get-HarnessRolloutRevision {
    param([string]$RepoRoot)
    $value = @(& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($value -join '').Trim() -cnotmatch '^[0-9a-f]{40}$') { throw 'rollout-source-revision-unavailable' }
    return ($value -join '').Trim()
}

function Assert-HarnessRolloutRepositoryClean {
    param([string]$RepoRoot)
    $status = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'rollout-source-status-unavailable' }
    $indexFlags = @(& git -C $RepoRoot -c core.quotepath=false ls-files -v -- 2>$null | Where-Object { [string]$_ -cnotmatch '^H ' })
    if ($LASTEXITCODE -ne 0) { throw 'rollout-source-index-unavailable' }
    if (@($status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or $indexFlags.Count -ne 0) { throw 'rollout-source-dirty' }
}

function Assert-HarnessRolloutDistributionClean {
    param([string]$RepoRoot)
    $paths = @('agent-configs','policies','runtime-hooks','schemas','scripts','skills','templates','tests','vault-template','harness.ps1','install.ps1','uninstall.ps1')
    $status = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all -- @paths 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'rollout-source-status-unavailable' }
    if (@($status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) { throw 'rollout-source-dirty' }
}

function Assert-HarnessRolloutSourceHeadBound {
    param([string]$RepoRoot)
    $paths = @(Get-HarnessRolloutSourcePaths -RepoRoot $RepoRoot)
    $null = @(& git -C $RepoRoot diff --quiet HEAD -- @paths 2>$null)
    if ($LASTEXITCODE -eq 1) { throw 'rollout-source-not-head-bound' }
    if ($LASTEXITCODE -ne 0) { throw 'rollout-source-head-binding-unavailable' }
    $flags = @(& git -C $RepoRoot -c core.quotepath=false ls-files -v -- @paths 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $flags.Count -ne $paths.Count -or @($flags | Where-Object { $_ -cnotmatch '^H ' }).Count -ne 0) { throw 'rollout-source-index-flag-invalid' }
}

function Get-HarnessRolloutReportDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        source_revision = $Document.source_revision
        source_digest = $Document.source_digest
        generator_digest = $Document.generator_digest
        generated_at_utc = $Document.generated_at_utc
        gates = $Document.gates
        eligible = $Document.eligible
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 30 -Compress)
}

function Assert-HarnessRolloutReport {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    $gateNames = @('behavior','v1_compatibility','direct_performance','core_install_rollback','full_install_rollback')
    $gateCommands = [ordered]@{
        behavior = 'scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'
        v1_compatibility = 'scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'
        direct_performance = 'scripts/run-host-benchmark.ps1 -Groups 3 -Trials 3 -Model gpt-5.6-sol -Reasoning max'
        core_install_rollback = 'scripts/run-isolated-install-smoke.ps1 -Preset core'
        full_install_rollback = 'scripts/run-isolated-install-smoke.ps1 -Preset full'
    }
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','source_revision','source_digest','generator_digest','generated_at_utc','gates','eligible','report_digest') -Label 'document'
    if ([string]$Document.schema_version -cne 'rollout-eligibility/v1') { throw 'rollout-report-invalid-schema' }
    if ([string]$Document.source_revision -cnotmatch '^[0-9a-f]{40}$' -or [string]$Document.source_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$Document.generator_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$Document.report_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-report-invalid-digest' }
    try { [void][datetimeoffset]::Parse([string]$Document.generated_at_utc,[Globalization.CultureInfo]::InvariantCulture) } catch { throw 'rollout-report-invalid-time' }
    if ($Document.eligible -isnot [bool]) { throw 'rollout-report-invalid-eligibility' }
    Assert-HarnessRolloutKeys -Value $Document.gates -Expected $gateNames -Label 'gates'
    $allPass = $true
    foreach ($name in $gateNames) {
        $gate = $Document.gates[$name]
        Assert-HarnessRolloutKeys -Value $gate -Expected @('status','evidence_digest','command') -Label "gate-$name"
        if ([string]$gate.status -cnotin @('pass','fail','blocked','unavailable','simulated')) { throw 'rollout-report-invalid-status' }
        if ([string]$gate.evidence_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$gate.command -cne [string]$gateCommands[$name]) { throw 'rollout-report-invalid-gate' }
        if ([string]$gate.status -cne 'pass') { $allPass = $false }
    }
    if ([bool]$Document.eligible -ne $allPass) { throw 'rollout-report-invalid-eligibility' }
    if ([string]$Document.report_digest -cne (Get-HarnessRolloutReportDigest -Document $Document)) { throw 'rollout-report-digest-mismatch' }
    Assert-HarnessRolloutDistributionClean -RepoRoot $RepoRoot
    Assert-HarnessRolloutSourceHeadBound -RepoRoot $RepoRoot
    if ([string]$Document.source_revision -cne (Get-HarnessRolloutRevision -RepoRoot $RepoRoot)) { throw 'rollout-report-stale-revision' }
    if ([string]$Document.source_digest -cne (Get-HarnessRolloutSourceDigest -RepoRoot $RepoRoot)) { throw 'rollout-report-stale-source' }
    $generatorDigest = Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path 'scripts/generate-v2-rollout-report.ps1'
    if ([string]$Document.generator_digest -cne $generatorDigest) { throw 'rollout-report-stale-generator' }
}

function New-HarnessRolloutReportDocument {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Gates)
    Assert-HarnessRolloutRepositoryClean -RepoRoot $RepoRoot
    $gateNames = @('behavior','v1_compatibility','direct_performance','core_install_rollback','full_install_rollback')
    Assert-HarnessRolloutKeys -Value $Gates -Expected $gateNames -Label 'gates'
    $eligible = @($gateNames | Where-Object { [string]$Gates[$_].status -cne 'pass' }).Count -eq 0
    $document = [ordered]@{
        schema_version = 'rollout-eligibility/v1'
        source_revision = Get-HarnessRolloutRevision -RepoRoot $RepoRoot
        source_digest = Get-HarnessRolloutSourceDigest -RepoRoot $RepoRoot
        generator_digest = Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path 'scripts/generate-v2-rollout-report.ps1'
        generated_at_utc = [datetime]::UtcNow.ToString('o')
        gates = $Gates
        eligible = $eligible
        report_digest = ''
    }
    $document.report_digest = Get-HarnessRolloutReportDigest -Document $document
    Assert-HarnessRolloutReport -RepoRoot $RepoRoot -Document $document
    return $document
}

function Get-HarnessRolloutEligibility {
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [AllowEmptyString()][string]$ReportPath = ''
    )
    if ([string]::IsNullOrWhiteSpace($ReportPath)) { return [ordered]@{status='missing';eligible=$false;reason='rollout-report-missing';report_digest=$null} }
    try {
        $target = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ReportPath -Label 'rollout eligibility report' -AllowMissing
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return [ordered]@{status='missing';eligible=$false;reason='rollout-report-missing';report_digest=$null} }
        $reportLimitBytes = 4MB
        $reportInfo = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($reportInfo.Length -gt $reportLimitBytes) { throw 'rollout-report-too-large' }
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($target,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
            $reportLength = $stream.Length
            if ($reportLength -gt $reportLimitBytes) { throw 'rollout-report-too-large' }
            $bytes = [byte[]]::new([int]$reportLength)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
                if ($read -le 0) { throw 'rollout-report-invalid' }
                $offset += $read
            }
            if ($stream.ReadByte() -ne -1) { throw 'rollout-report-too-large' }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if ($bytes.Length -gt $reportLimitBytes) { throw 'rollout-report-too-large' }
        try {
            $json = [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            $document = $json | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        } catch {
            throw 'rollout-report-invalid-json'
        }
        Assert-HarnessRolloutReport -RepoRoot $RepoRoot -Document $document
        if (-not [bool]$document.eligible) {
            foreach ($name in @('behavior','v1_compatibility','direct_performance','core_install_rollback','full_install_rollback')) {
                $status = [string]$document.gates[$name].status
                if ($status -cne 'pass') { return [ordered]@{status='ineligible';eligible=$false;reason="rollout-gate-$name-$status";report_digest=[string]$document.report_digest} }
            }
        }
        return [ordered]@{status='pass';eligible=$true;reason='eligible-rollout-report';report_digest=[string]$document.report_digest}
    } catch {
        $reason = [string]$_.Exception.Message
        if (-not $reason.StartsWith('rollout-',[StringComparison]::Ordinal)) { $reason = 'rollout-report-invalid' }
        $status = if ($reason.StartsWith('rollout-report-stale',[StringComparison]::Ordinal)) { 'stale' } else { 'invalid' }
        return [ordered]@{status=$status;eligible=$false;reason=$reason;report_digest=$null}
    }
}

function Get-HarnessProtocolResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$TaskId = '',
        [string]$RequestedProtocol = '',
        [string]$RepoRoot = '',
        [string]$EligibilityReportPath = ''
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }
    $requested = $RequestedProtocol
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = [System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[System.EnvironmentVariableTarget]::Process)
    }
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = 'auto' }
    if ($requested -cnotin @('auto','v1','v2')) { throw 'HARNESS_PROTOCOL must be auto, v1, or v2' }

    $detected = 'new'
    $stage = $null
    $planPath = $null
    $planDigest = $null
    $taskStatePath = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskStatePath = ".assistant/runtime/tasks/$TaskId/task.json"
        $taskStateTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'v2 task state' -AllowMissing
        if (Test-Path -LiteralPath $taskStateTarget) {
            Assert-HarnessV2TaskArtifact -RepoRoot $RepoRoot -Path $taskStateTarget -TaskId $TaskId
            $detected = 'v2'
        } else {
            $planPath = "docs/tasks/$TaskId/plan.md"
            $planTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $planPath -Label 'v1 plan' -AllowMissing
            if (Test-Path -LiteralPath $planTarget) {
                if (-not (Test-Path -LiteralPath $planTarget -PathType Leaf)) { throw 'v1 plan path is not a file' }
                try {
                    $content = [System.IO.File]::ReadAllText($planTarget,[System.Text.UTF8Encoding]::new($false,$true))
                    $fields = Get-HarnessV1Frontmatter -Content $content
                    Assert-HarnessV1Frontmatter -Fields $fields -TaskId $TaskId
                } catch {
                    throw "v1 plan exists but is not a legal v1 artifact: $($_.Exception.Message)"
                }
                $detected = 'v1'
                $stage = [string]$fields['stage']
                $planDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $planPath
            }
        }
    }

    if ($detected -ceq 'v1' -and $requested -ceq 'v2') {
        throw 'existing v1 task cannot be forced to v2; run the explicit v1-to-v2 migration command'
    }
    if ($detected -ceq 'v2' -and $requested -ceq 'v1') {
        throw 'existing v2 task cannot use the v1 compatibility path'
    }

    $rollout = [ordered]@{status='not-required';eligible=$false;reason='artifact-or-explicit-selection';report_digest=$null}
    if ($detected -ceq 'new' -and $requested -ceq 'auto') {
        $reportPath = $EligibilityReportPath
        $reportPathSelected = $PSBoundParameters.ContainsKey('EligibilityReportPath')
        if (-not $reportPathSelected) {
            $environmentReportPath = [Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)
            if ($null -ne $environmentReportPath) {
                $reportPath = $environmentReportPath
                $reportPathSelected = $true
            }
        }
        if (-not $reportPathSelected) { $reportPath = '.assistant/runtime/rollout/v2-eligibility.json' }
        $rollout = Get-HarnessRolloutEligibility -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ReportPath $reportPath
    }
    $selected = if ($detected -cin @('v1','v2')) {
        $detected
    } elseif ($requested -ceq 'v2') {
        'v2'
    } elseif ($requested -ceq 'v1') {
        'v1'
    } elseif ($rollout.eligible) {
        'v2'
    } else {
        'v1'
    }
    $reason = if ($detected -ceq 'v2') {
        'existing-v2-task-state'
    } elseif ($detected -ceq 'v1') {
        'existing-v1-plan'
    } elseif ($requested -ceq 'v2') {
        'explicit-v2-new-task'
    } elseif ($requested -ceq 'v1') {
        'explicit-v1-new-task'
    } elseif ($rollout.eligible) {
        'eligible-rollout-report'
    } else {
        [string]$rollout.reason
    }
    $warning = if ($selected -ceq 'v1') { 'v1 protocol is deprecated but remains supported; HARNESS_PROTOCOL=v1 is the rollback switch.' } else { $null }

    return [ordered]@{
        operation='protocol'
        task_id=$(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        requested_protocol=$requested
        detected_protocol=$detected
        selected_protocol=$selected
        reason=$reason
        warning=$warning
        rollout_eligibility=$rollout
        v1_stage=$stage
        v1_plan_path=$(if ($detected -ceq 'v1') { $planPath } else { $null })
        v1_plan_digest=$planDigest
        v2_task_state_path=$(if ($detected -ceq 'v2') { $taskStatePath } else { $null })
        side_effects=[ordered]@{runtime_writes=0;artifact_writes=0}
    }
}

Export-ModuleMember -Function Get-HarnessProtocolResolution
