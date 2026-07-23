Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Approval.psm1') -Force -ErrorAction Stop

function ConvertTo-HarnessEvidenceJson {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 50) + "`n"
}

function Read-HarnessEvidenceJson {
    param([string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'Evidence' -MustExist File
    try { $value = [System.IO.File]::ReadAllText($fullPath,[System.Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-HarnessJson -ErrorAction Stop }
    catch { throw "Evidence is not valid UTF-8 JSON: $($_.Exception.Message)" }
    if ($value -isnot [System.Collections.IDictionary]) { throw 'Evidence must be a JSON object' }
    return [pscustomobject]@{Document=$value;Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $fullPath)}
}

function Assert-HarnessEvidenceActorFields {
    param([System.Collections.IDictionary]$Actor,[string]$Label)
    foreach($field in @('host','model')){if([string]::IsNullOrWhiteSpace([string]$Actor[$field])){throw "$Label $field must not be blank"}}
    foreach($field in @('backend','actor_id','context_id')){if($Actor.Contains($field)-and[string]::IsNullOrWhiteSpace([string]$Actor[$field])){throw "$Label $field must not be blank"}}
}

function Test-HarnessEvidenceExcludedPath {
    param([string]$Path,[string[]]$ExactPaths)
    $comparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if ($Path.Equals('.assistant/runtime',$comparison) -or $Path.StartsWith('.assistant/runtime/',$comparison)) { return $true }
    foreach ($exactPath in @($ExactPaths)) {
        if ($Path.Equals([string]$exactPath,$comparison)) { return $true }
    }
    return $false
}

function Invoke-HarnessEvidenceGit {
    param([string]$GitPath,[string]$WorkspaceRoot,[string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitPath
    $startInfo.WorkingDirectory = $WorkspaceRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false,$true)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($name in @($startInfo.Environment.Keys)) {
        if ([string]$name -like 'GIT_*') { [void]$startInfo.Environment.Remove([string]$name) }
    }
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $startInfo.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.Environment['GIT_CONFIG_GLOBAL'] = $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
    $startInfo.Environment['GIT_ATTR_NOSYSTEM'] = '1'
    $startInfo.ArgumentList.Add('-c')
    $startInfo.ArgumentList.Add('core.fsmonitor=false')
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($WorkspaceRoot)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add([string]$argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            try { $process.Kill($true) } catch {}
            throw 'Git evidence inspection timed out'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Replace("`r`n","`n").TrimEnd("`n")
        [void]$stderrTask.GetAwaiter().GetResult()
        $lines = if ([string]::IsNullOrEmpty($stdout)) { @() } else { @($stdout -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
        return [pscustomobject]@{ExitCode=$process.ExitCode;Text=$stdout;Lines=$lines}
    } finally {
        $process.Dispose()
    }
}

function Get-HarnessEvidenceRevision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,
        [Parameter(Mandatory)][string]$EvidenceInputPath,
        [Parameter(Mandatory)][string]$EvidenceOutputPath
    )
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $inputRelative = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $EvidenceInputPath -Label 'Evidence' -MustExist File)
    $outputRelative = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $EvidenceOutputPath -Label 'evidence output' -AllowMissing)
    $evidenceFiles = [System.Collections.Generic.List[object]]::new()
    $runningOnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $pathComparer = if ($runningOnWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $exactExclusions = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    [void]$exactExclusions.Add($inputRelative);[void]$exactExclusions.Add($outputRelative)
    if ($Evidence.Contains('task_id')) { [void]$exactExclusions.Add("docs/tasks/$([string]$Evidence.task_id)/audit.md") }
    $revisionRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($Evidence.records)) { $revisionRecords.Add($record) }
    if ($Evidence.Contains('dry_run')) { $revisionRecords.Add($Evidence.dry_run) }
    foreach ($record in @($revisionRecords)) {
        $recordPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$record.evidence_path) -Label 'record evidence_path' -MustExist File
        $relative = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $recordPath
        $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $recordPath
        $evidenceFiles.Add([ordered]@{path=$relative;digest=$digest})
    }
    $gitToolRoot = Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $gitCommand = @(Get-Command git -CommandType Application -ErrorAction Stop)[0]
    $gitPath = [System.IO.Path]::GetFullPath([string]$gitCommand.Source)
    $gitRoot = Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('rev-parse','--show-toplevel')
    $head = '';$workingDiff='';$stagedDiff='';$untracked=[System.Collections.Generic.List[object]]::new();$gitUsable=$false
    if ($gitRoot.ExitCode -eq 0) {
        try { $resolvedGitRoot = (Resolve-Path -LiteralPath $gitRoot.Text).Path } catch { $resolvedGitRoot = '' }
        $gitUsable = if ($runningOnWindows) {
            $resolvedGitRoot.Equals($gitToolRoot,[System.StringComparison]::OrdinalIgnoreCase)
        } else {
            $resolvedGitRoot -ceq $gitToolRoot
        }
        if (-not $gitUsable -and $runningOnWindows -and -not [string]::IsNullOrWhiteSpace($resolvedGitRoot)) {
            try {
                $gitUsable = (Get-HarnessPhysicalPathIdentity -Path $resolvedGitRoot) -ceq (Get-HarnessPhysicalPathIdentity -Path $gitToolRoot)
            } catch {
                $gitUsable = $false
            }
        }
    }
    if ($gitUsable) {
        $trackedInput=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('ls-files','--error-unmatch','--',$inputRelative)
        if($trackedInput.ExitCode-eq0){[void]$exactExclusions.Remove($inputRelative)}elseif($trackedInput.ExitCode-ne1){throw 'unable to classify Evidence input path in Git'}
        $headRun=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('rev-parse','HEAD');if($headRun.ExitCode -eq 0){$head=$headRun.Text.Trim()}
        $indexState=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('ls-files','-v','--','.')
        if($indexState.ExitCode-ne0){throw 'unable to inspect Git index flags for Evidence revision'}
        $unsafeIndex=@($indexState.Lines|Where-Object{[string]::IsNullOrEmpty([string]$_)-or-not([string]$_).StartsWith('H ',[StringComparison]::Ordinal)})
        if($unsafeIndex.Count-gt0){throw 'Evidence workspace has unsafe Git index flags'}
        $effectiveFilters=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('config','--includes','--get-regexp','^filter\.')
        if($effectiveFilters.ExitCode-eq0){throw 'Evidence workspace has unsupported Git clean filters'}
        if($effectiveFilters.ExitCode-ne1){throw 'unable to inspect Git clean filters for Evidence revision'}
        $pathspec=[System.Collections.Generic.List[string]]::new();$pathspec.Add('.')
        $pathspec.Add($(if($runningOnWindows){':(icase,glob,exclude).assistant/runtime/**'}else{':(glob,exclude).assistant/runtime/**'}))
        foreach($excluded in @($exactExclusions|Sort-Object)){$pathspec.Add($(if($runningOnWindows){":(icase,literal,exclude)$excluded"}else{":(literal,exclude)$excluded"}))}
        $working=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments (@('diff','--ignore-submodules=none','--no-ext-diff','--no-textconv','--binary','--')+@($pathspec));if($working.ExitCode -ne 0){throw 'unable to compute working diff for Evidence revision'};$workingDiff=$working.Text
        $staged=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments (@('diff','--cached','--ignore-submodules=none','--no-ext-diff','--no-textconv','--binary','--')+@($pathspec));if($staged.ExitCode -ne 0){throw 'unable to compute staged diff for Evidence revision'};$stagedDiff=$staged.Text
        $others=Invoke-HarnessEvidenceGit -GitPath $gitPath -WorkspaceRoot $gitToolRoot -Arguments @('ls-files','--others','--exclude-standard','--','.');if($others.ExitCode-ne0){throw 'unable to enumerate untracked files for Evidence revision'}
        foreach($path in @($others.Lines|ForEach-Object{$_.Replace('\','/')}|Sort-Object)){
            if(Test-HarnessEvidenceExcludedPath -Path $path -ExactPaths @($exactExclusions)){continue}
            $untracked.Add([ordered]@{path=$path;digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path)})
        }
        if([string]::IsNullOrEmpty($workingDiff)-and[string]::IsNullOrEmpty($stagedDiff)-and$untracked.Count-eq 0){return $head}
    } else {
        foreach($file in Get-ChildItem -LiteralPath $WorkspaceRoot -File -Force -Recurse|Sort-Object FullName){
            $relative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $file.FullName
            if(Test-HarnessEvidenceExcludedPath -Path $relative -ExactPaths @($exactExclusions)){continue}
            $untracked.Add([ordered]@{path=$relative;digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $file.FullName)})
        }
    }
    $workspaceIdentity = if ($runningOnWindows) {
        Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot
    } else {
        Get-HarnessSha256Text -Content $WorkspaceRoot
    }
    $revisionInput=[ordered]@{
        workspace_identity=$workspaceIdentity
        head=$head
        contract_digest=$ContractDigest
        working_diff=(Get-HarnessSha256Text -Content $workingDiff)
        staged_diff=(Get-HarnessSha256Text -Content $stagedDiff)
        untracked=@($untracked)
        evidence_files=@($evidenceFiles|Sort-Object path)
    }
    return 'dirty:'+(Get-HarnessSha256Text -Content ($revisionInput|ConvertTo-Json -Depth 30 -Compress)).Substring(7)
}

function Resolve-HarnessEvidenceCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TaskVersion,
        [Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][int]$RequiredAcceptanceCount,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PinnedRevision
    )
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $loaded=Read-HarnessEvidenceJson -WorkspaceRoot $WorkspaceRoot -Path $EvidencePath;$document=$loaded.Document
    foreach($record in @($document.records)){if($record -is [System.Collections.IDictionary]-and$record.Contains('actor')){if($record.actor-isnot[System.Collections.IDictionary]){throw 'Evidence record actor must be an object'};Assert-HarnessEvidenceActorFields -Actor $record.actor -Label 'Evidence record actor'}}
    if($document.Contains('dry_run')){if($document.dry_run -isnot [System.Collections.IDictionary]-or$document.dry_run.actor-isnot[System.Collections.IDictionary]){throw 'dry-run actor must be an object'};Assert-HarnessEvidenceActorFields -Actor $document.dry_run.actor -Label 'dry-run actor'}
    try{$valid=Test-Json -Json ($document|ConvertTo-Json -Depth 50 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\evidence.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue}catch{throw "Evidence schema validation failed: $($_.Exception.Message)"}
    if(-not$valid){throw 'Evidence failed schema validation'}
    if([string]$document.task_id -cne $TaskId){throw 'Evidence task_id does not match TaskId'}
    if([int]$document.task_version -ne $TaskVersion){throw "Evidence task_version is stale: expected=$TaskVersion actual=$($document.task_version)"}
    if([string]$document.contract_digest -cne $ContractDigest){throw 'Evidence contract_digest is stale'}
    $protectedOperation=$null
    if($document.Contains('protected_operation')){$protectedOperation=Resolve-HarnessProtectedOperation -TaskVersion $TaskVersion -ContractDigest $ContractDigest -Operation $document.protected_operation -Label 'Evidence protected_operation'}
    $outputRelative="docs/tasks/$TaskId/evidence.json";[void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $outputRelative -Label 'evidence output' -AllowMissing)
    $covered=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal);$hasFail=$false;$hasBlocked=$false;$hasPartial=$false
    foreach($record in @($document.records)){
        if($record.Contains('operation_identity')){
            if($null-eq$protectedOperation){throw 'Evidence record operation_identity requires protected_operation'}
            if([string]$record.operation_identity-cne[string]$protectedOperation.identity){throw 'Evidence record operation_identity does not match protected_operation'}
        }
        $recordPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$record.evidence_path) -Label 'record evidence_path' -MustExist File
        if((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $recordPath)-cne[string]$record.digest){throw "Evidence record digest mismatch: $($record.evidence_path)"}
        if([string]$record.type -ceq 'command'){
            [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$record.cwd) -Label 'record cwd' -MustExist Directory)
            if([int]$record.exit_code -ne 0){$hasFail=$true}
        }else{
            if([string]$record.result -ceq 'fail'){$hasFail=$true}elseif([string]$record.result -ceq 'blocked'){$hasBlocked=$true}elseif([string]$record.result -ceq 'partial'){$hasPartial=$true}
        }
        foreach($item in @($record.covers)){[void]$covered.Add([string]$item)}
    }
    if($document.Contains('dry_run')){
        $dryRun=$document.dry_run
        if([string]::IsNullOrWhiteSpace([string]$dryRun.command)){throw 'dry-run command must not be blank'}
        foreach($field in @('host','model','actor_id','context_id')){if([string]::IsNullOrWhiteSpace([string]$dryRun.actor[$field])){throw "dry-run executor $field must not be blank"}}
        if($dryRun.actor.Contains('backend')-and[string]::IsNullOrWhiteSpace([string]$dryRun.actor.backend)){throw 'dry-run executor backend must not be blank'}
        if($null-ne$protectedOperation-and@($dryRun.covers).Count-eq0){throw 'dry-run covers must not be empty for protected_operation'}
        if($dryRun.Contains('operation_identity')){
            if($null-eq$protectedOperation){throw 'dry-run operation_identity requires protected_operation'}
            if([string]$dryRun.operation_identity-cne[string]$protectedOperation.identity){throw 'dry-run operation_identity does not match protected_operation'}
            if(@($dryRun.covers)-cnotcontains[string]$protectedOperation.identity){throw 'dry-run covers does not include protected_operation identity'}
        }
        $dryRunPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$dryRun.evidence_path) -Label 'dry-run evidence_path' -MustExist File
        if((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $dryRunPath)-cne[string]$dryRun.digest){throw "dry-run Evidence digest mismatch: $($dryRun.evidence_path)"}
        [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$dryRun.cwd) -Label 'dry-run cwd' -MustExist Directory)
        if([int]$dryRun.exit_code-ne0){$hasFail=$true}
    }
    $buckets=[System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    foreach($pair in @(@('satisfied',$document.coverage.satisfied),@('not_verified',$document.coverage.not_verified),@('blocked',$document.coverage.blocked))){
        foreach($item in @($pair[1])){if($buckets.ContainsKey([string]$item)){throw "Evidence coverage overlaps: $item"};$buckets.Add([string]$item,[string]$pair[0])}
    }
    foreach($item in @($document.coverage.satisfied)){if(-not$covered.Contains([string]$item)){throw "Evidence satisfied coverage has no record: $item"}}
    for($index=1;$index-le$RequiredAcceptanceCount;$index++){$id="AC-$index";if(-not$buckets.ContainsKey($id)){$hasPartial=$true}elseif($buckets[$id]-ceq'not_verified'){$hasPartial=$true}elseif($buckets[$id]-ceq'blocked'){$hasBlocked=$true}}
    foreach($gap in @($document.gaps)){if([string]$gap.status -ceq 'not-verified'){$hasPartial=$true}else{$hasBlocked=$true}}
    if(@($document.coverage.not_verified).Count-gt 0){$hasPartial=$true};if(@($document.coverage.blocked).Count-gt 0){$hasBlocked=$true}
    $derived=if($hasFail){'fail'}elseif($hasBlocked){'blocked'}elseif($hasPartial){'partial'}else{'pass'}
    if([string]$document.conclusion -cne $derived){throw "Evidence conclusion does not match records and coverage: declared=$($document.conclusion) derived=$derived"}
    $actualRevision=[string]$document.revision
    if([string]::IsNullOrWhiteSpace($PinnedRevision)){
        $expectedRevision=Get-HarnessEvidenceRevision -WorkspaceRoot $WorkspaceRoot -ContractDigest $ContractDigest -Evidence $document -EvidenceInputPath $loaded.Path -EvidenceOutputPath $outputRelative
        if($expectedRevision.StartsWith('dirty:',[StringComparison]::Ordinal)){if($actualRevision-cne$expectedRevision){throw 'Evidence dirty revision is stale'}}elseif($actualRevision-cne$expectedRevision){throw 'Evidence commit revision is stale'}
    }else{
        $expectedRevision=$PinnedRevision
        if($actualRevision-cne$expectedRevision){throw 'Evidence revision no longer matches its transaction snapshot'}
    }
    $content=ConvertTo-HarnessEvidenceJson -Value $document
    $nextStatus=switch($derived){'pass'{'done'}'fail'{'running'}'blocked'{'paused'}default{'verifying'}}
    return [pscustomobject]@{Document=$document;InputPath=$loaded.Path;OutputPath=$outputRelative;Content=$content;Digest=(Get-HarnessSha256Text -Content $content);Conclusion=$derived;NextStatus=$nextStatus;ExpectedRevision=$expectedRevision;ProtectedOperation=$protectedOperation}
}

function Resolve-HarnessEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TaskVersion,
        [Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][int]$RequiredAcceptanceCount,
        [Parameter(Mandatory)][string]$EvidencePath
    )
    return Resolve-HarnessEvidenceCore -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskVersion $TaskVersion -ContractDigest $ContractDigest -RequiredAcceptanceCount $RequiredAcceptanceCount -EvidencePath $EvidencePath -PinnedRevision ''
}

Export-ModuleMember -Function Get-HarnessEvidenceRevision,Resolve-HarnessEvidence
