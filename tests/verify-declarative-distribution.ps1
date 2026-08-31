[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=Split-Path -Parent $PSScriptRoot }
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.Distribution.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.CanonicalJson.psm1')

$script:Checks=0
$script:Failures=[Collections.Generic.List[string]]::new()
$utf8=[Text.UTF8Encoding]::new($false,$true)
$scratch=Join-Path $RepoRoot ('tmp/verify-distribution-'+[guid]::NewGuid().ToString('N'))
$fixtureRepo=Join-Path $scratch 'repo'
$fixtureUser=Join-Path $scratch 'user'
$fixtureWorkspace=Join-Path $scratch 'workspace'

function Check([bool]$Condition,[string]$Message) {
    if ($Condition) { $script:Checks++; Write-Output "[PASS] $Message" }
    else { $script:Failures.Add($Message); Write-Output "[FAIL] $Message" }
}
function Add-Failure([string]$Message) { $script:Failures.Add($Message) }
function Read-Json([string]$Path) { return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
function Write-Json([string]$Path,[System.Collections.IDictionary]$Document) {
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Document -Depth 100),$utf8)
}
function Expect-Rejection([scriptblock]$Action,[string]$Message,[string]$Pattern='') {
    try { & $Action | Out-Null; Check $false "$Message (accepted)" }
    catch { Check ([string]::IsNullOrWhiteSpace($Pattern) -or $_.Exception.Message -match $Pattern) $Message }
}
function Change-Profile([scriptblock]$Mutation,[scriptblock]$Action,[string]$Preset='core') {
    $path=Join-Path $fixtureRepo "modules/distribution/profiles/$Preset.json"
    $before=[IO.File]::ReadAllBytes($path)
    try { $document=Read-Json $path; & $Mutation $document; Write-Json $path $document; & $Action }
    finally { [IO.File]::WriteAllBytes($path,$before) }
}
function Change-Manifest([string]$Id,[scriptblock]$Mutation,[scriptblock]$Action) {
    $path=Join-Path $fixtureRepo "modules/$Id/module.manifest.json"
    $catalogPath=Join-Path $fixtureRepo 'module-manifest-catalog.json'
    $before=[IO.File]::ReadAllBytes($path)
    $catalogBefore=[IO.File]::ReadAllBytes($catalogPath)
    try {
        $document=Read-Json $path; & $Mutation $document; Write-Json $path $document
        $catalog=Read-Json $catalogPath
        foreach ($record in @($catalog.source_manifests)) {
            if ($record.module_id -ceq $Id) { $record.digest=Get-HarnessCanonicalJsonSha256 -JsonBytes ([IO.File]::ReadAllBytes($path)) }
        }
        Write-Json $catalogPath $catalog
        & $Action
    } finally { [IO.File]::WriteAllBytes($path,$before); [IO.File]::WriteAllBytes($catalogPath,$catalogBefore) }
}
function Get-Plan([string]$Preset='core') { return Get-HarnessDistributionPlan -RepoRoot $fixtureRepo -Preset $Preset }
function Get-Snapshot([string]$Root,[switch]$IgnoreHostStartupCache) {
    $result=[Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Root)) { return 'missing' }
    $directories=[Collections.Generic.Stack[string]]::new(); $directories.Push($Root)
    while ($directories.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $directories.Pop() -Force) {
            $relative=[IO.Path]::GetRelativePath($Root,$entry.FullName).Replace('\','/')
            if ($IgnoreHostStartupCache -and $relative -ceq 'AppData/Local/Microsoft/PowerShell/StartupProfileData-NonInteractive') { continue }
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $result.Add("link:$relative=$($entry.Target)") }
            elseif ($entry.PSIsContainer) {
                # PowerShell itself creates this one JIT startup cache and parents.
                # Still descend and bind every other file in those directories.
                if (-not $IgnoreHostStartupCache -or $relative -cnotin @('AppData','AppData/Local','AppData/Local/Microsoft','AppData/Local/Microsoft/PowerShell')) { $result.Add("directory:$relative") }
                $directories.Push($entry.FullName)
            }
            else { $result.Add("file:$relative=$((Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash)") }
        }
    }
    $result.Sort([StringComparer]::Ordinal)
    return $result -join "`n"
}
function Run-Install([string[]]$Extra=@()) {
    $child=Start-RepoProcess -UserProfile $fixtureUser -ScriptPath (Join-Path $fixtureRepo 'install.ps1') -Arguments (@('-RepoRoot',$fixtureRepo,'-WorkspaceRoot',$fixtureWorkspace)+$Extra)
    try {
        if (-not $child.Process.WaitForExit(120000)) { $child.Process.Kill($true); throw 'Distribution install fixture timed out' }
        return [pscustomobject]@{ExitCode=$child.Process.ExitCode;Output=($child.StdOut.GetAwaiter().GetResult()+$child.StdErr.GetAwaiter().GetResult())}
    } finally { $child.Process.Dispose() }
}
function Assert-ZeroWriteInstall([string]$Message,[string[]]$Extra=@('-Preset','core')) {
    $beforeUser=Get-Snapshot $fixtureUser -IgnoreHostStartupCache; $beforeWorkspace=Get-Snapshot $fixtureWorkspace
    $result=Run-Install $Extra
    $afterUser=Get-Snapshot $fixtureUser -IgnoreHostStartupCache; $afterWorkspace=Get-Snapshot $fixtureWorkspace
    $valid=$result.ExitCode -ne 0 -and $result.Output -match 'Distribution|Profile|allowlist' -and $beforeUser -ceq $afterUser -and $beforeWorkspace -ceq $afterWorkspace
    Check $valid $Message
    if (-not $valid) { Write-Output "[DETAIL] exit=$($result.ExitCode); user-before=[$beforeUser]; user-after=[$afterUser]; workspace-before=[$beforeWorkspace]; workspace-after=[$afterWorkspace]" }
}

try {
    New-Item -ItemType Directory -Path $fixtureRepo,$fixtureUser,$fixtureWorkspace -Force | Out-Null
    $files=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in @('install.ps1','uninstall.ps1','scripts/install-transaction-common.ps1','scripts/lib/Harness.Hashing.psm1','scripts/lib/Harness.Path.psm1','scripts/lib/Harness.CanonicalJson.psm1','scripts/lib/Harness.Distribution.psm1','scripts/get-distribution-plan.ps1','module-manifest-catalog.json','schemas/module-manifest-catalog-v1.schema.json','schemas/module-manifest.schema.json','schemas/module-manifest-v1.schema.json','schemas/install-profile.schema.json','schemas/distribution-plan.schema.json')) { [void]$files.Add($file) }
    foreach ($module in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'modules') -Directory) { [void]$files.Add("modules/$($module.Name)/module.manifest.json") }
    foreach ($preset in @('core','governed','full')) {
        $profilePath="modules/distribution/profiles/$preset.json"
        [void]$files.Add($profilePath)
        foreach ($asset in @( (Read-Json (Join-Path $RepoRoot $profilePath)).asset_allowlist )) {
            foreach ($file in @($asset.files)) { [void]$files.Add([string]$file) }
        }
    }
    foreach ($file in $files) { Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRepo -RelativePath $file }

    $expectedSkills=@{
        core=@('.system','entry-router','orchestrator','plan','implement','review','test','spec')
        governed=@('.system','entry-router','orchestrator','plan','implement','review','test','spec','planning','audit')
        full=@('.system','audit','codex','entry-router','implement','md-html','obsidian-memory','orchestrator','plan','planning','review','spec','test','workflow-team')
    }
    foreach ($preset in @('core','governed','full')) {
        $plan=Get-Plan $preset
        $repeat=Get-Plan $preset
        Assert-HarnessDistributionPlanCurrent -RepoRoot $fixtureRepo -Plan $plan
        Check ((ConvertTo-HarnessDistributionJson $plan) -ceq (ConvertTo-HarnessDistributionJson $repeat)) "$preset plan is deterministic and revalidates without Git or Runtime"
        $skills=@('.system')+@($plan.assets | Where-Object kind -CEQ 'skill' | ForEach-Object target)
        Check (($skills -join '|') -ceq ($expectedSkills[$preset] -join '|')) "$preset preserves legacy skill order and selection"
        $hooks=@($plan.assets | Where-Object kind -CEQ 'hook' | ForEach-Object target)
        $expectedHooks=@('pretooluse.ps1','codex-pretooluse-launcher.ps1')+$(if($preset -ceq 'full'){@('userpromptsubmit.js')}else{@()})+@('stop.js','workspace-resolver.js')
        Check (($hooks -join '|') -ceq ($expectedHooks -join '|')) "$preset preserves legacy hook selection"
        Check (@($plan.assets | Where-Object kind -CEQ 'vault').Count -eq $(if($preset -ceq 'full'){29}else{5})) "$preset preserves the legacy vault file set"
        $unsigned=[ordered]@{}; foreach($key in $plan.Keys){if($key -cne 'digest'){$unsigned[$key]=$plan[$key]}}
        $referenceDigest=Get-HarnessCanonicalJsonSha256 -JsonBytes $utf8.GetBytes((ConvertTo-Json -InputObject $unsigned -Depth 100 -Compress))
        Check ($plan.digest_algorithm -ceq 'canonical-json/v1' -and $plan.digest -ceq $referenceDigest) "$preset uses the independently verified canonical digest contract"
    }
    $full=Get-Plan full
    Check (@($full.authorized_module_assets).Count -eq 4 -and @($full.authorized_module_assets | Where-Object path -CEQ 'docs/team-write-authority.md').Count -eq 0) 'Manifest requests without Profile grants do not enter the plan'
    $snapshot=Get-Snapshot $fixtureRepo
    [void](Get-Plan)
    Check ($snapshot -ceq (Get-Snapshot $fixtureRepo)) 'planning performs zero filesystem writes'

    $profileCases=@(
        @{Name='unknown Profile field';Change={param($p) $p['activation']=$true}},
        @{Name='unsupported Profile version';Change={param($p) $p.schema_version='install-profile/v2'}},
        @{Name='historical algorithm is not silently canonicalized';Change={param($p) $p.digest_algorithm='legacy-json/v1'}},
        @{Name='wrong preset identity';Change={param($p) $p.profile_id='full'}},
        @{Name='preset vault compatibility';Change={param($p) $p.vault_profile='full'}},
        @{Name='unknown enabled module';Change={param($p) $p.enabled_modules[0].module_id='unknown-module'}},
        @{Name='duplicate enabled module';Change={param($p) $p.enabled_modules+=@($p.enabled_modules[0])}},
        @{Name='disabled transitive dependency';Change={param($p) $p.enabled_modules=@($p.enabled_modules | Where-Object module_id -CNE 'task-governance')}},
        @{Name='ungranted capability';Change={param($p) $p.enabled_modules[0].allowed_capabilities=@()}},
        @{Name='duplicate asset';Change={param($p) $p.asset_allowlist+=@($p.asset_allowlist[0])}},
        @{Name='case-colliding target';Change={param($p) $p.asset_allowlist[1].target='ENTRY-ROUTER'}},
        @{Name='source escape';Change={param($p) $p.asset_allowlist[0].source='../outside.md'}},
        @{Name='absolute target';Change={param($p) $p.asset_allowlist[0].target=[IO.Path]::GetPathRoot($fixtureRepo).Replace('\','/')+'outside'}},
        @{Name='source wildcard';Change={param($p) $p.asset_allowlist[0].files=@('skills/entry-router/**')}},
        @{Name='support file escape';Change={param($p) $p.asset_allowlist[0].files+=@('scripts/task.ps1')}},
        @{Name='unknown asset module';Change={param($p) $p.asset_allowlist[0].module_id='unknown-module'}},
        @{Name='v0 cannot masquerade as install_assets';Change={param($p) $p.asset_allowlist[0].origin='module-request'}},
        @{Name='missing mandatory template';Change={param($p) $p.asset_allowlist=@($p.asset_allowlist | Where-Object target -CNE 'claude-global')}}
    )
    foreach ($case in $profileCases) {
        Change-Profile $case.Change { Expect-Rejection { Get-Plan } $case.Name }
    }
    Change-Profile {param($p)
        $p.asset_allowlist+=@([ordered]@{id='vault-parent';kind='vault';origin='bootstrap';module_id='distribution';source='vault-template/entry.template';target='entry';ownership='managed';files=@('vault-template/entry.template')})
    } { Expect-Rejection { Get-Plan } 'file-versus-directory destination collisions fail before planning' 'target paths overlap' }
    $profileFile=Join-Path $fixtureRepo 'modules/distribution/profiles/core.json'
    $profileBefore=[IO.File]::ReadAllBytes($profileFile)
    try {
        [IO.File]::WriteAllText($profileFile,'{"profile_id":"core","profile_id":"full"}',$utf8)
        Expect-Rejection { Get-Plan } 'duplicate decoded JSON properties fail closed' 'duplicate'
        [IO.File]::WriteAllBytes($profileFile,([byte[]]@(0xEF,0xBB,0xBF)+$profileBefore))
        Expect-Rejection { Get-Plan } 'BOM input is rejected, never implicitly normalized' 'BOM'
    } finally { [IO.File]::WriteAllBytes($profileFile,$profileBefore) }
    Change-Manifest 'memory' {param($m) $m['activation']=$true} { Expect-Rejection { Get-Plan } 'invalid disabled-module Manifest fails before a plan' }
    Change-Manifest 'entry-kernel' {param($m) $m.dependencies.modules+=@('unknown-module')} { Expect-Rejection { Get-Plan } 'unknown Manifest dependency fails' 'Unknown' }
    Change-Manifest 'thin-trust-kernel' {param($m) $m.dependencies.modules=@('entry-kernel')} { Expect-Rejection { Get-Plan } 'Manifest dependency cycle fails' 'cycle' }
    Change-Manifest 'memory' {param($m) $m.ownership.owned_paths+=@('scripts/task.ps1')} { Expect-Rejection { Get-Plan } 'Manifest ownership conflict fails' 'ownership conflict' }
    Change-Manifest 'memory' {param($m) $m.package.install_assets+=@('skills/test/SKILL.md')} { Expect-Rejection { Get-Plan } 'unowned install asset request fails' 'not owned' }
    Change-Manifest 'memory' {param($m) $m.package.install_assets=@()} {
        $plan=Get-Plan full
        Check (@($plan.authorized_module_assets | Where-Object module_id -CEQ 'memory').Count -eq 0 -and @($plan.assets | Where-Object target -CEQ 'obsidian-memory').Count -eq 0) 'Profile allowlist alone cannot fabricate a Manifest request'
    }
    Change-Profile {param($p) $p.enabled_modules=@($p.enabled_modules | Where-Object module_id -CNE 'team')} {
        $plan=Get-Plan full
        Check (@($plan.assets | Where-Object module_id -CEQ 'team').Count -eq 0) 'a disabled capability cannot self-enable through its Manifest'
    } full
    Change-Profile {param($p) $p.asset_allowlist=@($p.asset_allowlist | Where-Object module_id -CNE 'team')} {
        Check (@((Get-Plan full).authorized_module_assets | Where-Object module_id -CEQ 'team').Count -eq 0) 'module requests are intersected with exact Profile asset grants'
    } full

    $plan=Get-Plan
    $tampered=ConvertTo-HarnessDistributionJson $plan | ConvertFrom-Json -AsHashtable
    $tampered.assets[0].target='injected'
    Expect-Rejection { Assert-HarnessDistributionPlanCurrent -RepoRoot $fixtureRepo -Plan $tampered } 'tampered plan digest fails' 'digest'
    $unsigned=[ordered]@{}; foreach($key in $tampered.Keys){if($key -cne 'digest'){$unsigned[$key]=$tampered[$key]}}
    $tampered.digest=Get-HarnessCanonicalJsonSha256 -JsonBytes $utf8.GetBytes((ConvertTo-HarnessDistributionJson $unsigned))
    Expect-Rejection { Assert-HarnessDistributionPlanCurrent -RepoRoot $fixtureRepo -Plan $tampered } 'rehashed forged plan cannot override Profile authorization' 'stale|authorization'
    $source=Join-Path $fixtureRepo 'skills/entry-router/SKILL.md'
    $sourceBefore=[IO.File]::ReadAllBytes($source)
    try {
        [IO.File]::AppendAllText($source,"`nchanged after planning",$utf8)
        Expect-Rejection { Read-HarnessDistributionSourceText -RepoRoot $fixtureRepo -Plan $plan -Source 'skills/entry-router/SKILL.md' } 'source consumer validates the same bytes it renders' 'changed'
        Expect-Rejection { Assert-HarnessDistributionSkillSourcesCurrent -RepoRoot $fixtureRepo -Plan $plan } 'skill transport revalidates source bytes immediately before linking' 'changed'
        Expect-Rejection { Assert-HarnessDistributionPlanCurrent -RepoRoot $fixtureRepo -Plan $plan } 'source drift invalidates the plan' 'stale'
    } finally { [IO.File]::WriteAllBytes($source,$sourceBefore) }
    $extra=Join-Path $fixtureRepo 'skills/entry-router/ungranted.txt'
    try { [IO.File]::WriteAllText($extra,'not authorized',$utf8); Expect-Rejection { Get-Plan } 'ungranted linked-directory payload fails before planning' 'file set' }
    finally { Remove-Item -LiteralPath $extra -Force }
    $outside=Join-Path $scratch 'outside'; New-Item -ItemType Directory -Path $outside | Out-Null
    $alias=Join-Path $fixtureRepo 'skills/entry-router/alias'
    try {
        New-Item -ItemType Junction -Path $alias -Target $outside | Out-Null
        Expect-Rejection { Get-Plan } 'reparse directories are rejected before recursive descent' 'reparse'
    } finally { if (Test-Path -LiteralPath $alias) { [IO.Directory]::Delete($alias) } }

    Change-Profile {param($p) $p['unknown']=$true} { Assert-ZeroWriteInstall 'invalid Profile leaves home/workspace unchanged before any install journal' }
    $stateRoot=Join-Path $fixtureUser '.dev-harness'; New-Item -ItemType Directory -Path $stateRoot | Out-Null
    $pending=Join-Path $stateRoot 'install-transaction.json'
    [IO.File]::WriteAllText($pending,'{"existing_pending_journal":"must remain unchanged"}',$utf8)
    Change-Profile {param($p) $p['unknown']=$true} { Assert-ZeroWriteInstall 'invalid Profile also precedes existing journal recovery or cleanup' }
    Remove-Item -LiteralPath $pending -Force
    [IO.Directory]::Delete($stateRoot)
    $sourceBefore=[IO.File]::ReadAllBytes($source)
    try { Remove-Item -LiteralPath $source -Force; Assert-ZeroWriteInstall 'missing source is rejected without creating install state' }
    finally { [IO.File]::WriteAllBytes($source,$sourceBefore) }
    try { [IO.File]::WriteAllBytes($source,([byte[]]@(0xFF))); Assert-ZeroWriteInstall 'invalid UTF-8 source is rejected before installation writes' }
    finally { [IO.File]::WriteAllBytes($source,$sourceBefore) }
    $jsonTemplate=Join-Path $fixtureRepo 'agent-configs/claude/settings.local.core.json.template'
    $jsonBefore=[IO.File]::ReadAllBytes($jsonTemplate)
    try { [IO.File]::WriteAllText($jsonTemplate,'not JSON',$utf8); Assert-ZeroWriteInstall 'malformed JSON template is rejected before installation writes' }
    finally { [IO.File]::WriteAllBytes($jsonTemplate,$jsonBefore) }
    try { [IO.File]::WriteAllText($jsonTemplate,(([string][char]0xFEFF) * 2 + '{}'),$utf8); Assert-ZeroWriteInstall 'preflight and renderer strip only one BOM from legacy JSON sources' }
    finally { [IO.File]::WriteAllBytes($jsonTemplate,$jsonBefore) }
    try { [IO.File]::WriteAllText($jsonTemplate,'{"inexact":1e-29}',$utf8); Assert-ZeroWriteInstall 'legacy inexact-number rejection occurs before installation writes' }
    finally { [IO.File]::WriteAllBytes($jsonTemplate,$jsonBefore) }
    $alternateTemplate=Join-Path $fixtureRepo 'agent-configs/claude/alternate.md.template'
    try {
        [IO.File]::WriteAllText($alternateTemplate,'# not a settings object',$utf8)
        Change-Profile {param($p)
            $asset=@($p.asset_allowlist | Where-Object target -CEQ 'claude-settings')[0]
            $asset.source='agent-configs/claude/alternate.md.template'; $asset.files=@($asset.source)
        } { Assert-ZeroWriteInstall 'host JSON preflight follows the declared consumer, not a source filename suffix' }
    } finally { Remove-Item -LiteralPath $alternateTemplate -Force }

    # Prove install consumption, not a shadow report: a valid narrowed full Profile
    # changes the actual installed assets, while uninstall still uses its history.
    $compatTemplate=Join-Path $fixtureRepo 'agent-configs/codex/settings.local.shared.json.template'
    $compatJson=[IO.File]::ReadAllText($compatTemplate) -replace '^\s*\{','{"tk06_compat_integer":18446744073709551616,"tk06_compat_decimal":0.1234567890123456789012345678,'
    [IO.File]::WriteAllText($compatTemplate,$compatJson,$utf8)
    Change-Profile {param($p) $p.asset_allowlist=@($p.asset_allowlist | Where-Object module_id -CNE 'team')} {
        $result=Run-Install @('-Preset','full')
        Check ($result.ExitCode -eq 0) 'installer applies a valid Distribution plan'
        if ($result.ExitCode -ne 0) { throw $result.Output }
        foreach ($hostName in @('.claude','.codex','.agents')) {
            Check (-not (Test-Path -LiteralPath (Join-Path $fixtureUser "$hostName/skills/workflow-team")) -and (Test-Path -LiteralPath (Join-Path $fixtureUser "$hostName/skills/obsidian-memory"))) "$hostName consumes the narrowed asset set, preserving allowed skills"
        }
        $installedJson=[IO.File]::ReadAllText((Join-Path $fixtureUser '.codex/.claude/settings.local.json'))
        Check ($installedJson -match '"tk06_compat_integer"\s*:\s*18446744073709551616' -and $installedJson -match '"tk06_compat_decimal"\s*:\s*0\.1234567890123456789012345678') 'legacy host JSON keeps exact BigInteger and Decimal source support'
        $registry=Read-Json (Join-Path $fixtureUser '.dev-harness/install-registry.json')
        $manifest=Read-Json ([string]@($registry.global_manifest_history)[-1])
        Check ($manifest.schema_version -ceq 'install-manifest/v1.2' -and $registry.schema_version -ceq 'install-registry/v1.1' -and @($manifest.feature_ownership.skills) -cnotcontains 'workflow-team') 'historical install schemas persist the actually applied selection without changing digest algorithms'
    } full
    $catalogPath=Join-Path $fixtureRepo 'module-manifest-catalog.json'
    [IO.File]::WriteAllText($catalogPath,'invalid current distribution inputs',$utf8)
    [IO.File]::WriteAllText((Join-Path $fixtureRepo 'modules/distribution/profiles/full.json'),'invalid profile',$utf8)
    $child=Start-RepoProcess -UserProfile $fixtureUser -ScriptPath (Join-Path $fixtureRepo 'uninstall.ps1') -Arguments @('-RepoRoot',$fixtureRepo,'-WorkspaceRoot',$fixtureWorkspace)
    try {
        if (-not $child.Process.WaitForExit(120000)) { $child.Process.Kill($true); throw 'Distribution uninstall fixture timed out' }
        $output=$child.StdOut.GetAwaiter().GetResult()+$child.StdErr.GetAwaiter().GetResult()
        Check ($child.Process.ExitCode -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixtureUser '.claude/skills/obsidian-memory'))) 'uninstall converges from registered history even when current Profile and catalog are invalid'
        if ($child.Process.ExitCode -ne 0) { throw $output }
    } finally { $child.Process.Dispose() }
} catch { Add-Failure $_.Exception.Message; Write-Output "[FAIL] $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
finally {
    $fullScratch=[IO.Path]::GetFullPath($scratch)
    $allowedRoot=[IO.Path]::GetFullPath((Join-Path $RepoRoot 'tmp')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $fullScratch.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Distribution fixture cleanup escaped its fixed repository root' }
    Remove-DirectoryWithRetry -Path $fullScratch
}
Write-Output "Checks passed: $script:Checks"
if ($script:Failures.Count -gt 0) { Write-Output "STATUS: FAIL ($($script:Failures.Count))"; exit 1 }
Write-Output 'STATUS: PASS'
exit 0
