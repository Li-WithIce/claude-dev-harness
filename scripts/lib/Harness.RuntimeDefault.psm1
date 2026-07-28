Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.HostCapabilities.psm1') -Force -ErrorAction Stop

$script:RuntimeDefaultRelativePath = '.assistant/runtime/protocol-default.json'

function Get-HarnessRuntimeSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-HarnessRuntimeStrictJsonElement {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add([string]$property.Name)) { throw 'runtime-default-duplicate-json-key' }
            Assert-HarnessRuntimeStrictJsonElement -Element $property.Value
        }
    } elseif ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-HarnessRuntimeStrictJsonElement -Element $item }
    }
}

function Read-HarnessRuntimeDefaultJson {
    param([Parameter(Mandatory)][string]$Path)

    $limit = 64KB
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -gt $limit) { throw 'runtime-default-too-large' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -le 0) { throw 'runtime-default-truncated' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'runtime-default-too-large' }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'runtime-default-bom-rejected'
    }
    try {
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $json = [Text.Json.JsonDocument]::Parse($text)
        try {
            if ($json.RootElement.ValueKind -cne [Text.Json.JsonValueKind]::Object) { throw 'runtime-default-not-object' }
            Assert-HarnessRuntimeStrictJsonElement -Element $json.RootElement
        } finally { $json.Dispose() }
        return $text | ConvertFrom-HarnessJson -ErrorAction Stop
    } catch {
        $reason = [string]$_.Exception.Message
        if ($reason.StartsWith('runtime-default-',[StringComparison]::Ordinal)) { throw }
        throw 'runtime-default-invalid-json'
    }
}

function Get-HarnessRuntimeDefaultDecisionDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    $body = [ordered]@{
        schema_version = $Document.schema_version
        new_task_protocol = $Document.new_task_protocol
        scope = $Document.scope
        source_revision = $Document.source_revision
        decision_id = $Document.decision_id
        issued_at_utc = $Document.issued_at_utc
    }
    if ($Document.Contains('expires_at_utc')) { $body.expires_at_utc = $Document.expires_at_utc }
    if ($Document.Contains('workspace_identity_digest')) { $body.workspace_identity_digest = $Document.workspace_identity_digest }
    $body.required_capabilities = @($Document.required_capabilities)
    return Get-HarnessRuntimeSha256Text -Text ($body | ConvertTo-Json -Depth 10 -Compress)
}

function Get-HarnessRuntimeSourceRevision {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $output = @(& git -C $root rev-parse HEAD 2>$null | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or $output[0].Trim() -cnotmatch '^[0-9a-f]{40,64}$') {
        throw 'runtime-default-source-revision-unavailable'
    }
    return $output[0].Trim()
}

function Get-HarnessRuntimeWorkspaceIdentityDigest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return Get-HarnessRuntimeSha256Text -Text (Get-HarnessPhysicalPathIdentity -Path $workspace)
}

function Assert-HarnessRuntimeDefaultDecision {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow
    )

    $required = @('schema_version','new_task_protocol','scope','source_revision','decision_id','issued_at_utc','required_capabilities','decision_digest')
    $allowed = @($required + @('expires_at_utc','workspace_identity_digest'))
    $keys = @($Document.Keys | ForEach-Object { [string]$_ })
    if (@($keys | Where-Object { $_ -cnotin $allowed }).Count -gt 0 -or
        @($required | Where-Object { $keys -cnotcontains $_ }).Count -gt 0) {
        throw 'runtime-default-invalid-document'
    }
    $schemaPath = Join-Path $RepoRoot 'schemas\runtime-default-decision.schema.json'
    if (-not (Test-Json -Json ($Document | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
        throw 'runtime-default-invalid-document'
    }
    if ([string]$Document.decision_digest -cne (Get-HarnessRuntimeDefaultDecisionDigest -Document $Document)) {
        throw 'runtime-default-digest-mismatch'
    }
    $currentRevision = Get-HarnessRuntimeSourceRevision -RepoRoot $RepoRoot
    if ([string]$Document.source_revision -cne $currentRevision) { throw 'runtime-default-source-revision-mismatch' }

    [datetimeoffset]$issuedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Document.issued_at_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$issuedAt)) {
        throw 'runtime-default-issued-at-invalid'
    }
    if ($issuedAt -gt $AsOfUtc.AddSeconds(30)) { throw 'runtime-default-future-issued' }

    if ([string]$Document.scope -ceq 'workspace-canary') {
        if (-not $Document.Contains('expires_at_utc') -or $Document.expires_at_utc -isnot [string] -or
            -not $Document.Contains('workspace_identity_digest') -or $Document.workspace_identity_digest -isnot [string]) {
            throw 'runtime-default-canary-binding-missing'
        }
        [datetimeoffset]$expiresAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$Document.expires_at_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expiresAt) -or
            $expiresAt -le $issuedAt) { throw 'runtime-default-expiry-invalid' }
        if ($expiresAt -le $AsOfUtc) { throw 'runtime-default-expired' }
        if ([string]$Document.workspace_identity_digest -cne (Get-HarnessRuntimeWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot)) {
            throw 'runtime-default-workspace-mismatch'
        }
    } else {
        if (($Document.Contains('expires_at_utc') -and $null -ne $Document.expires_at_utc) -or
            ($Document.Contains('workspace_identity_digest') -and $null -ne $Document.workspace_identity_digest)) {
            throw 'runtime-default-release-binding-invalid'
        }
    }
    return $true
}

function Get-HarnessRuntimeDefaultDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [AllowNull()][System.Collections.IDictionary]$HostCapabilities = $null,
        [datetimeoffset]$AsOfUtc = [datetimeoffset]::UtcNow
    )

    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $script:RuntimeDefaultRelativePath -Label 'runtime default decision' -AllowMissing
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{status='missing';usable=$false;reason='runtime-default-missing';path=$script:RuntimeDefaultRelativePath;decision_digest=$null;new_task_protocol=$null;scope=$null;missing_capabilities=@()}
    }
    try {
        $document = Read-HarnessRuntimeDefaultJson -Path $path
        [void](Assert-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $workspace -Document $document -AsOfUtc $AsOfUtc)
        if ($null -eq $HostCapabilities) { $HostCapabilities = Get-HarnessHostCapabilities -RepoRoot $RepoRoot }
        [void](Assert-HarnessHostCapabilitiesDocument -Document $HostCapabilities)
        $missing = @($document.required_capabilities | Where-Object { $HostCapabilities.capabilities[[string]$_] -ne $true })
        if ($missing.Count -gt 0) {
            return [ordered]@{status='unavailable';usable=$false;reason=('runtime-default-capability-missing-' + ($missing -join ','));path=$script:RuntimeDefaultRelativePath;decision_digest=[string]$document.decision_digest;new_task_protocol=[string]$document.new_task_protocol;scope=[string]$document.scope;missing_capabilities=$missing}
        }
        return [ordered]@{status='valid';usable=$true;reason=('runtime-default-' + [string]$document.new_task_protocol);path=$script:RuntimeDefaultRelativePath;decision_digest=[string]$document.decision_digest;new_task_protocol=[string]$document.new_task_protocol;scope=[string]$document.scope;missing_capabilities=@()}
    } catch {
        $reason = [string]$_.Exception.Message
        if (-not $reason.StartsWith('runtime-default-',[StringComparison]::Ordinal)) { $reason = 'runtime-default-invalid' }
        return [ordered]@{status='invalid';usable=$false;reason=$reason;path=$script:RuntimeDefaultRelativePath;decision_digest=$null;new_task_protocol=$null;scope=$null;missing_capabilities=@()}
    }
}

function New-HarnessRuntimeDefaultDecisionDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidateSet('workspace-canary','release-default')][string]$Scope,
        [ValidateSet('v1','v2')][string]$NewTaskProtocol = 'v2',
        [string]$SourceRevision = '',
        [string]$DecisionId = '',
        [datetimeoffset]$IssuedAtUtc = [datetimeoffset]::UtcNow,
        [Nullable[datetimeoffset]]$ExpiresAtUtc = $null,
        [string[]]$RequiredCapabilities = @('workspace_protocol_config')
    )

    if ([string]::IsNullOrWhiteSpace($SourceRevision)) { $SourceRevision = Get-HarnessRuntimeSourceRevision -RepoRoot $RepoRoot }
    if ([string]::IsNullOrWhiteSpace($DecisionId)) { $DecisionId = 'rtd_' + [guid]::NewGuid().ToString('N') }
    if ($Scope -ceq 'workspace-canary' -and $null -eq $ExpiresAtUtc) { throw 'runtime-default-canary-expiry-required' }
    if ($Scope -ceq 'release-default' -and $null -ne $ExpiresAtUtc) { throw 'runtime-default-release-expiry-forbidden' }
    $document = [ordered]@{
        schema_version = 'harness-runtime-default/v1'
        new_task_protocol = $NewTaskProtocol
        scope = $Scope
        source_revision = $SourceRevision
        decision_id = $DecisionId
        issued_at_utc = $IssuedAtUtc.ToUniversalTime().ToString('o')
        expires_at_utc = $(if ($null -eq $ExpiresAtUtc) { $null } else { ([datetimeoffset]$ExpiresAtUtc).ToUniversalTime().ToString('o') })
        workspace_identity_digest = $(if ($Scope -ceq 'workspace-canary') { Get-HarnessRuntimeWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot } else { $null })
        required_capabilities = @($RequiredCapabilities)
        decision_digest = ''
    }
    $document.decision_digest = Get-HarnessRuntimeDefaultDecisionDigest -Document $document
    [void](Assert-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Document $document -AsOfUtc $IssuedAtUtc)
    return $document
}

Export-ModuleMember -Function Get-HarnessRuntimeDefaultDecision,New-HarnessRuntimeDefaultDecisionDocument,Get-HarnessRuntimeDefaultDecisionDigest,Get-HarnessRuntimeSourceRevision,Get-HarnessRuntimeWorkspaceIdentityDigest,Assert-HarnessRuntimeDefaultDecision
