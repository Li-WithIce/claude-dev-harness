Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function ConvertTo-HarnessEvidenceJson {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 50) + "`n"
}

function Read-HarnessEvidenceJson {
    param([string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'Evidence' -MustExist File
    try { $value = [System.IO.File]::ReadAllText($fullPath,[System.Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop }
    catch { throw "Evidence is not valid UTF-8 JSON: $($_.Exception.Message)" }
    if ($value -isnot [System.Collections.IDictionary]) { throw 'Evidence must be a JSON object' }
    return [pscustomobject]@{Document=$value;Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $fullPath)}
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
    param([string]$WorkspaceRoot,[string[]]$Arguments)
    $output = @(& git -C $WorkspaceRoot @Arguments 2>$null)
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Text=($output -join "`n");Lines=$output}
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
    foreach ($record in @($Evidence.records)) {
        $recordPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$record.evidence_path) -Label 'record evidence_path' -MustExist File
        $relative = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $recordPath
        [void]$exactExclusions.Add($relative)
        $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $recordPath
        $evidenceFiles.Add([ordered]@{path=$relative;digest=$digest})
    }
    $gitToolRoot = Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $gitRoot = Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments @('rev-parse','--show-toplevel')
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
        $headRun=Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments @('rev-parse','HEAD');if($headRun.ExitCode -eq 0){$head=$headRun.Text.Trim()}
        $indexState=Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments @('ls-files','-v','--','.')
        if($indexState.ExitCode-ne0){throw 'unable to inspect Git index flags for Evidence revision'}
        $unsafeIndex=@($indexState.Lines|Where-Object{[string]::IsNullOrEmpty([string]$_)-or-not([string]$_).StartsWith('H ',[StringComparison]::Ordinal)})
        if($unsafeIndex.Count-gt0){throw 'Evidence workspace has unsafe Git index flags'}
        $pathspec=[System.Collections.Generic.List[string]]::new();$pathspec.Add('.')
        $pathspec.Add($(if($runningOnWindows){':(icase,glob,exclude).assistant/runtime/**'}else{':(glob,exclude).assistant/runtime/**'}))
        foreach($excluded in @($exactExclusions|Sort-Object)){$pathspec.Add($(if($runningOnWindows){":(icase,literal,exclude)$excluded"}else{":(literal,exclude)$excluded"}))}
        $working=Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments (@('diff','--binary','--')+@($pathspec));if($working.ExitCode -ne 0){throw 'unable to compute working diff for Evidence revision'};$workingDiff=$working.Text
        $staged=Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments (@('diff','--cached','--binary','--')+@($pathspec));if($staged.ExitCode -ne 0){throw 'unable to compute staged diff for Evidence revision'};$stagedDiff=$staged.Text
        $others=Invoke-HarnessEvidenceGit -WorkspaceRoot $gitToolRoot -Arguments @('ls-files','--others','--exclude-standard','--','.');if($others.ExitCode -ne 0){throw 'unable to enumerate untracked files for Evidence revision'}
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
    try{$valid=Test-Json -Json ($document|ConvertTo-Json -Depth 50 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\evidence.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue}catch{throw "Evidence schema validation failed: $($_.Exception.Message)"}
    if(-not$valid){throw 'Evidence failed schema validation'}
    if([string]$document.task_id -cne $TaskId){throw 'Evidence task_id does not match TaskId'}
    if([int]$document.task_version -ne $TaskVersion){throw "Evidence task_version is stale: expected=$TaskVersion actual=$($document.task_version)"}
    if([string]$document.contract_digest -cne $ContractDigest){throw 'Evidence contract_digest is stale'}
    $outputRelative="docs/tasks/$TaskId/evidence.json";[void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $outputRelative -Label 'evidence output' -AllowMissing)
    $covered=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal);$hasFail=$false;$hasBlocked=$false;$hasPartial=$false
    foreach($record in @($document.records)){
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
    return [pscustomobject]@{Document=$document;InputPath=$loaded.Path;OutputPath=$outputRelative;Content=$content;Digest=(Get-HarnessSha256Text -Content $content);Conclusion=$derived;NextStatus=$nextStatus;ExpectedRevision=$expectedRevision}
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
