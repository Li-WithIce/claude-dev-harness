Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

$script:ProtocolConfigRelativePath = '.assistant/config/protocol.json'
$script:RolloutFinalEligibilityRelativePath = '.assistant/runtime/rollout/v2-eligibility.json'
$script:RolloutCanaryCandidateRelativePath = '.assistant/runtime/rollout/v2-canary-candidate.json'
$script:RolloutCanaryAuthorizationRelativePath = '.assistant/runtime/rollout/v2-canary-authorization.json'
$script:RolloutCanaryMaximumLifetime = [timespan]::FromDays(7)
$script:RolloutV1GateNames = @('behavior','v1_compatibility','direct_performance','core_install_rollback','full_install_rollback')
$script:RolloutV1GateCommands = [ordered]@{
    behavior = 'scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'
    v1_compatibility = 'scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'
    direct_performance = 'scripts/run-host-benchmark.ps1 -Groups 3 -Trials 3 -Model gpt-5.6-sol -Reasoning max'
    core_install_rollback = 'scripts/run-isolated-install-smoke.ps1 -Preset core'
    full_install_rollback = 'scripts/run-isolated-install-smoke.ps1 -Preset full'
}
$script:RolloutV2GateContracts = [ordered]@{
    'DP-G00-EXACT-HEAD-ENGINEERING-CI' = 'thin-harness-exact-head-engineering-evidence/v1'
    'DP-G01-MODEL40' = 'harness-model-eval-report/v2'
    'DP-G02-COGNITIVE-HOST-3X3' = 'harness-host-benchmark-report/v2'
    'DP-G03-INSTALLED-DESKTOP-HOST-3X3' = 'harness-installed-desktop-benchmark-report/v1'
    'DP-G04-CODEX-HOME-RUNNER-ISOLATION' = 'harness-release-isolation-report/v1'
    'DP-G05-V2-BARE-1.25' = 'harness-host-benchmark-report/v2'
    'DP-G06-REQUEST-SEND-REDUCTION' = 'harness-host-benchmark-report/v2'
    'DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE' = 'harness-installed-desktop-benchmark-report/v1'
    'DP-G09-RELEASE-MODEL' = 'harness-release-model-receipt/v1'
    'DP-G10-RELEASE-HOST' = 'harness-release-host-receipt/v1'
    'DP-G11-RELEASE-FULL' = 'harness-release-full-receipt/v1'
    'DP-G12-ROLLOUT-ELIGIBILITY-REPORT' = 'rollout-report-review-receipt/v1'
    'DP-G13-PROMOTION-AUTO-PROBE' = 'harness-canary-promotion-receipt/v1'
    'DP-G14-V1-STOP-LOSS' = 'harness-v1-stop-loss-report/v1'
    'DP-G15-CANARY' = 'harness-canary-observation-report/v1'
    'DP-G16-STABLE-DECISION' = 'harness-stable-decision/v1'
    'DP-G18-CORE-LIFECYCLE' = 'harness-preset-lifecycle-report/v1'
    'DP-G19-GOVERNED-LIFECYCLE' = 'harness-preset-lifecycle-report/v1'
    'DP-G20-FULL-LIFECYCLE' = 'harness-preset-lifecycle-report/v1'
}
$script:RolloutV2PostPromotionGates = @('DP-G13-PROMOTION-AUTO-PROBE','DP-G15-CANARY','DP-G16-STABLE-DECISION')

function Get-HarnessWorkspaceProtocolConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            status = 'missing'
            path = $script:ProtocolConfigRelativePath
            document = [ordered]@{schema_version='harness-protocol-config/v1';new_task_protocol='auto'}
            digest = $null
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'workspace protocol config is not a file' }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 4096) { throw 'workspace protocol config is too large' }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'workspace protocol config must be UTF-8 without BOM'
    }

    $jsonDocument = $null
    try {
        $text = [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text)
        if ($jsonDocument.RootElement.ValueKind -cne [System.Text.Json.JsonValueKind]::Object) {
            throw 'workspace protocol config must be a JSON object'
        }
        $propertyNames = @($jsonDocument.RootElement.EnumerateObject() | ForEach-Object { $_.Name })
        if ($propertyNames.Count -ne 2 -or
            @($propertyNames | Select-Object -Unique).Count -ne 2 -or
            $propertyNames -cnotcontains 'schema_version' -or
            $propertyNames -cnotcontains 'new_task_protocol') {
            throw 'workspace protocol config keys are invalid'
        }
        $document = $text | ConvertFrom-HarnessJson -ErrorAction Stop
    } catch {
        throw "workspace protocol config is not strict UTF-8 JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }

    $schemaPath = Join-Path $RepoRoot 'schemas/protocol-config.schema.json'
    try {
        $valid = Test-Json -Json ($document | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "workspace protocol config schema validation failed: $($_.Exception.Message)"
    }
    if (-not $valid) { throw 'workspace protocol config failed schema validation' }
    return [ordered]@{
        status = 'present'
        path = $script:ProtocolConfigRelativePath
        document = $document
        digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path
    }
}

function Set-HarnessWorkspaceProtocolConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidateSet('auto','v1','v2')][string]$NewTaskProtocol
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    [void](Resolve-Path -LiteralPath (Join-Path $RepoRoot 'schemas/protocol-config.schema.json') -ErrorAction Stop)
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing)
    $document = [ordered]@{schema_version='harness-protocol-config/v1';new_task_protocol=$NewTaskProtocol}
    $content = ($document | ConvertTo-Json -Depth 10) + "`n"
    $digest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Content $content
    return [ordered]@{
        operation = 'protocol-config'
        action = $(switch ($NewTaskProtocol) {'v2' {'enable-v2'} 'v1' {'disable-v2'} default {'reset-auto'}})
        path = $script:ProtocolConfigRelativePath
        new_task_protocol = $NewTaskProtocol
        digest = $digest
        side_effects = [ordered]@{config_writes=1;runtime_writes=0;artifact_writes=0}
    }
}

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
        $document = $json | ConvertFrom-HarnessJson -ErrorAction Stop
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

function Get-HarnessRolloutV2GateContracts {
    param([switch]$InputOnly)
    $copy = [ordered]@{}
    foreach ($name in $script:RolloutV2GateContracts.Keys) {
        if ($InputOnly -and [string]$name -ceq 'DP-G12-ROLLOUT-ELIGIBILITY-REPORT') { continue }
        $copy[[string]$name] = [string]$script:RolloutV2GateContracts[$name]
    }
    return $copy
}

function Get-HarnessRolloutV2ExpectedHost {
    return [ordered]@{
        product = 'codex-cli-service'
        observed_version = '0.144.4'
        hook_contract = 'codex-0.144.4-environment-shell-hook/v1'
        invocation_telemetry_contract = 'codex-invocation-telemetry/v2'
        request_send_contract = 'codex-0.144.4-successful-websocket-send/v2'
    }
}

function Assert-HarnessStrictJsonElement {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'duplicate JSON property' }
            Assert-HarnessStrictJsonElement -Element $property.Value
        }
    } elseif ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-HarnessStrictJsonElement -Element $item }
    }
}

function ConvertFrom-HarnessRolloutJsonBytes {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('report','evidence-set','canary-authorization','observed-host-context','review-payload','review-receipt')][string]$Kind
    )
    $prefix = switch ($Kind) {
        'report' { 'rollout-report' }
        'evidence-set' { 'rollout-evidence-set' }
        'canary-authorization' { 'rollout-canary-authorization' }
        'observed-host-context' { 'rollout-observed-host-context' }
        'review-payload' { 'rollout-review-payload' }
        default { 'rollout-review-receipt' }
    }
    $jsonDocument = $null
    try {
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw 'UTF-8 BOM is not allowed' }
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $options.AllowTrailingCommas = $false
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text,$options)
        if ($jsonDocument.RootElement.ValueKind -cne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
        Assert-HarnessStrictJsonElement -Element $jsonDocument.RootElement
        $document = $text | ConvertFrom-HarnessJson -Depth 100 -ErrorAction Stop
        if ($document -isnot [System.Collections.IDictionary]) { throw 'root must be an object' }
        return $document
    } catch {
        throw "${prefix}-invalid-json"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }
}

function Assert-HarnessRolloutSchema {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][string]$SchemaRelativePath,
        [Parameter(Mandatory)][string]$ErrorReason
    )
    $schemaPath = Join-Path $RepoRoot $SchemaRelativePath
    try {
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'schema missing' }
        $valid = Test-Json -Json ($Document | ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue
    } catch { throw $ErrorReason }
    if (-not $valid) { throw $ErrorReason }
}

function Assert-HarnessRolloutUtcTime {
    param([Parameter(Mandatory)][string]$Value,[Parameter(Mandatory)][string]$ErrorReason)
    try { $time = [datetimeoffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture) } catch { throw $ErrorReason }
    if ($time.Offset -ne [timespan]::Zero) { throw $ErrorReason }
}

function Get-HarnessObservedHostContextDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        product = $Document.product
        cli_version = $Document.cli_version
        service_version = $Document.service_version
        hook_contract = $Document.hook_contract
        invocation_telemetry_contract = $Document.invocation_telemetry_contract
        request_send_contract = $Document.request_send_contract
        observed_at_utc = $Document.observed_at_utc
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-HarnessObservedHostContext {
    param(
        [string]$RepoRoot,
        [System.Collections.IDictionary]$Document,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow
    )
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-observed-host-context.schema.json' -ErrorReason 'rollout-observed-host-context-invalid-document'
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','product','cli_version','service_version','hook_contract','invocation_telemetry_contract','request_send_contract','observed_at_utc','context_digest') -Label 'observed-host-context'
    if ([string]$Document.schema_version -cne 'rollout-observed-host-context/v1') { throw 'rollout-observed-host-context-invalid-schema' }
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.observed_at_utc) -ErrorReason 'rollout-observed-host-context-invalid-time'
    $observedAt = [datetimeoffset]::Parse([string]$Document.observed_at_utc,[Globalization.CultureInfo]::InvariantCulture)
    if ($observedAt -gt $AsOfUtc) { throw 'rollout-observed-host-context-future' }
    if ([string]$Document.context_digest -cne (Get-HarnessObservedHostContextDigest -Document $Document)) { throw 'rollout-observed-host-context-digest-mismatch' }
    if ([string]$Document.product -cne 'codex-cli-service') { throw 'rollout-observed-host-context-product-mismatch' }
    if ([string]$Document.cli_version -cne '0.144.4') { throw 'rollout-observed-host-context-cli-version-mismatch' }
    if ([string]$Document.service_version -cne '0.144.4') { throw 'rollout-observed-host-context-service-version-mismatch' }
    if ([string]$Document.hook_contract -cne 'codex-0.144.4-environment-shell-hook/v1') { throw 'rollout-observed-host-context-hook-contract-mismatch' }
    if ([string]$Document.invocation_telemetry_contract -cne 'codex-invocation-telemetry/v2') { throw 'rollout-observed-host-context-invocation-telemetry-contract-mismatch' }
    if ([string]$Document.request_send_contract -cne 'codex-0.144.4-successful-websocket-send/v2') { throw 'rollout-observed-host-context-request-send-contract-mismatch' }
}

function New-HarnessObservedHostContextDocument {
    param(
        [string]$RepoRoot,
        [string]$CliVersion = '0.144.4',
        [string]$ServiceVersion = '0.144.4',
        [string]$HookContract = 'codex-0.144.4-environment-shell-hook/v1',
        [string]$InvocationTelemetryContract = 'codex-invocation-telemetry/v2',
        [string]$RequestSendContract = 'codex-0.144.4-successful-websocket-send/v2',
        [datetimeoffset]$ObservedAtUtc = [datetimeoffset]::UtcNow,
        [switch]$SkipSemanticValidation
    )
    $document = [ordered]@{
        schema_version = 'rollout-observed-host-context/v1'
        product = 'codex-cli-service'
        cli_version = $CliVersion
        service_version = $ServiceVersion
        hook_contract = $HookContract
        invocation_telemetry_contract = $InvocationTelemetryContract
        request_send_contract = $RequestSendContract
        observed_at_utc = $ObservedAtUtc.ToUniversalTime().ToString('o')
        context_digest = ''
    }
    $document.context_digest = Get-HarnessObservedHostContextDigest -Document $document
    if (-not $SkipSemanticValidation) { Assert-HarnessObservedHostContext -RepoRoot $RepoRoot -Document $document }
    return $document
}

function Get-HarnessRolloutReviewPayloadDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        phase = $Document.phase
        source_revision = $Document.source_revision
        source_digest = $Document.source_digest
        generator_digest = $Document.generator_digest
        generated_at_utc = $Document.generated_at_utc
        host = $Document.host
        gates = $Document.gates
        provenance_status = $Document.provenance_status
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 100 -Compress)
}

function Get-HarnessRolloutReviewReceiptDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        reviewed_payload_digest = $Document.reviewed_payload_digest
        source_revision = $Document.source_revision
        phase = $Document.phase
        reviewer_actor_id = $Document.reviewer_actor_id
        reviewer_context_id = $Document.reviewer_context_id
        reviewer_model = $Document.reviewer_model
        read_only = $Document.read_only
        verdict = $Document.verdict
        findings = $Document.findings
        created_at_utc = $Document.created_at_utc
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 30 -Compress)
}

function Assert-HarnessRolloutReviewReceipt {
    param(
        [string]$RepoRoot,
        [System.Collections.IDictionary]$Document,
        [string]$ExpectedPayloadDigest,
        [string]$ExpectedSourceRevision,
        [string]$ExpectedPhase
    )
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-review-receipt.schema.json' -ErrorReason 'rollout-review-receipt-invalid-document'
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','reviewed_payload_digest','source_revision','phase','reviewer_actor_id','reviewer_context_id','reviewer_model','read_only','verdict','findings','created_at_utc','receipt_digest') -Label 'review-receipt'
    if ([string]$Document.schema_version -cne 'rollout-report-review-receipt/v1') { throw 'rollout-review-receipt-invalid-schema' }
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.created_at_utc) -ErrorReason 'rollout-review-receipt-invalid-time'
    if ([string]$Document.receipt_digest -cne (Get-HarnessRolloutReviewReceiptDigest -Document $Document)) { throw 'rollout-review-receipt-digest-mismatch' }
    if ([string]$Document.reviewed_payload_digest -cne $ExpectedPayloadDigest) { throw 'rollout-review-receipt-payload-mismatch' }
    if ([string]$Document.source_revision -cne $ExpectedSourceRevision) { throw 'rollout-review-receipt-source-mismatch' }
    if ([string]$Document.phase -cne $ExpectedPhase) { throw 'rollout-review-receipt-phase-mismatch' }
    if ($Document.read_only -ne $true) { throw 'rollout-review-receipt-not-read-only' }
    if ([string]$Document.verdict -cne 'pass') { throw 'rollout-review-receipt-verdict' }
    if ([int]$Document.findings.p0 -ne 0 -or [int]$Document.findings.p1 -ne 0 -or [int]$Document.findings.p2 -ne 0) { throw 'rollout-review-receipt-findings' }
}

function New-HarnessRolloutReviewReceiptDocument {
    param(
        [string]$RepoRoot,
        [System.Collections.IDictionary]$Payload,
        [string]$ReviewerActorId,
        [string]$ReviewerContextId,
        [string]$ReviewerModel,
        [datetimeoffset]$CreatedAtUtc = [datetimeoffset]::UtcNow
    )
    $document = [ordered]@{
        schema_version = 'rollout-report-review-receipt/v1'
        reviewed_payload_digest = [string]$Payload.reviewed_payload_digest
        source_revision = [string]$Payload.source_revision
        phase = [string]$Payload.phase
        reviewer_actor_id = $ReviewerActorId
        reviewer_context_id = $ReviewerContextId
        reviewer_model = $ReviewerModel
        read_only = $true
        verdict = 'pass'
        findings = [ordered]@{p0=0;p1=0;p2=0}
        created_at_utc = $CreatedAtUtc.ToUniversalTime().ToString('o')
        receipt_digest = ''
    }
    $document.receipt_digest = Get-HarnessRolloutReviewReceiptDigest -Document $document
    Assert-HarnessRolloutReviewReceipt -RepoRoot $RepoRoot -Document $document -ExpectedPayloadDigest ([string]$Payload.reviewed_payload_digest) -ExpectedSourceRevision ([string]$Payload.source_revision) -ExpectedPhase ([string]$Payload.phase)
    return $document
}

function Assert-HarnessRolloutV2Host {
    param([System.Collections.IDictionary]$Binding)
    $expected = Get-HarnessRolloutV2ExpectedHost
    Assert-HarnessRolloutKeys -Value $Binding -Expected @($expected.Keys) -Label 'host'
    foreach ($name in $expected.Keys) {
        if ([string]$Binding[$name] -cne [string]$expected[$name]) { throw "rollout-report-host-binding-$name" }
    }
}

function Assert-HarnessRolloutV2GateSet {
    param(
        [System.Collections.IDictionary]$Gates,
        [Parameter(Mandatory)][string]$SourceRevision,
        [Parameter(Mandatory)][ValidateSet('canary-candidate','final-default')][string]$Phase,
        [switch]$InputOnly,
        [switch]$AllowNonAuthorizingStatus
    )
    $contracts = Get-HarnessRolloutV2GateContracts -InputOnly:$InputOnly
    Assert-HarnessRolloutKeys -Value $Gates -Expected @($contracts.Keys) -Label 'gates'
    foreach ($name in $contracts.Keys) {
        $gate = $Gates[$name]
        Assert-HarnessRolloutKeys -Value $gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label "gate-$name"
        if ([string]$gate.status -cnotin @('pass','fail','blocked','unavailable','simulated','not_run','pending','skipped','manual')) { throw 'rollout-report-invalid-status' }
        if ([string]$gate.evidence_contract -cne [string]$contracts[$name]) { throw "rollout-report-evidence-contract-$name" }
        if ([string]::IsNullOrWhiteSpace([string]$gate.artifact_path) -or [string]::IsNullOrWhiteSpace([string]$gate.producer_identity)) { throw 'rollout-evidence-provenance-unverified' }
        if ([string]$gate.evidence_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-report-invalid-digest' }
        if ([string]$gate.source_revision -cne $SourceRevision) { throw "rollout-report-evidence-revision-$name" }
    }
    if (-not $AllowNonAuthorizingStatus) {
        foreach ($name in $contracts.Keys) {
            $expectedStatus = if ($Phase -ceq 'canary-candidate' -and [string]$name -cin $script:RolloutV2PostPromotionGates) { 'not_run' } else { 'pass' }
            if ([string]$Gates[$name].status -cne $expectedStatus) { throw "rollout-report-phase-gate-$name" }
        }
    }
}

function Test-HarnessRolloutEvidenceProvenanceShape {
    param([System.Collections.IDictionary]$Document)
    if ($Document -isnot [System.Collections.IDictionary] -or -not $Document.Contains('gates') -or $Document.gates -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($gate in @($Document.gates.Values)) {
        if ($gate -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($name in @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity')) {
            if (-not $gate.Contains($name)) { return $false }
        }
        if ([string]::IsNullOrWhiteSpace([string]$gate.artifact_path) -or [string]::IsNullOrWhiteSpace([string]$gate.producer_identity)) { return $false }
    }
    return $true
}

function Assert-HarnessRolloutReviewPayload {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-review-payload.schema.json' -ErrorReason 'rollout-review-payload-invalid-document'
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','phase','source_revision','source_digest','generator_digest','generated_at_utc','host','gates','provenance_status','reviewed_payload_digest') -Label 'review-payload'
    if ([string]$Document.schema_version -cne 'rollout-review-payload/v1') { throw 'rollout-review-payload-invalid-schema' }
    if ([string]$Document.phase -cnotin @('canary-candidate','final-default')) { throw 'rollout-review-payload-invalid-phase' }
    if ([string]$Document.provenance_status -cnotin @('verified','unverified','test-only')) { throw 'rollout-review-payload-invalid-provenance' }
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.generated_at_utc) -ErrorReason 'rollout-review-payload-invalid-time'
    Assert-HarnessRolloutV2Host -Binding $Document.host
    Assert-HarnessRolloutV2GateSet -Gates $Document.gates -SourceRevision ([string]$Document.source_revision) -Phase ([string]$Document.phase) -InputOnly -AllowNonAuthorizingStatus:([string]$Document.provenance_status -ceq 'unverified')
    if ([string]$Document.reviewed_payload_digest -cne (Get-HarnessRolloutReviewPayloadDigest -Document $Document)) { throw 'rollout-review-payload-digest-mismatch' }
    Assert-HarnessRolloutDistributionClean -RepoRoot $RepoRoot
    Assert-HarnessRolloutSourceHeadBound -RepoRoot $RepoRoot
    if ([string]$Document.source_revision -cne (Get-HarnessRolloutRevision -RepoRoot $RepoRoot)) { throw 'rollout-review-payload-stale-revision' }
    if ([string]$Document.source_digest -cne (Get-HarnessRolloutSourceDigest -RepoRoot $RepoRoot)) { throw 'rollout-review-payload-stale-source' }
    $generatorDigest = Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path 'scripts/generate-v2-rollout-report.ps1'
    if ([string]$Document.generator_digest -cne $generatorDigest) { throw 'rollout-review-payload-stale-generator' }
}

function New-HarnessRolloutReviewPayloadDocument {
    param(
        [string]$RepoRoot,
        [System.Collections.IDictionary]$EvidenceSet,
        [Parameter(Mandatory)][ValidateSet('verified','unverified','test-only')][string]$ProvenanceStatus
    )
    Assert-HarnessRolloutV2EvidenceSet -RepoRoot $RepoRoot -Document $EvidenceSet
    $gates = [ordered]@{}
    foreach ($name in (Get-HarnessRolloutV2GateContracts -InputOnly).Keys) {
        $input = $EvidenceSet.gates[$name]
        $status = if ($ProvenanceStatus -ceq 'unverified') {
            if ([string]$EvidenceSet.phase -ceq 'canary-candidate' -and [string]$name -cin $script:RolloutV2PostPromotionGates) { 'not_run' } else { 'unavailable' }
        } else { [string]$input.status }
        $gates[$name] = [ordered]@{
            status = $status
            evidence_contract = [string]$input.evidence_contract
            artifact_path = [string]$input.artifact_path
            evidence_digest = [string]$input.evidence_digest
            source_revision = [string]$input.source_revision
            producer_identity = [string]$input.producer_identity
        }
    }
    $hostBinding = [ordered]@{}
    foreach ($name in (Get-HarnessRolloutV2ExpectedHost).Keys) { $hostBinding[$name] = [string]$EvidenceSet.host[$name] }
    $document = [ordered]@{
        schema_version = 'rollout-review-payload/v1'
        phase = [string]$EvidenceSet.phase
        source_revision = Get-HarnessRolloutRevision -RepoRoot $RepoRoot
        source_digest = Get-HarnessRolloutSourceDigest -RepoRoot $RepoRoot
        generator_digest = Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path 'scripts/generate-v2-rollout-report.ps1'
        generated_at_utc = [datetimeoffset]::UtcNow.ToString('o')
        host = $hostBinding
        gates = $gates
        provenance_status = $ProvenanceStatus
        reviewed_payload_digest = ''
    }
    $document.reviewed_payload_digest = Get-HarnessRolloutReviewPayloadDigest -Document $document
    Assert-HarnessRolloutReviewPayload -RepoRoot $RepoRoot -Document $document
    return $document
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

function Get-HarnessRolloutV1ReportDigest {
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

function Get-HarnessRolloutV2ReportDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        phase = $Document.phase
        source_revision = $Document.source_revision
        source_digest = $Document.source_digest
        generator_digest = $Document.generator_digest
        generated_at_utc = $Document.generated_at_utc
        host = $Document.host
        review_payload_digest = $Document.review_payload_digest
        review_receipt = $Document.review_receipt
        provenance_status = $Document.provenance_status
        gates = $Document.gates
        eligible = $Document.eligible
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 100 -Compress)
}

function Get-HarnessRolloutReportDigest {
    param([System.Collections.IDictionary]$Document)
    if ([string]$Document.schema_version -ceq 'rollout-eligibility/v1') { return Get-HarnessRolloutV1ReportDigest -Document $Document }
    if ([string]$Document.schema_version -ceq 'rollout-eligibility/v2') { return Get-HarnessRolloutV2ReportDigest -Document $Document }
    throw 'rollout-report-invalid-schema'
}

function Assert-HarnessRolloutV1Report {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    $gateNames = $script:RolloutV1GateNames
    $gateCommands = $script:RolloutV1GateCommands
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

function Convert-HarnessRolloutReportToReviewPayload {
    param([System.Collections.IDictionary]$Document)
    $gates = [ordered]@{}
    foreach ($name in (Get-HarnessRolloutV2GateContracts -InputOnly).Keys) {
        $gate = $Document.gates[$name]
        $gates[$name] = [ordered]@{
            status = [string]$gate.status
            evidence_contract = [string]$gate.evidence_contract
            artifact_path = [string]$gate.artifact_path
            evidence_digest = [string]$gate.evidence_digest
            source_revision = [string]$gate.source_revision
            producer_identity = [string]$gate.producer_identity
        }
    }
    return [ordered]@{
        schema_version = 'rollout-review-payload/v1'
        phase = [string]$Document.phase
        source_revision = [string]$Document.source_revision
        source_digest = [string]$Document.source_digest
        generator_digest = [string]$Document.generator_digest
        generated_at_utc = [string]$Document.generated_at_utc
        host = $Document.host
        gates = $gates
        provenance_status = [string]$Document.provenance_status
        reviewed_payload_digest = [string]$Document.review_payload_digest
    }
}

function Assert-HarnessRolloutV2Report {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-eligibility-v2.schema.json' -ErrorReason 'rollout-report-invalid-document'
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','phase','source_revision','source_digest','generator_digest','generated_at_utc','host','review_payload_digest','review_receipt','provenance_status','gates','eligible','report_digest') -Label 'document'
    if ([string]$Document.schema_version -cne 'rollout-eligibility/v2') { throw 'rollout-report-invalid-schema' }
    if ([string]$Document.phase -cnotin @('canary-candidate','final-default')) { throw 'rollout-report-invalid-phase' }
    if ([string]$Document.provenance_status -cnotin @('verified','test-only')) { throw 'rollout-report-invalid-provenance' }
    if ([string]$Document.source_revision -cnotmatch '^[0-9a-f]{40}$' -or [string]$Document.source_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$Document.generator_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$Document.review_payload_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$Document.report_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-report-invalid-digest' }
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.generated_at_utc) -ErrorReason 'rollout-report-invalid-time'
    if ($Document.eligible -isnot [bool]) { throw 'rollout-report-invalid-eligibility' }
    Assert-HarnessRolloutV2Host -Binding $Document.host
    Assert-HarnessRolloutV2GateSet -Gates $Document.gates -SourceRevision ([string]$Document.source_revision) -Phase ([string]$Document.phase)
    $payload = Convert-HarnessRolloutReportToReviewPayload -Document $Document
    Assert-HarnessRolloutReviewPayload -RepoRoot $RepoRoot -Document $payload
    if ([string]$Document.review_payload_digest -cne [string]$payload.reviewed_payload_digest) { throw 'rollout-report-review-payload-mismatch' }
    Assert-HarnessRolloutReviewReceipt -RepoRoot $RepoRoot -Document $Document.review_receipt -ExpectedPayloadDigest ([string]$Document.review_payload_digest) -ExpectedSourceRevision ([string]$Document.source_revision) -ExpectedPhase ([string]$Document.phase)
    $reviewGate = $Document.gates['DP-G12-ROLLOUT-ELIGIBILITY-REPORT']
    if ([string]$reviewGate.status -cne 'pass' -or
        [string]$reviewGate.evidence_contract -cne 'rollout-report-review-receipt/v1' -or
        [string]$reviewGate.evidence_digest -cne [string]$Document.review_receipt.receipt_digest -or
        [string]$reviewGate.producer_identity -cne [string]$Document.review_receipt.reviewer_actor_id -or
        [string]::IsNullOrWhiteSpace([string]$reviewGate.artifact_path)) { throw 'rollout-report-review-binding-mismatch' }
    $expectedEligible = [string]$Document.phase -ceq 'final-default'
    if ([bool]$Document.eligible -ne $expectedEligible) { throw 'rollout-report-invalid-eligibility' }
    if ([string]$Document.report_digest -cne (Get-HarnessRolloutReportDigest -Document $Document)) { throw 'rollout-report-digest-mismatch' }
    Assert-HarnessRolloutDistributionClean -RepoRoot $RepoRoot
    Assert-HarnessRolloutSourceHeadBound -RepoRoot $RepoRoot
    if ([string]$Document.source_revision -cne (Get-HarnessRolloutRevision -RepoRoot $RepoRoot)) { throw 'rollout-report-stale-revision' }
    if ([string]$Document.source_digest -cne (Get-HarnessRolloutSourceDigest -RepoRoot $RepoRoot)) { throw 'rollout-report-stale-source' }
    $generatorDigest = Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path 'scripts/generate-v2-rollout-report.ps1'
    if ([string]$Document.generator_digest -cne $generatorDigest) { throw 'rollout-report-stale-generator' }
}

function Assert-HarnessRolloutReport {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    if ([string]$Document.schema_version -ceq 'rollout-eligibility/v1') { Assert-HarnessRolloutV1Report -RepoRoot $RepoRoot -Document $Document; return }
    if ([string]$Document.schema_version -ceq 'rollout-eligibility/v2') { Assert-HarnessRolloutV2Report -RepoRoot $RepoRoot -Document $Document; return }
    throw 'rollout-report-invalid-schema'
}

function Assert-HarnessRolloutV2EvidenceSet {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document)
    if (-not (Test-HarnessRolloutEvidenceProvenanceShape -Document $Document)) { throw 'rollout-evidence-provenance-unverified' }
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-evidence-set.schema.json' -ErrorReason 'rollout-evidence-set-invalid-document'
    Assert-HarnessRolloutKeys -Value $Document -Expected @('schema_version','phase','source_revision','host','gates') -Label 'evidence-set'
    if ([string]$Document.schema_version -cne 'rollout-evidence-set/v1') { throw 'rollout-evidence-set-invalid-schema' }
    if ([string]$Document.phase -cnotin @('canary-candidate','final-default')) { throw 'rollout-evidence-set-invalid-phase' }
    if ([string]$Document.source_revision -cnotmatch '^[0-9a-f]{40}$') { throw 'rollout-evidence-set-invalid-revision' }
    Assert-HarnessRolloutV2Host -Binding $Document.host
    Assert-HarnessRolloutV2GateSet -Gates $Document.gates -SourceRevision ([string]$Document.source_revision) -Phase ([string]$Document.phase) -InputOnly -AllowNonAuthorizingStatus
    Assert-HarnessRolloutRepositoryClean -RepoRoot $RepoRoot
    Assert-HarnessRolloutSourceHeadBound -RepoRoot $RepoRoot
    if ([string]$Document.source_revision -cne (Get-HarnessRolloutRevision -RepoRoot $RepoRoot)) { throw 'rollout-evidence-set-stale-revision' }
}

function New-HarnessRolloutV2ReportDocument {
    param(
        [string]$RepoRoot,
        [System.Collections.IDictionary]$ReviewPayload,
        [System.Collections.IDictionary]$ReviewReceipt,
        [string]$ReviewReceiptArtifactPath,
        [switch]$TestOnly
    )
    Assert-HarnessRolloutReviewPayload -RepoRoot $RepoRoot -Document $ReviewPayload
    Assert-HarnessRolloutReviewReceipt -RepoRoot $RepoRoot -Document $ReviewReceipt -ExpectedPayloadDigest ([string]$ReviewPayload.reviewed_payload_digest) -ExpectedSourceRevision ([string]$ReviewPayload.source_revision) -ExpectedPhase ([string]$ReviewPayload.phase)
    if ([string]::IsNullOrWhiteSpace($ReviewReceiptArtifactPath)) { throw 'rollout-review-receipt-artifact-path-required' }
    if ($TestOnly) {
        if ([string]$ReviewPayload.provenance_status -cne 'test-only') { throw 'rollout-report-test-only-payload-required' }
    } elseif ([string]$ReviewPayload.provenance_status -cne 'verified') { throw 'rollout-evidence-provenance-unverified' }
    $sourceRevision = [string]$ReviewPayload.source_revision
    $gates = [ordered]@{}
    foreach ($name in $script:RolloutV2GateContracts.Keys) {
        if ([string]$name -ceq 'DP-G12-ROLLOUT-ELIGIBILITY-REPORT') {
            $gates[$name] = [ordered]@{
                status = 'pass'
                evidence_contract = [string]$script:RolloutV2GateContracts[$name]
                artifact_path = $ReviewReceiptArtifactPath
                evidence_digest = [string]$ReviewReceipt.receipt_digest
                source_revision = $sourceRevision
                producer_identity = [string]$ReviewReceipt.reviewer_actor_id
            }
            continue
        }
        $gate = $ReviewPayload.gates[$name]
        $gates[$name] = [ordered]@{
            status = [string]$gate.status
            evidence_contract = [string]$gate.evidence_contract
            artifact_path = [string]$gate.artifact_path
            evidence_digest = [string]$gate.evidence_digest
            source_revision = [string]$gate.source_revision
            producer_identity = [string]$gate.producer_identity
        }
    }
    $document = [ordered]@{
        schema_version = 'rollout-eligibility/v2'
        phase = [string]$ReviewPayload.phase
        source_revision = $sourceRevision
        source_digest = [string]$ReviewPayload.source_digest
        generator_digest = [string]$ReviewPayload.generator_digest
        generated_at_utc = [string]$ReviewPayload.generated_at_utc
        host = $ReviewPayload.host
        review_payload_digest = [string]$ReviewPayload.reviewed_payload_digest
        review_receipt = $ReviewReceipt
        provenance_status = [string]$ReviewPayload.provenance_status
        gates = $gates
        eligible = [string]$ReviewPayload.phase -ceq 'final-default'
        report_digest = ''
    }
    $document.report_digest = Get-HarnessRolloutReportDigest -Document $document
    Assert-HarnessRolloutV2Report -RepoRoot $RepoRoot -Document $document
    return $document
}

function Get-HarnessWorkspaceIdentityDigest {
    param([string]$WorkspaceRoot)
    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return Get-HarnessSha256Text -Content (Get-HarnessPhysicalPathIdentity -Path $workspace)
}

function Get-HarnessCanaryAuthorizationDigest {
    param([System.Collections.IDictionary]$Document)
    $body = [ordered]@{
        schema_version = $Document.schema_version
        report_schema_version = $Document.report_schema_version
        report_phase = $Document.report_phase
        report_digest = $Document.report_digest
        source_revision = $Document.source_revision
        workspace_identity_digest = $Document.workspace_identity_digest
        observed_host_context_digest = $Document.observed_host_context_digest
        authorization_id = $Document.authorization_id
        authorized_by = $Document.authorized_by
        issued_at_utc = $Document.issued_at_utc
        expires_at_utc = $Document.expires_at_utc
        new_tasks_only = $Document.new_tasks_only
        status = $Document.status
    }
    return Get-HarnessSha256Text -Content ($body | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-HarnessCanaryAuthorization {
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [System.Collections.IDictionary]$Report,
        [System.Collections.IDictionary]$ObservedHostContext,
        [System.Collections.IDictionary]$Document,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow
    )
    Assert-HarnessRolloutSchema -RepoRoot $RepoRoot -Document $Document -SchemaRelativePath 'schemas/rollout-canary-authorization.schema.json' -ErrorReason 'rollout-canary-authorization-invalid-document'
    if ([string]$Report.schema_version -cne 'rollout-eligibility/v2' -or [string]$Report.phase -cne 'canary-candidate' -or [bool]$Report.eligible) { throw 'rollout-canary-authorization-report-phase' }
    if ([string]$Report.provenance_status -cne 'verified') { throw 'rollout-canary-authorization-report-provenance' }
    Assert-HarnessObservedHostContext -RepoRoot $RepoRoot -Document $ObservedHostContext -AsOfUtc $AsOfUtc
    if ([string]$Document.report_schema_version -cne [string]$Report.schema_version -or [string]$Document.report_phase -cne [string]$Report.phase -or [string]$Document.report_digest -cne [string]$Report.report_digest -or [string]$Document.source_revision -cne [string]$Report.source_revision) { throw 'rollout-canary-authorization-report-mismatch' }
    if ([string]$Document.observed_host_context_digest -cne [string]$ObservedHostContext.context_digest) { throw 'rollout-canary-authorization-host-context-mismatch' }
    if ([string]::IsNullOrWhiteSpace([string]$Document.authorized_by) -or [string]::IsNullOrWhiteSpace([string]$Document.authorization_id)) { throw 'rollout-canary-authorization-owner-required' }
    if ($Document.new_tasks_only -ne $true) { throw 'rollout-canary-authorization-new-tasks-only' }
    if ([string]$Document.status -cne 'granted') { throw 'rollout-canary-authorization-status' }
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.issued_at_utc) -ErrorReason 'rollout-canary-authorization-invalid-time'
    Assert-HarnessRolloutUtcTime -Value ([string]$Document.expires_at_utc) -ErrorReason 'rollout-canary-authorization-invalid-time'
    $issuedAt = [datetimeoffset]::Parse([string]$Document.issued_at_utc,[Globalization.CultureInfo]::InvariantCulture)
    $expiresAt = [datetimeoffset]::Parse([string]$Document.expires_at_utc,[Globalization.CultureInfo]::InvariantCulture)
    if ($issuedAt -gt $AsOfUtc) { throw 'rollout-canary-authorization-future-issued' }
    if ($expiresAt -le $issuedAt) { throw 'rollout-canary-authorization-invalid-expiry' }
    if (($expiresAt - $issuedAt) -gt $script:RolloutCanaryMaximumLifetime) { throw 'rollout-canary-authorization-duration-exceeded' }
    if ($expiresAt -le $AsOfUtc) { throw 'rollout-canary-authorization-expired' }
    if ([string]$Document.workspace_identity_digest -cne (Get-HarnessWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot)) { throw 'rollout-canary-authorization-workspace-mismatch' }
    if ([string]$Document.authorization_digest -cne (Get-HarnessCanaryAuthorizationDigest -Document $Document)) { throw 'rollout-canary-authorization-digest-mismatch' }
}

function New-HarnessCanaryAuthorizationDocument {
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [System.Collections.IDictionary]$Report,
        [System.Collections.IDictionary]$ObservedHostContext,
        [string]$AuthorizedBy,
        [datetimeoffset]$ExpiresAtUtc,
        [datetimeoffset]$IssuedAtUtc = [datetimeoffset]::UtcNow
    )
    Assert-HarnessRolloutV2Report -RepoRoot $RepoRoot -Document $Report
    if ([string]$Report.phase -cne 'canary-candidate' -or [bool]$Report.eligible) { throw 'rollout-canary-authorization-report-phase' }
    if ([string]$Report.provenance_status -cne 'verified') { throw 'rollout-canary-authorization-report-provenance' }
    if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) { throw 'rollout-canary-authorization-owner-required' }
    Assert-HarnessObservedHostContext -RepoRoot $RepoRoot -Document $ObservedHostContext -AsOfUtc $IssuedAtUtc
    $document = [ordered]@{
        schema_version = 'rollout-canary-authorization/v1'
        authorization_id = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        report_schema_version = [string]$Report.schema_version
        report_phase = [string]$Report.phase
        report_digest = [string]$Report.report_digest
        source_revision = [string]$Report.source_revision
        workspace_identity_digest = Get-HarnessWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot
        observed_host_context_digest = [string]$ObservedHostContext.context_digest
        authorized_by = $AuthorizedBy.Trim()
        issued_at_utc = $IssuedAtUtc.ToUniversalTime().ToString('o')
        expires_at_utc = $ExpiresAtUtc.ToUniversalTime().ToString('o')
        new_tasks_only = $true
        status = 'granted'
        authorization_digest = ''
    }
    $document.authorization_digest = Get-HarnessCanaryAuthorizationDigest -Document $document
    Assert-HarnessCanaryAuthorization -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Report $Report -ObservedHostContext $ObservedHostContext -Document $document -AsOfUtc $IssuedAtUtc
    return $document
}

function New-HarnessRolloutReportDocument {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Gates)
    Assert-HarnessRolloutRepositoryClean -RepoRoot $RepoRoot
    $gateNames = $script:RolloutV1GateNames
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

function Read-HarnessRolloutWorkspaceDocument {
    param(
        [string]$WorkspaceRoot,
        [string]$Path,
        [Parameter(Mandatory)][ValidateSet('report','canary-authorization')][string]$Kind
    )
    $label = if ($Kind -ceq 'report') { 'rollout eligibility report' } else { 'rollout Canary authorization' }
    $target = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $label -AllowMissing
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $null }
    $limit = if ($Kind -ceq 'report') { 4MB } else { 64KB }
    $tooLarge = if ($Kind -ceq 'report') { 'rollout-report-too-large' } else { 'rollout-canary-authorization-too-large' }
    $info = Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if ($info.Length -gt $limit) { throw $tooLarge }
    $stream = $null
    try {
        $stream = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -gt $limit) { throw $tooLarge }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw "rollout-$Kind-invalid-json" }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw $tooLarge }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $jsonKind = if ($Kind -ceq 'report') { 'report' } else { 'canary-authorization' }
    return ConvertFrom-HarnessRolloutJsonBytes -Bytes $bytes -Kind $jsonKind
}

function Assert-HarnessRolloutAuthorizingProvenance {
    param([System.Collections.IDictionary]$Document)
    if ([string]$Document.provenance_status -cne 'verified') { throw 'rollout-evidence-provenance-unverified' }
    foreach ($name in (Get-HarnessRolloutV2GateContracts -InputOnly).Keys) {
        throw "rollout-evidence-provenance-unwired-$name"
    }
}

function Get-HarnessRolloutEligibility {
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [AllowEmptyString()][string]$ReportPath = '',
        [AllowNull()][System.Collections.IDictionary]$ObservedHostContext = $null,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow
    )
    if ([string]::IsNullOrWhiteSpace($ReportPath)) { return [ordered]@{status='missing';eligible=$false;reason='rollout-report-missing';report_digest=$null} }
    try {
        $document = Read-HarnessRolloutWorkspaceDocument -WorkspaceRoot $WorkspaceRoot -Path $ReportPath -Kind report
        if ($null -eq $document) { return [ordered]@{status='missing';eligible=$false;reason='rollout-report-missing';report_digest=$null} }
        Assert-HarnessRolloutReport -RepoRoot $RepoRoot -Document $document
        if ([string]$document.schema_version -ceq 'rollout-eligibility/v1') {
            foreach ($name in $script:RolloutV1GateNames) {
                $status = [string]$document.gates[$name].status
                if ($status -cne 'pass') { return [ordered]@{status='historical';eligible=$false;reason="rollout-v1-historical-gate-$name-$status";report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v1';phase='historical-v1';report_eligible=[bool]$document.eligible} }
            }
            return [ordered]@{status='historical';eligible=$false;reason='rollout-v1-historical-diagnostic-only';report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v1';phase='historical-v1';report_eligible=[bool]$document.eligible}
        }
        if ($null -eq $ObservedHostContext) {
            return [ordered]@{status='unauthorized';eligible=$false;reason='rollout-observed-host-context-missing';report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase=[string]$document.phase;report_eligible=[bool]$document.eligible;authorization_digest=$null}
        }
        try { Assert-HarnessObservedHostContext -RepoRoot $RepoRoot -Document $ObservedHostContext -AsOfUtc $AsOfUtc }
        catch {
            $hostReason = [string]$_.Exception.Message
            if (-not $hostReason.StartsWith('rollout-observed-host-context',[StringComparison]::Ordinal)) { $hostReason = 'rollout-observed-host-context-invalid' }
            return [ordered]@{status='unauthorized';eligible=$false;reason=$hostReason;report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase=[string]$document.phase;report_eligible=[bool]$document.eligible;authorization_digest=$null}
        }
        if ([string]$document.phase -ceq 'final-default') {
            try { Assert-HarnessRolloutAuthorizingProvenance -Document $document }
            catch {
                $provenanceReason = [string]$_.Exception.Message
                if (-not $provenanceReason.StartsWith('rollout-evidence-provenance',[StringComparison]::Ordinal)) { $provenanceReason = 'rollout-evidence-provenance-unverified' }
                return [ordered]@{status='unavailable';eligible=$false;reason=$provenanceReason;report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase='final-default';report_eligible=$true;authorization_digest=$null}
            }
            return [ordered]@{status='pass';eligible=$true;reason='eligible-rollout-report';report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase='final-default';report_eligible=$true;authorization_digest=$null}
        }
        try {
            $authorization = Read-HarnessRolloutWorkspaceDocument -WorkspaceRoot $WorkspaceRoot -Path $script:RolloutCanaryAuthorizationRelativePath -Kind canary-authorization
            if ($null -eq $authorization) { throw 'rollout-canary-authorization-missing' }
            Assert-HarnessCanaryAuthorization -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Report $document -ObservedHostContext $ObservedHostContext -Document $authorization -AsOfUtc $AsOfUtc
        } catch {
            $authorizationReason = [string]$_.Exception.Message
            if (-not $authorizationReason.StartsWith('rollout-canary-authorization',[StringComparison]::Ordinal)) { $authorizationReason = 'rollout-canary-authorization-invalid' }
            return [ordered]@{status='unauthorized';eligible=$false;reason=$authorizationReason;report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase='canary-candidate';report_eligible=$false;authorization_digest=$null}
        }
        try { Assert-HarnessRolloutAuthorizingProvenance -Document $document }
        catch {
            $provenanceReason = [string]$_.Exception.Message
            if (-not $provenanceReason.StartsWith('rollout-evidence-provenance',[StringComparison]::Ordinal)) { $provenanceReason = 'rollout-evidence-provenance-unverified' }
            return [ordered]@{status='unavailable';eligible=$false;reason=$provenanceReason;report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase='canary-candidate';report_eligible=$false;authorization_digest=[string]$authorization.authorization_digest}
        }
        return [ordered]@{status='canary-authorized';eligible=$true;reason='authorized-canary-candidate';report_digest=[string]$document.report_digest;report_schema_version='rollout-eligibility/v2';phase='canary-candidate';report_eligible=$false;authorization_digest=[string]$authorization.authorization_digest}
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
        [string]$EligibilityReportPath = '',
        [AllowNull()][System.Collections.IDictionary]$ObservedHostContext = $null
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }
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

    $workspaceConfig = [ordered]@{status='not-read';path=$script:ProtocolConfigRelativePath;new_task_protocol=$null;digest=$null}
    $requested = $detected
    $preferenceSource = 'existing-artifact'
    if ($detected -ceq 'new') {
        $requested = $RequestedProtocol
        $preferenceSource = 'maintenance-override'
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $requested = [Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process)
            $preferenceSource = 'HARNESS_PROTOCOL'
        }
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $config = Get-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
            $workspaceConfig = [ordered]@{
                status = [string]$config.status
                path = [string]$config.path
                new_task_protocol = [string]$config.document.new_task_protocol
                digest = $config.digest
            }
            $requested = [string]$config.document.new_task_protocol
            $preferenceSource = if ([string]$config.status -ceq 'present') { 'workspace-config' } else { 'default-auto' }
        }
        if ($requested -cnotin @('auto','v1','v2')) { throw 'HARNESS_PROTOCOL must be auto, v1, or v2' }
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
        if (-not $reportPathSelected) {
            $finalTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:RolloutFinalEligibilityRelativePath -Label 'rollout final eligibility' -AllowMissing
            $reportPath = if (Test-Path -LiteralPath $finalTarget -PathType Leaf) { $script:RolloutFinalEligibilityRelativePath } else { $script:RolloutCanaryCandidateRelativePath }
        }
        $rollout = Get-HarnessRolloutEligibility -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ReportPath $reportPath -ObservedHostContext $ObservedHostContext
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
        $(if ($preferenceSource -ceq 'workspace-config') {'workspace-v2-new-task'} else {'explicit-v2-new-task'})
    } elseif ($requested -ceq 'v1') {
        $(if ($preferenceSource -ceq 'workspace-config') {'workspace-v1-new-task'} else {'explicit-v1-new-task'})
    } elseif ($rollout.eligible) {
        [string]$rollout.reason
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
        preference_source=$preferenceSource
        reason=$reason
        warning=$warning
        workspace_config=$workspaceConfig
        rollout_eligibility=$rollout
        v1_stage=$stage
        v1_plan_path=$(if ($detected -ceq 'v1') { $planPath } else { $null })
        v1_plan_digest=$planDigest
        v2_task_state_path=$(if ($detected -ceq 'v2') { $taskStatePath } else { $null })
        side_effects=[ordered]@{runtime_writes=0;artifact_writes=0}
    }
}

Export-ModuleMember -Function Get-HarnessWorkspaceProtocolConfig,Set-HarnessWorkspaceProtocolConfig,Get-HarnessProtocolResolution
