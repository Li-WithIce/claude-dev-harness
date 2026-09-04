$PSNativeCommandUseErrorActionPreference = $false

Import-Module (Join-Path $PSScriptRoot 'Harness.HostCapabilities.psm1') -Force -ErrorAction Stop

$script:RuntimeDefaultRelativePath = '.assistant/runtime/protocol-default.json'
$script:RuntimeSourcePaths = @(
    'agent-configs/claude/CLAUDE.md.template','agent-configs/workspace/AGENTS.md.template','harness.ps1'
    'policies/entry-contract.md','schemas/protocol-config.schema.json','schemas/protocol-config-v2.schema.json'
    'schemas/runtime-default-admission.schema.json','schemas/runtime-default-decision.schema.json','scripts/harness-status.ps1'
    'scripts/lib/Harness.AtomicWrite.psm1','scripts/lib/Harness.Hashing.psm1','scripts/lib/Harness.HostCapabilities.psm1'
    'scripts/lib/Harness.Path.psm1','scripts/lib/Harness.Policy.psm1','scripts/lib/Harness.Protocol.psm1'
    'scripts/lib/Harness.RuntimeDefaultReader.ps1','scripts/lib/Harness.RuntimeKernel.ps1','scripts/task.ps1'
)

function Get-HarnessRuntimeSourceIdentity {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $source = @((Invoke-HarnessGit -WorkspaceRoot $root -Arguments @('show','-s','--format=format:%H%n%T','HEAD') -FailureReason 'runtime-default-source-revision-unavailable').Lines)
    Assert-HarnessKernelCondition ($source.Count -eq 2 -and $source[0] -cmatch '^[0-9a-f]{40,64}$' -and $source[1] -cmatch '^[0-9a-f]{40,64}$') 'runtime-default-source-revision-unavailable'
    $indexLines = @((Invoke-HarnessGit -WorkspaceRoot $root -Arguments (@('ls-files','--stage','-v','--') + $script:RuntimeSourcePaths) -FailureReason 'runtime-default-source-index-unavailable').Lines)
    $statusLines = @((Invoke-HarnessGit -WorkspaceRoot $root -Arguments (@('-c','core.autocrlf=input','status','--porcelain=v2','--untracked-files=all','--') + $script:RuntimeSourcePaths) -FailureReason 'runtime-default-source-status-unavailable').Lines)

    Assert-HarnessKernelCondition (-not @($statusLines | Where-Object { $_.StartsWith('? ',[StringComparison]::Ordinal) }).Count) 'runtime-default-source-untracked-shadow'
    if ($statusLines.Count -gt 0) { throw 'runtime-default-source-dirty' }

    $indexedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $indexLines) {
        $match = [regex]::Match($line,'^(?<flag>\S) (?<mode>\d{6}) (?<oid>[0-9a-f]{40,64}) (?<stage>\d)\t(?<path>.+)$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
        Assert-HarnessKernelCondition ($match.Success -and $match.Groups['flag'].Value -ceq 'H' -and $match.Groups['mode'].Value -ceq '100644' -and $match.Groups['stage'].Value -ceq '0') 'runtime-default-source-unsafe-index'
        if (-not $indexedPaths.Add($match.Groups['path'].Value)) { throw 'runtime-default-source-unsafe-index' }
    }
    Assert-HarnessKernelCondition ($indexedPaths.Count -eq $script:RuntimeSourcePaths.Count -and -not @($script:RuntimeSourcePaths | Where-Object { -not $indexedPaths.Contains($_) }).Count) 'runtime-default-source-path-missing'

    $contract = [ordered]@{schema_version='harness-runtime-contract/v1';paths=@($script:RuntimeSourcePaths | ForEach-Object {
        [ordered]@{path=[string]$_;sha256=Get-HarnessSha256Bytes -Bytes ([IO.File]::ReadAllBytes((Join-Path $root ([string]$_))))}
    })}
    return [ordered]@{schema_version = 'harness-runtime-source-identity/v1'
        revision = [string]$source[0]
        tree_oid = [string]$source[1]
        path_set_digest = Get-HarnessUtf8TextSha256 -Text (($script:RuntimeSourcePaths -join "`n") + "`n")
        runtime_contract_digest = Get-HarnessUtf8TextSha256 -Text ($contract | ConvertTo-Json -Depth 10 -Compress)}
}

function Get-HarnessRuntimeDefaultDecisionDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    $body = Select-HarnessKernelKeys -Value $Document -Keys @('schema_version','new_task_protocol','scope','source_revision','source_identity','decision_id','issued_at_utc','expires_at_utc','workspace_identity_digest','required_capabilities')
    $body.required_capabilities = @($Document.required_capabilities)
    return Get-HarnessUtf8TextSha256 -Text ($body | ConvertTo-Json -Depth 10 -Compress)
}

function Get-HarnessRuntimeWorkspaceIdentityDigest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    return Get-HarnessUtf8TextSha256 -Text (Get-HarnessPhysicalPathIdentity -Path (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot))
}

function Assert-HarnessRuntimeDefaultDecision {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,[datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow,
        [AllowNull()][System.Collections.IDictionary]$ObservedSourceIdentity = $null)

    # Preserve the historical document Schema and digest algorithm; admission is narrower.
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $Document -Schema 'runtime-default-admission.schema.json' -Label 'runtime default' -Depth 20 -FailureMessage runtime-default-invalid-document
    Assert-HarnessKernelCondition ([string]$Document.decision_digest -ceq (Get-HarnessRuntimeDefaultDecisionDigest -Document $Document)) 'runtime-default-digest-mismatch'
    if ([string]$Document.source_revision -cne [string]$Document.source_identity.revision) { throw 'runtime-default-source-revision-mismatch' }
    if ($null -eq $ObservedSourceIdentity) { $ObservedSourceIdentity = Get-HarnessRuntimeSourceIdentity -RepoRoot $RepoRoot }
    if ([string]$Document.source_identity.revision -cne [string]$ObservedSourceIdentity.revision) { throw 'runtime-default-source-revision-mismatch' }
    if ([string]$Document.source_identity.tree_oid -cne [string]$ObservedSourceIdentity.tree_oid) { throw 'runtime-default-source-tree-mismatch' }
    if ([string]$Document.source_identity.path_set_digest -cne [string]$ObservedSourceIdentity.path_set_digest) { throw 'runtime-default-source-path-set-mismatch' }
    if ([string]$Document.source_identity.runtime_contract_digest -cne [string]$ObservedSourceIdentity.runtime_contract_digest) { throw 'runtime-default-source-contract-mismatch' }

    [datetimeoffset]$issuedAt = [datetimeoffset]::MinValue
    Assert-HarnessKernelCondition ([datetimeoffset]::TryParse([string]$Document.issued_at_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$issuedAt)) 'runtime-default-issued-at-invalid'
    if ($issuedAt -gt $AsOfUtc.AddSeconds(30)) { throw 'runtime-default-future-issued' }

    if ([string]$Document.scope -ceq 'workspace-canary') {
        Assert-HarnessKernelCondition ($Document.Contains('expires_at_utc') -and $Document.expires_at_utc -is [string] -and $Document.Contains('workspace_identity_digest') -and $Document.workspace_identity_digest -is [string]) 'runtime-default-canary-binding-missing'
        [datetimeoffset]$expiresAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$Document.expires_at_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expiresAt) -or
            $expiresAt -le $issuedAt) { throw 'runtime-default-expiry-invalid' }
        if ($expiresAt -le $AsOfUtc) { throw 'runtime-default-expired' }
        Assert-HarnessKernelCondition ([string]$Document.workspace_identity_digest -ceq (Get-HarnessRuntimeWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot)) 'runtime-default-workspace-mismatch'
    } else {
        Assert-HarnessKernelCondition ((-not $Document.Contains('expires_at_utc') -or $null -eq $Document.expires_at_utc) -and (-not $Document.Contains('workspace_identity_digest') -or $null -eq $Document.workspace_identity_digest)) 'runtime-default-release-binding-invalid'
    }
    return $true
}

function Get-HarnessRuntimeDefaultDecision {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [AllowNull()][System.Collections.IDictionary]$HostCapabilities = $null,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow)

    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    try {
        $path = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $script:RuntimeDefaultRelativePath -Label 'runtime default decision' -AllowMissing
        if (-not (Test-Path -LiteralPath $path)) {
            return [ordered]@{status='missing';usable=$false;reason='runtime-default-missing';path=$script:RuntimeDefaultRelativePath;decision_digest=$null;new_task_protocol=$null;scope=$null;required_capabilities=@();missing_capabilities=@();host_capabilities=$null}
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'runtime-default-not-regular-file' }
        try {
            $document = Read-HarnessKernelJsonPath -Path $path -Label 'runtime default' -MaximumBytes 64KB
        } catch {
            $reason = [string]$_.Exception.Message
            if ($reason.StartsWith('runtime-default-',[StringComparison]::Ordinal)) { throw }
            if ($reason -match 'too large$') { throw 'runtime-default-too-large' }
            if ($reason -match 'without BOM$') { throw 'runtime-default-bom-rejected' }
            if ($reason -match 'duplicate JSON key$') { throw 'runtime-default-duplicate-json-key' }
            if ($reason -match 'must be a JSON object$') { throw 'runtime-default-not-object' }
            throw 'runtime-default-invalid-json'
        }
        [void](Assert-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $workspace -Document $document -AsOfUtc $AsOfUtc)
        if ($null -eq $HostCapabilities) { $HostCapabilities = Get-HarnessHostCapabilities -RepoRoot $RepoRoot -RequiredCapabilities @($document.required_capabilities) }
        [void](Assert-HarnessHostCapabilitiesDocument -Document $HostCapabilities)
        $missing = @($document.required_capabilities | Where-Object { $HostCapabilities.capabilities[[string]$_] -ne $true })
        if ($missing.Count -gt 0) {
            return [ordered]@{status='unavailable';usable=$false;reason=('runtime-default-capability-missing-' + ($missing -join ','));path=$script:RuntimeDefaultRelativePath;decision_digest=[string]$document.decision_digest;new_task_protocol=[string]$document.new_task_protocol;scope=[string]$document.scope;required_capabilities=@($document.required_capabilities);missing_capabilities=$missing;host_capabilities=$HostCapabilities}
        }
        return [ordered]@{status='valid';usable=$true;reason=('runtime-default-' + [string]$document.new_task_protocol);path=$script:RuntimeDefaultRelativePath;decision_digest=[string]$document.decision_digest;new_task_protocol=[string]$document.new_task_protocol;scope=[string]$document.scope;required_capabilities=@($document.required_capabilities);missing_capabilities=@();host_capabilities=$HostCapabilities}
    } catch {
        $reason = [string]$_.Exception.Message
        if (-not $reason.StartsWith('runtime-default-',[StringComparison]::Ordinal)) { $reason = 'runtime-default-invalid' }
        return [ordered]@{status='invalid';usable=$false;reason=$reason;path=$script:RuntimeDefaultRelativePath;decision_digest=$null;new_task_protocol=$null;scope=$null;required_capabilities=@();missing_capabilities=@();host_capabilities=$null}
    }
}
