Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KernelAtomicModule = Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop
$script:PathModule = Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -PassThru -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop
$script:HarnessIntegerTypes = [type[]]@([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64])

function Assert-HarnessKernelCondition {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function ConvertTo-HarnessKernelJson {
    param([Parameter(Mandatory)][AllowNull()][object]$Value,[int]$Depth=50,[switch]$Compress)
    return ($Value | ConvertTo-Json -Depth $Depth -Compress:$Compress) + $(if ($Compress) { '' } else { "`n" })
}

function Test-HarnessKernelValueEqual {
    param([AllowNull()][object]$Left,[AllowNull()][object]$Right)
    return (ConvertTo-HarnessKernelJson -Value $Left -Compress) -ceq (ConvertTo-HarnessKernelJson -Value $Right -Compress)
}

function Test-HarnessKernelFields {
    param([object]$Value,[Collections.IDictionary]$Expected)
    if ($null -eq $Value) { return $false }
    return -not @($Expected.Keys | Where-Object { -not (Test-HarnessKernelValueEqual -Left $(if ($Value -is [Collections.IDictionary]) { $Value[$_] } else { $Value.$_ }) -Right $Expected[$_]) } | Select-Object -First 1).Count
}

function Assert-HarnessKernelTextFields {
    param([object]$Value,[string[]]$Fields,[string]$Label)
    foreach ($blank in @($Fields | Where-Object { [string]::IsNullOrWhiteSpace([string]$(if ($Value -is [Collections.IDictionary]) { $Value[$_] } else { $Value.$_ })) } | Select-Object -First 1)) { throw "$Label $blank must not be blank" }
}

function Select-HarnessKernelKeys {
    param([Collections.IDictionary]$Value,[string[]]$Keys)
    $selected = [ordered]@{}
    foreach ($key in $Keys) { if ($Value.Contains($key)) { $selected[$key] = $Value[$key] } }
    return $selected
}

function Write-HarnessKernelProjection {
    param([object]$Value,[string[]]$Fields)
    foreach ($field in $Fields) {
        $label,$source = $field.Split('=',2)
        $path,$format = $source.Split('|',2)
        $cursor = $Value
        foreach ($segment in $path.Split('.')) { if ($null -ne $cursor) { $cursor = $cursor.$segment } }
        if ($format -ceq 'count') { $cursor = @($cursor).Count }
        elseif ($format -ceq 'bool') { $cursor = ([string][bool]$cursor).ToLowerInvariant() }
        elseif ($format -ceq 'none' -and $null -eq $cursor) { $cursor = 'none' }
        Write-Output ('{0}: {1}' -f $label,$cursor)
    }
}

function New-HarnessAdapterResponse {
    param([string]$Operation,[object]$Value,[string[]]$Keys)
    $body = Select-HarnessKernelKeys -Value $Value -Keys $Keys
    $body.Insert(0,'operation',$Operation)
    foreach ($key in @('allowed','written','dry_run','protected')) { if ($body.Contains($key)) { $body[$key] = [bool]$body[$key] } }
    foreach ($key in @('matched_rules','required_scopes')) { if ($body.Contains($key)) { $body[$key] = @($body[$key]) } }
    return [ordered]@{schema_version='adapter-kernel-api/v1';message_type='response';body=$body}
}

function New-HarnessZeroSideEffects {
    return [ordered]@{task_state_writes=0;runtime_writes=0;
        artifact_writes=0;external_writes=0}
}

function ConvertFrom-HarnessKernelJson {
    param([string]$Json,[string]$Label,[switch]$RequireObject)
    try {
        $value = & $script:PathModule { param($Text,$Name) ConvertFrom-HarnessJsonDocument -Json $Text -Options ([Text.Json.JsonDocumentOptions]::new()) -RejectDuplicateKeys -Label $Name } $Json $Label
        Assert-HarnessKernelCondition (-not $RequireObject -or $value -is [Collections.IDictionary]) "$Label must be a JSON object"
        return $value
    } catch {
        if ([string]$_.Exception.Message -like "$Label *") { throw }
        throw "$Label is not valid JSON: $($_.Exception.Message)"
    }
}

function Read-HarnessKernelUtf8File {
    param([string]$Path,[string]$Label,[int64]$MaximumBytes=0,[switch]$AllowBom)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    Assert-HarnessKernelCondition ($item -is [IO.FileInfo] -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) "$Label is not a regular file"
    if ($MaximumBytes -gt 0 -and $item.Length -gt $MaximumBytes) { throw "$Label is too large" }
    $stream = [IO.FileStream]::new($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),4096,[IO.FileOptions]::SequentialScan)
    try {
        $bytes = [byte[]]::new($item.Length)
        $read = $stream.ReadAtLeast($bytes,$bytes.Length,$false)
        if ($read -ne $bytes.Length) { [Array]::Resize([ref]$bytes,$read) }
    } finally { $stream.Dispose() }
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-HarnessKernelCondition ($AllowBom -or -not $hasBom) "$Label must be UTF-8 without BOM"
    return [pscustomobject]@{Bytes=$bytes;HasBom=$hasBom;Text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes,3*[int]$hasBom,$bytes.Length-3*[int]$hasBom)}
}

function Read-HarnessKernelJson {
    param([string]$Path,[string]$Label,[string]$WorkspaceRoot='',[int64]$MaximumBytes=0,[string]$RepoRoot='',[string]$Schema='',[string]$SchemaLabel='',[int]$Depth=50,[string]$FailureMessage='')
    $fullPath = if(-not[string]::IsNullOrWhiteSpace($WorkspaceRoot)){Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File}else{$Path}
    try { $document = ConvertFrom-HarnessKernelJson -Json (Read-HarnessKernelUtf8File -Path $fullPath -Label $Label -MaximumBytes $MaximumBytes).Text -Label $Label -RequireObject }
    catch {
        if ([string]$_.Exception.Message -like "$Label *") { throw }
        throw "$Label is not valid UTF-8 JSON: $($_.Exception.Message)"
    }
    if ($Schema) { Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $document -Schema $Schema -Label $(if($SchemaLabel){$SchemaLabel}else{$Label}) -Depth $Depth -FailureMessage $FailureMessage }
    if([string]::IsNullOrWhiteSpace($WorkspaceRoot)){return $document}
    return [pscustomobject]@{Document=$document;Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $fullPath)}
}

function Get-HarnessKernelMutexName {
    param([string]$WorkspaceRoot,[string]$WorkspaceIdentity,[string]$Suffix)
    if ([string]::IsNullOrWhiteSpace($WorkspaceIdentity)) { $WorkspaceIdentity = Get-HarnessPhysicalPathIdentity -Path (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) }
    return "Global\dev-harness.v2.$((Get-HarnessSha256Text -Content $WorkspaceIdentity).Substring(7,16)).$Suffix"
}

function Resolve-HarnessRequirementContract {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId,[string]$Path,[string]$Label='Contract')
    $loaded = Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -RepoRoot $RepoRoot -Schema requirement-contract.schema.json -Depth 30
    $contract = $loaded.Document
    Assert-HarnessKernelCondition ($contract.task_id -ceq $TaskId) "$Label task_id does not match TaskId"
    Assert-HarnessKernelCondition (-not @($contract.unresolved_product_decisions).Count) "cannot use a blocked Requirement $Label"
    Assert-HarnessKernelCondition ($contract.digest -ceq (Get-HarnessSha256Text -Content ((Select-HarnessKernelKeys -Value $contract `
        -Keys @('schema_version','task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','product_decisions','unresolved_product_decisions','source_authority')) | ConvertTo-Json -Depth 30 -Compress))) "$Label digest does not match canonical content"
    return [pscustomobject]@{Document=$contract;Path=$loaded.Path;Digest=$contract.digest}
}

function Write-HarnessKernelBytesCas {
    param([string]$WorkspaceRoot,[string]$Path,[byte[]]$Bytes,[string]$SourceDigest,[string]$CurrentDigest)
    return & $script:KernelAtomicModule { param($Root,$Target,$Content,$Source,$Current) Write-HarnessAtomicBytes -WorkspaceRoot $Root -Path $Target -SourceBytes $Content -ExpectedSourceDigest $Source -ExpectedCurrentDigest $Current } $WorkspaceRoot $Path $Bytes $SourceDigest $CurrentDigest
}

function Write-HarnessKernelJsonCas {
    param([string]$WorkspaceRoot,[string]$Path,[Collections.IDictionary]$Value,[string]$CurrentDigest)
    $content = ConvertTo-HarnessKernelJson -Value $Value
    return Write-HarnessKernelBytesCas -WorkspaceRoot $WorkspaceRoot -Path $Path -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($content)) -SourceDigest (Get-HarnessSha256Text -Content $content) -CurrentDigest $CurrentDigest
}

function Enter-HarnessKernelMutex {
    param([string]$Name,[string]$Label,[int]$TimeoutMilliseconds=10000)
    $mutex = [Threading.Mutex]::new($false,$Name)
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "timed out waiting for $Label mutex: $Name" }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-HarnessKernelMutex {
    param([Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { [void]$Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Resolve-HarnessProtectedRuleMatch {
    param([Collections.IDictionary]$Rule,[string]$CommandText,[string[]]$Paths,[string]$Environment,[switch]$RequireTrustedEnvironment)
    if ($Rule.match.Contains('command_regex') -and $CommandText -notmatch [string]$Rule.match.command_regex) { return $null }
    $matchingPaths = @()
    if ($Rule.match.Contains('path_globs')) {
        $matchingPaths = @($Paths | ForEach-Object {
            $normalized = $_.Replace('\','/').TrimStart('/')
            if (@($Rule.match.path_globs | Where-Object { $normalized -match ('^' + [regex]::Escape(([string]$_).Replace('\','/')).Replace('\*\*/','(?:.*/)?').Replace('\*\*','.*').Replace('\*','[^/]*').Replace('\?','[^/]') + '$') }).Count) { $normalized }
        })
        if (-not $matchingPaths.Count) { return $null }
    }
    if ($Rule.match.Contains('environment')) {
        if ([string]::IsNullOrWhiteSpace($Environment)) {
            if ($RequireTrustedEnvironment) { throw "protected write matches rule '$($Rule.id)' but has no trusted Environment binding" }
            return $null
        }
        if ($Environment -cne [string]$Rule.match.environment) { return $null }
    }
    return [pscustomobject]@{Rule=$Rule;Paths=@($matchingPaths)}
}

function Assert-HarnessKernelSchema {
    param([string]$RepoRoot,[object]$Value,[string]$Schema,[string]$Label,[int]$Depth=50,[string]$FailureMessage='')
    if(-not$(try{Test-Json -Json ($Value | ConvertTo-Json -Depth $Depth -Compress) -SchemaFile (Join-Path $RepoRoot "schemas\$Schema") -ErrorAction Stop -WarningAction SilentlyContinue}catch{
        if ($FailureMessage) { throw $FailureMessage }
        throw "$Label schema validation failed: $($_.Exception.Message)"
    })){throw $(if($FailureMessage){$FailureMessage}else{"$Label failed schema validation"})}
}

function Invoke-HarnessKernelProcess {
    param([string]$FilePath,[string]$WorkingDirectory,[string[]]$Arguments,[int]$TimeoutMilliseconds,[switch]$CleanGitEnvironment,[AllowNull()][string]$StandardInput=$null)
    $info = [Diagnostics.ProcessStartInfo]@{
        FileName=$FilePath;WorkingDirectory=$WorkingDirectory
        UseShellExecute=$false;CreateNoWindow=$true
        RedirectStandardOutput=$true;RedirectStandardError=$true
        RedirectStandardInput=$null-ne$StandardInput
        StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)}
    if ($CleanGitEnvironment) {
        foreach ($name in @($info.Environment.Keys)) {
            if ([string]$name -like 'GIT_*') { [void]$info.Environment.Remove([string]$name) }
        }
        $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $info.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        $info.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
        $info.Environment['GIT_CONFIG_GLOBAL'] = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        $info.Environment['GIT_ATTR_NOSYSTEM'] = '1'
    }
    if ($null -ne $info.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $info.ArgumentList.Add([string]$argument) }
    } else {
        $info.Arguments = ($Arguments | ForEach-Object { '"' + (([string]$_ -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1') + '"' }) -join ' '
    }
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        $stdout,$stderr = $process.StandardOutput.ReadToEndAsync(),$process.StandardError.ReadToEndAsync()
        if ($null -ne $StandardInput) {
            $process.StandardInput.BaseStream.Write(($inputBytes=[Text.UTF8Encoding]::new($false).GetBytes($StandardInput)),0,$inputBytes.Length)
            $process.StandardInput.Close()
        }
        if ($process.WaitForExit($TimeoutMilliseconds) -and [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),2000)) {
            return [pscustomobject]@{Complete=$true;ExitCode=$process.ExitCode;
                StdOut=$stdout.GetAwaiter().GetResult().Replace("`r`n","`n");StdErr=$stderr.GetAwaiter().GetResult().Replace("`r`n","`n")}
        }
        try { $process.Kill($true) } catch {}
        try { [void]$process.WaitForExit(2000) } catch {}
    } catch {} finally {
        if ($null -ne $process) { $process.Dispose() }
    }
    return [pscustomobject]@{Complete=$false;ExitCode=-1;
        StdOut='';StdErr=''}
}

function Invoke-HarnessGit {
    param([string]$WorkspaceRoot,[string[]]$Arguments,[string]$GitPath='git',[switch]$DisableFsMonitor,[string]$FailureReason='')
    $result = Invoke-HarnessKernelProcess -FilePath $GitPath -WorkingDirectory $WorkspaceRoot -Arguments (@($(if ($DisableFsMonitor) { '-c','core.fsmonitor=false' })) + @('-C',$WorkspaceRoot) + $Arguments) -TimeoutMilliseconds 60000 -CleanGitEnvironment
    if (-not $result.Complete) { throw $(if ($FailureReason) { $FailureReason } else { 'Git evidence inspection timed out' }) }
    if ($FailureReason -and $result.ExitCode -ne 0) { throw $FailureReason }
    $text = $result.StdOut.TrimEnd("`n")
    return [pscustomobject]@{ExitCode=$result.ExitCode;Text=$text;Lines=$(if ($text.Length) { @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) } else { @() })}
}

function Assert-HarnessHostCapabilitiesDocument {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    Assert-HarnessKernelSchema -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -Value $Document -Schema host-capabilities.schema.json -Label 'host capabilities' -FailureMessage host-capabilities-invalid-document
    return $true
}

function Get-HarnessHostCapabilities {
    param([Parameter(Mandatory)][string]$RepoRoot,[string[]]$RequiredCapabilities=@(),[switch]$ProbeHostDetails)
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $capabilities = [ordered]@{workspace_protocol_config=(Test-Path (Join-Path $root 'schemas\protocol-config.schema.json') -PathType Leaf) -and (Test-Path (Join-Path $root 'scripts\lib\Harness.Protocol.psm1') -PathType Leaf)
        structured_tool_events='unavailable';request_send_telemetry='unavailable';
            desktop_profile_isolation='unavailable';hook_status_query='unavailable'}
    foreach ($unknown in @($RequiredCapabilities | Where-Object { [string]$_ -cnotin @($capabilities.Keys) } | Select-Object -First 1)) { throw "host-capabilities-unknown-required-capability-$unknown" }
    Assert-HarnessKernelCondition ([Collections.Generic.HashSet[string]]::new([string[]]$RequiredCapabilities,[StringComparer]::Ordinal).Count -eq $RequiredCapabilities.Count) 'host-capabilities-duplicate-required-capability'
    $actualVersion = 'unknown'
    if ($ProbeHostDetails) {
        try {
            $command = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
            Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) unavailable
            $result = Invoke-HarnessKernelProcess -FilePath (Get-Process -Id $PID).Path -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMilliseconds 5000 -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-Command',("& '" + ([string]$command.Path).Replace("'","''") + "' --version"))
            Assert-HarnessKernelCondition ($result.Complete -and $result.ExitCode -eq 0 -and -not $result.StdErr.Length -and $result.StdOut.Length -le 65536) unavailable
            $actualVersion = [string]([regex]::Match($result.StdOut,'\Acodex-cli (?<version>\S+)(?:\n)?\z',[Text.RegularExpressions.RegexOptions]::CultureInvariant).Groups['version'].Value)
            if ([string]::IsNullOrWhiteSpace($actualVersion)) { $actualVersion = 'unknown' }
        } catch {}
    }
    $document = [ordered]@{schema_version='harness-host-capabilities/v1';product='codex';actual_version=$actualVersion
        observation_status=$(if(-not@($RequiredCapabilities|Where-Object{$capabilities[$_]-isnot[bool]}).Count){'observed'}elseif(@($RequiredCapabilities|Where-Object{$capabilities[$_]-is[bool]}).Count){'partial'}else{'unavailable'});capabilities=$capabilities}
    [void](Assert-HarnessHostCapabilitiesDocument -Document $document)
    return $document
}

function ConvertTo-HarnessProtectedOperationArray {
    param([string[]]$Values,[ValidateSet('target','scope')][string]$Kind)
    $normalized = @($Values | ForEach-Object { ([string]$_).Trim().Replace('\','/') })
    if (-not $normalized.Count -or @($normalized | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw "protected operation $Kind values must not be empty or blank" }
    if (@($normalized | Sort-Object -Unique).Count -ne $normalized.Count) { throw "protected operation $Kind values must be unique" }
    if ($Kind -ceq 'target' -and @($normalized | Where-Object { [IO.Path]::IsPathRooted($_) -or $_.Contains(':') -or @($_ -split '/' | Where-Object { $_ -ceq '..' }).Count }).Count) { throw 'protected operation target is invalid' }
    if ($Kind -ceq 'scope' -and @($normalized | Where-Object { $_ -cnotmatch '^(?:rule:[a-z0-9][a-z0-9-]{0,63}|command_digest:sha256:[0-9a-f]{64}|environment:[a-z0-9][a-z0-9._-]{0,63}|path:.+|dry-run:true)$' }).Count) { throw 'protected operation Approval scope is invalid' }
    return @($normalized | Sort-Object)
}

function New-HarnessProtectedOperation {
    param([Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][string]$Environment,[Parameter(Mandatory)][ValidateSet('protected-write')][string]$ActionCategory,[Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][ValidateSet('none','product','architecture','production')][string]$ApprovalType,
        [Parameter(Mandatory)][string[]]$ApprovalScope)
    if ($TaskVersion -lt 1) { throw 'protected operation task_version is invalid' }
    Assert-HarnessKernelCondition ($ContractDigest -cmatch '^sha256:[0-9a-f]{64}$') 'protected operation Contract digest is invalid'
    $environment = $Environment.Trim().ToLowerInvariant()
    Assert-HarnessKernelCondition ($environment -cmatch '^[a-z0-9][a-z0-9._-]{0,63}$') 'protected operation environment is invalid'
    $operation = [ordered]@{schema_version='protected-operation/v1';environment=$environment;action_category=$ActionCategory
        targets=@(ConvertTo-HarnessProtectedOperationArray -Values $Targets -Kind target);approval_type=$ApprovalType
        approval_scope=@(ConvertTo-HarnessProtectedOperationArray -Values $ApprovalScope -Kind scope);identity=''}
    $identityInput = [ordered]@{task_version=$TaskVersion;contract_digest=$ContractDigest}
    foreach ($key in @('environment','action_category','targets','approval_type','approval_scope')) { $identityInput[$key] = $operation[$key] }
    $operation.identity = Get-HarnessSha256Text -Content ("dev-harness:protected-operation:v1`n" + ($identityInput | ConvertTo-Json -Depth 20 -Compress))
    return $operation
}

function Resolve-HarnessProtectedOperation {
    param([Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest, [Parameter(Mandatory)][System.Collections.IDictionary]$Operation,[string]$Label='protected operation')
    Assert-HarnessKernelCondition (-not @($Operation.Keys | Where-Object { @('schema_version','environment','action_category','targets','approval_type','approval_scope','identity') -cnotcontains $_ }).Count -and $Operation.Count -eq 7) "$Label keys are invalid"
    Assert-HarnessKernelCondition ($Operation.schema_version -ceq 'protected-operation/v1') "$Label schema_version is invalid"
    $resolved = New-HarnessProtectedOperation -TaskVersion $TaskVersion -ContractDigest $ContractDigest -Environment $Operation.environment -ActionCategory $Operation.action_category -Targets @($Operation.targets) -ApprovalType $Operation.approval_type -ApprovalScope @($Operation.approval_scope)
    Assert-HarnessKernelCondition (Test-HarnessKernelValueEqual -Left $Operation -Right $resolved) "$Label is not canonical or its identity is invalid"
    return $resolved
}

function Test-HarnessApprovalExpiry {
    param([Collections.IDictionary]$Approval,[datetimeoffset]$AsOf=[datetimeoffset]::UtcNow)
    try { $approvedAt = [datetimeoffset]::Parse([string]$Approval.approved_at,[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw 'Approval approved_at is invalid' }
    if ($approvedAt -gt $AsOf) { throw 'Approval approved_at is in the future' }
    if ($null -eq $Approval.expires_at) { return $false }
    try { $expiresAt = [datetimeoffset]::Parse([string]$Approval.expires_at,[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw 'Approval expires_at is invalid' }
    if ($expiresAt -le $approvedAt) { throw 'Approval expires_at must be later than approved_at' }
    return $expiresAt -le $AsOf
}

function Resolve-HarnessApprovalInputCore {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ApprovalPath,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$TargetTaskVersion,
        [Parameter(Mandatory)][string]$ContractDigest,[datetimeoffset]$AsOf=[datetimeoffset]::UtcNow)
    $loaded = Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $ApprovalPath -Label 'Approval input'
    $approval = $loaded.Document
    Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace([string]$approval.approver)) 'Approval approver must not be blank'
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $approval -Schema approval.schema.json -Label 'Approval input' -Depth 30
    Assert-HarnessKernelCondition (Test-HarnessKernelFields $approval @{task_id=$TaskId;task_version=$TargetTaskVersion;contract_digest=$ContractDigest}) 'Approval task, version, or Contract binding is stale'
    Assert-HarnessKernelCondition ($approval.status -ceq 'granted') 'only a granted Approval can be imported'
    Assert-HarnessKernelCondition (-not (Test-HarnessApprovalExpiry -Approval $approval -AsOf $AsOf)) 'Approval is expired'
    if ($approval.Contains('protected_operation')) {
        $operation = Resolve-HarnessProtectedOperation -TaskVersion $approval.task_version -ContractDigest $approval.contract_digest -Operation $approval.protected_operation -Label 'Approval protected_operation'
        Assert-HarnessKernelCondition ($approval.approval_type -ceq $operation.approval_type -and -not @($operation.approval_scope | Where-Object { @($approval.approved_scope) -cnotcontains $_ }).Count) 'Approval protected_operation type or scope is inconsistent'
    }
    $content = ConvertTo-HarnessKernelJson -Value $approval -Depth 30
    return [pscustomobject]@{Document=$approval;InputPath=$loaded.Path;OutputPath=".assistant/runtime/tasks/$TaskId/approvals/$($approval.approval_id).json"
        Content=$content;Digest=(Get-HarnessSha256Text -Content $content)}
}

function Resolve-HarnessApprovalInput {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ApprovalPath, [Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$TargetTaskVersion,[Parameter(Mandatory)][string]$ContractDigest)
    return Resolve-HarnessApprovalInputCore @PSBoundParameters
}

function Assert-HarnessTaskApprovalCore {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Task,[string]$RequiredType='',[string[]]$RequiredScopes=@(),
        [AllowNull()][System.Collections.IDictionary]$RequiredOperation=$null,[datetimeoffset]$AsOf=[datetimeoffset]::UtcNow)
    if ($null -ne $RequiredOperation) {
        $RequiredOperation = Resolve-HarnessProtectedOperation -TaskVersion $Task.version -ContractDigest $Task.contract_digest -Operation $RequiredOperation -Label 'required protected_operation'
        Assert-HarnessKernelCondition (-not $RequiredType -or $RequiredType -ceq $RequiredOperation.approval_type) 'required Approval type conflicts with protected_operation'
        $RequiredType = $RequiredOperation.approval_type
        $RequiredScopes = @($RequiredOperation.approval_scope)
    }
    foreach ($approvalId in @($Task.approvals)) {
        $loaded = Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path ".assistant/runtime/tasks/$($Task.task_id)/approvals/$approvalId.json" -Label 'task Approval' -RepoRoot $RepoRoot -Schema approval.schema.json -Depth 30
        $approval = $loaded.Document
        Assert-HarnessKernelCondition ($approval.approval_id -ceq $approvalId -and $approval.task_id -ceq $Task.task_id) 'task Approval identity is invalid'
        if (-not ($approval.status -ceq 'granted' -and -not (Test-HarnessApprovalExpiry -Approval $approval -AsOf $AsOf) -and
            [int]$approval.task_version -eq [int]$Task.version -and $approval.contract_digest -ceq $Task.contract_digest -and
            (-not $RequiredType -or $approval.approval_type -ceq $RequiredType) -and
            -not @($RequiredScopes | Where-Object { @($approval.approved_scope) -cnotcontains $_ }).Count)) { continue }
        $operation = if ($approval.Contains('protected_operation')) { Resolve-HarnessProtectedOperation -TaskVersion $approval.task_version -ContractDigest $approval.contract_digest -Operation $approval.protected_operation -Label 'task Approval protected_operation' } else { $null }
        if ($null -ne $RequiredOperation -and ($null -eq $operation -or $operation.identity -cne $RequiredOperation.identity)) {
            continue
        }
        return [pscustomobject]@{Path=$loaded.Path;Document=$approval;
            Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $loaded.Path);ProtectedOperation=$operation}
    }
    throw ("no current granted Approval covers the required task version, Contract, type, and scope; required_type={0}; required_scopes={1}" -f $RequiredType,($RequiredScopes -join ','))
}

function Assert-HarnessTaskApproval {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task, [string]$RequiredType='',[string[]]$RequiredScopes=@(), [AllowNull()][System.Collections.IDictionary]$RequiredOperation=$null)
    return Assert-HarnessTaskApprovalCore @PSBoundParameters
}

function Test-HarnessEvidenceExcludedPath {
    param([string]$Path,[string[]]$ExactPaths)
    $comparison=if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    return $Path.Equals('.assistant/runtime',$comparison)-or$Path.StartsWith('.assistant/runtime/',$comparison)-or$Path.Equals('.qoder',$comparison)-or$Path.StartsWith('.qoder/',$comparison)-or `
        @($ExactPaths|Where-Object{$Path.Equals([string]$_,$comparison)}|Select-Object -First 1).Count-gt0
}

function Get-HarnessEvidenceRevision {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ContractDigest, [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,[Parameter(Mandatory)][string]$EvidenceInputPath, [Parameter(Mandatory)][string]$EvidenceOutputPath)
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $inputRelative = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $EvidenceInputPath -Label 'Evidence' -MustExist File)
    $runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $exactExclusions=[Collections.Generic.HashSet[string]]::new([string[]]@($inputRelative,
        (Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $EvidenceOutputPath -Label 'evidence output' -AllowMissing))),
        $(if($runningOnWindows){[StringComparer]::OrdinalIgnoreCase}else{[StringComparer]::Ordinal}))
    if($Evidence.Contains('task_id')){[void]$exactExclusions.Add("docs/tasks/$($Evidence.task_id)/audit.md")}
    $evidenceFiles=@((@($Evidence.records)+$(if($Evidence.Contains('dry_run')){@($Evidence.dry_run)}else{@()}))|ForEach-Object{
        $relative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $_.evidence_path -Label 'record evidence_path' -MustExist File)
        [ordered]@{path=$relative;digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $relative)}
    })
    $git=@{GitPath=[IO.Path]::GetFullPath([string]@(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source)
        WorkspaceRoot=(Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot)
        DisableFsMonitor=$true}
    $gitRoot=Invoke-HarnessGit @git -Arguments @('rev-parse','--show-toplevel')
    $head,$workingDiff,$stagedDiff,$untracked='','','',[Collections.Generic.List[object]]::new()
    $resolvedGitRoot=$(if($gitRoot.ExitCode-eq0){try{(Resolve-Path -LiteralPath $gitRoot.Text).Path}catch{$null}}else{$null})
    if($null-ne$resolvedGitRoot-and$(if($runningOnWindows){$resolvedGitRoot.Equals($git.WorkspaceRoot,[StringComparison]::OrdinalIgnoreCase)-or `
        (Get-HarnessPhysicalPathIdentity -Path $resolvedGitRoot)-ceq(Get-HarnessPhysicalPathIdentity -Path $git.WorkspaceRoot)}else{$resolvedGitRoot-ceq$git.WorkspaceRoot})){
        $trackedInput=Invoke-HarnessGit @git -Arguments @('ls-files','--error-unmatch','--',$inputRelative)
        if($trackedInput.ExitCode-eq0){[void]$exactExclusions.Remove($inputRelative)}elseif($trackedInput.ExitCode-ne1){throw 'unable to classify Evidence input path in Git'}
        $headRun=Invoke-HarnessGit @git -Arguments @('rev-parse','HEAD')
        if($headRun.ExitCode-eq0){$head=$headRun.Text.Trim()}
        if(@((Invoke-HarnessGit @git -Arguments @('ls-files','-v','--','.') -FailureReason 'unable to inspect Git index flags for Evidence revision').Lines |
            Where-Object{[string]::IsNullOrEmpty([string]$_)-or-not([string]$_).StartsWith('H ',[StringComparison]::Ordinal)}).Count){throw 'Evidence workspace has unsafe Git index flags'}
        $effectiveFilters=Invoke-HarnessGit @git -Arguments @('config','--includes','--get-regexp','^filter\.')
        if($effectiveFilters.ExitCode-eq0){throw 'Evidence workspace has unsupported Git clean filters'}
        if($effectiveFilters.ExitCode-ne1){throw 'unable to inspect Git clean filters for Evidence revision'}
        $pathspec=[Collections.Generic.List[string]]@('.',$(if($runningOnWindows){':(icase,glob,exclude).assistant/runtime/**'}else{':(glob,exclude).assistant/runtime/**'}))
        foreach($excluded in @($exactExclusions|Sort-Object)){$pathspec.Add($(if($runningOnWindows){":(icase,literal,exclude)$excluded"}else{":(literal,exclude)$excluded"}))}
        $workingDiff=(Invoke-HarnessGit @git -Arguments (@('diff','--ignore-submodules=none','--no-ext-diff','--no-textconv','--binary','--')+@($pathspec)) -FailureReason 'unable to compute working diff for Evidence revision').Text
        $stagedDiff=(Invoke-HarnessGit @git -Arguments (@('diff','--cached','--ignore-submodules=none','--no-ext-diff','--no-textconv','--binary','--')+@($pathspec)) -FailureReason 'unable to compute staged diff for Evidence revision').Text
        $qoderPathspec=@(":(top,$(if($runningOnWindows){'icase,'})literal,exclude).qoder",":(top,$(if($runningOnWindows){'icase,'})glob,exclude).qoder/**")
        foreach($path in @((Invoke-HarnessGit @git -Arguments (@('ls-files','--others','--exclude-standard','--','.')+$qoderPathspec) -FailureReason 'unable to enumerate untracked files for Evidence revision').Lines|ForEach-Object{$_.Replace('\','/')}|Sort-Object)){
            if(Test-HarnessEvidenceExcludedPath -Path $path -ExactPaths @($exactExclusions)){continue}
            $untracked.Add([ordered]@{path=$path;digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path)})
        }
        if(-not$workingDiff-and-not$stagedDiff-and-not$untracked.Count){return $head}
    }else{
        foreach($file in Get-ChildItem -LiteralPath $WorkspaceRoot -Force|Where-Object{-not(Test-HarnessEvidenceExcludedPath -Path $_.Name -ExactPaths @())}|ForEach-Object{if($_.PSIsContainer){Get-ChildItem -LiteralPath $_.FullName -File -Force -Recurse}else{$_}}|Sort-Object FullName){
            $relative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $file.FullName
            if(Test-HarnessEvidenceExcludedPath -Path $relative -ExactPaths @($exactExclusions)){continue}
            $untracked.Add([ordered]@{path=$relative;digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $file.FullName)})
        }
    }
    return 'dirty:'+(Get-HarnessSha256Text -Content (([ordered]@{workspace_identity=$(if($runningOnWindows){Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot}else{Get-HarnessSha256Text -Content $WorkspaceRoot});head=$head;contract_digest=$ContractDigest
        working_diff=(Get-HarnessSha256Text -Content $workingDiff);staged_diff=(Get-HarnessSha256Text -Content $stagedDiff)
        untracked=@($untracked);evidence_files=@($evidenceFiles|Sort-Object path)})|ConvertTo-Json -Depth 30 -Compress)).Substring(7)
}

function Resolve-HarnessEvidenceCore {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][int]$RequiredAcceptanceCount,[Parameter(Mandatory)][string]$EvidencePath,
        [AllowEmptyString()][string]$PinnedRevision='')
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $loaded=Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $EvidencePath -Label 'Evidence'
    $document=$loaded.Document
    $dryRun=if($document.Contains('dry_run')){$document.dry_run}else{$null}
    foreach($record in @($document.records)+@($dryRun)){
        if($record-isnot[Collections.IDictionary]){continue}
        $label=if([object]::ReferenceEquals($record,$dryRun)){'dry-run'}else{'record'}
        if($record.Contains('actor')-and$record.actor-is[Collections.IDictionary]){Assert-HarnessKernelTextFields -Value $record.actor -Fields @($record.actor.Keys) -Label "$label actor"}
        if($record.Contains('command')){Assert-HarnessKernelTextFields -Value $record -Fields command -Label $label}
    }
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $document -Schema evidence.schema.json -Label 'Evidence'
    if($document.task_id-cne$TaskId){throw 'Evidence task_id does not match TaskId'}
    if([int]$document.task_version-ne$TaskVersion){throw "Evidence task_version is stale: expected=$TaskVersion actual=$($document.task_version)"}
    if($document.contract_digest-cne$ContractDigest){throw 'Evidence contract_digest is stale'}
    $protectedOperation=if($document.Contains('protected_operation')){Resolve-HarnessProtectedOperation -TaskVersion $TaskVersion -ContractDigest $ContractDigest -Operation $document.protected_operation -Label 'Evidence protected_operation'}else{$null}
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "docs/tasks/$TaskId/evidence.json" -Label 'evidence output' -AllowMissing)
    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $severity = 0
    if($null-ne$dryRun-and$null-ne$protectedOperation-and-not@($dryRun.covers).Count){throw 'dry-run covers must not be empty for protected_operation'}
    foreach($record in @($document.records)+@($dryRun)){
        if($null-eq$record){continue}
        $isDryRun=[object]::ReferenceEquals($record,$dryRun)
        $label=if($isDryRun){'dry-run'}else{'record'}
        if($record.Contains('operation_identity')){
            if($null-eq$protectedOperation){throw "$(if($isDryRun){'dry-run'}else{'Evidence record'}) operation_identity requires protected_operation"}
            if($record.operation_identity-cne$protectedOperation.identity){throw "$(if($isDryRun){'dry-run'}else{'Evidence record'}) operation_identity does not match protected_operation"}
            if($isDryRun-and@($record.covers)-cnotcontains$record.operation_identity){throw 'dry-run covers does not include protected_operation identity'}
        }
        if((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $record.evidence_path `
            -Label "$label evidence_path" -MustExist File))-cne$record.digest){throw "$(if($isDryRun){'dry-run Evidence'}else{'Evidence record'}) digest mismatch: $($record.evidence_path)"}
        if($record.Contains('cwd')){
            [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $record.cwd -Label "$label cwd" -MustExist Directory)
            if([int]$record.exit_code-ne0){$severity=3}
        }else{$severity=[Math]::Max($severity,@('pass','partial','blocked','fail').IndexOf([string]$record.result))}
        if(-not$isDryRun){foreach($item in @($record.covers)){[void]$covered.Add($item)}}
    }
    $coverage=@($document.coverage.satisfied)+@($document.coverage.not_verified)+@($document.coverage.blocked)
    $buckets=[Collections.Generic.HashSet[string]]::new([string[]]$coverage,[StringComparer]::Ordinal)
    if($buckets.Count-ne$coverage.Count){throw 'Evidence coverage overlaps'}
    foreach($item in @($document.coverage.satisfied)){if(-not$covered.Contains($item)){throw "Evidence satisfied coverage has no record: $item"}}
    for($index=1;$index-le$RequiredAcceptanceCount;$index++){if(-not$buckets.Contains("AC-$index")){$severity=[Math]::Max($severity,1)}}
    $severity=[Math]::Max($severity,$(if(@($document.coverage.blocked).Count-or@($document.gaps|Where-Object status -cne 'not-verified').Count){2}elseif(@($document.coverage.not_verified).Count-or@($document.gaps).Count){1}else{0}))
    $derived=@('pass','partial','blocked','fail')[$severity]
    if($document.conclusion-cne$derived){throw "Evidence conclusion does not match records and coverage: declared=$($document.conclusion) derived=$derived"}
    $expectedRevision=if([string]::IsNullOrWhiteSpace($PinnedRevision)){Get-HarnessEvidenceRevision -WorkspaceRoot $WorkspaceRoot -ContractDigest $ContractDigest -Evidence $document -EvidenceInputPath $loaded.Path -EvidenceOutputPath "docs/tasks/$TaskId/evidence.json"}else{$PinnedRevision}
    if($document.revision-cne$expectedRevision){
        if($PinnedRevision){throw 'Evidence revision no longer matches its transaction snapshot'}
        if($expectedRevision.StartsWith('dirty:',[StringComparison]::Ordinal)){throw 'Evidence dirty revision is stale'}
        throw 'Evidence commit revision is stale'
    }
    $content=ConvertTo-HarnessKernelJson -Value $document
    return [pscustomobject]@{Document=$document;InputPath=$loaded.Path;
        OutputPath="docs/tasks/$TaskId/evidence.json";Content=$content;
        Digest=(Get-HarnessSha256Text -Content $content);Conclusion=$derived;
        NextStatus=$(switch($derived){'pass'{'done'}'fail'{'running'}'blocked'{'paused'}default{'verifying'}});ExpectedRevision=$expectedRevision;
        ProtectedOperation=$protectedOperation}
}

function Resolve-HarnessEvidence {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][int]$RequiredAcceptanceCount,[Parameter(Mandatory)][string]$EvidencePath)
    return Resolve-HarnessEvidenceCore @PSBoundParameters
}
