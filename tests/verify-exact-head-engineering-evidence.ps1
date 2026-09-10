[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path

$script:checks = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()
$script:caseIndex = 0
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Get-BytesDigest([byte[]]$Bytes) { return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-FileDigest([string]$Path) { return Get-BytesDigest ([IO.File]::ReadAllBytes($Path)) }
function Get-TextDigest([string]$Text) { return Get-BytesDigest ([Text.UTF8Encoding]::new($false).GetBytes($Text)) }
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
function Write-Document([string]$Path,[Collections.IDictionary]$Document,[switch]$Compress) {
    $json = if ($Compress) { $Document | ConvertTo-Json -Depth 100 -Compress } else { $Document | ConvertTo-Json -Depth 100 }
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}
function Set-ReportDigest([Collections.IDictionary]$Document) {
    $Document.report_digest = $null
    $Document.report_digest = Get-TextDigest ($Document | ConvertTo-Json -Depth 100 -Compress)
}
function Invoke-Git([string]$Root,[string[]]$Arguments) {
    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed: git $($Arguments -join ' '): $($output -join ' | ')" }
    return ($output -join [Environment]::NewLine).Trim()
}
function Copy-SubjectFile([string]$SourceRoot,[string]$SubjectRoot,[string]$RelativePath) {
    $source = Join-Path $SourceRoot $RelativePath
    $target = Join-Path $SubjectRoot $RelativePath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy($source,$target,$false)
}
function Replace-FixtureTokens([string]$Path,[string]$BaseSha,[string]$HeadSha) {
    $text = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $text = $text.Replace('__BASE_SHA__',$BaseSha).Replace('__HEAD_SHA__',$HeadSha)
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}
function Get-ReviewReceipt([string]$FixtureRoot) {
    $comment = Get-Content -LiteralPath (Join-Path $FixtureRoot 'review-comment.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $fence = ([string]([char]96)) * 3
    $pattern = '(?s)' + [regex]::Escape($fence) + '(?:json)?\s*(?<json>\{.*\})\s*' + [regex]::Escape($fence)
    $match = [regex]::Match([string]$comment.body,$pattern)
    if (-not $match.Success) { throw 'review fixture receipt missing' }
    return $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}
function Set-ReviewReceipt([string]$FixtureRoot,[Collections.IDictionary]$Receipt,[switch]$Duplicate) {
    $path = Join-Path $FixtureRoot 'review-comment.json'
    $comment = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $fence = ([string]([char]96)) * 3
    $block = $fence + 'json' + [Environment]::NewLine + ($Receipt | ConvertTo-Json -Depth 100 -Compress) + [Environment]::NewLine + $fence
    $comment.body = 'Independent exact-head review fixture.' + [Environment]::NewLine + [Environment]::NewLine + $block
    if ($Duplicate) { $comment.body += [Environment]::NewLine + [Environment]::NewLine + $block }
    Write-Document -Path $path -Document $comment -Compress
}
function Update-Json([string]$Path,[scriptblock]$Mutation) {
    $document = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    & $Mutation $document
    Write-Document -Path $Path -Document $document -Compress
}
function Invoke-Producer([string]$SubjectRoot,[string]$FixtureRoot,[string]$OutputPath,[string]$Mode = 'test-only',[switch]$OmitFixture) {
    $pwsh = (Get-Process -Id $PID -ErrorAction Stop).Path
    $arguments = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $SubjectRoot 'scripts\generate-exact-head-engineering-evidence.ps1'),
        '-RepoRoot',$SubjectRoot,'-RepositoryFullName','Li-WithIce/claude-dev-harness','-PullRequestNumber','2',
        '-RunId','9001','-ReviewCommentId','8001','-OutputPath',$OutputPath,'-ProducerMode',$Mode
    )
    if (-not $OmitFixture) { $arguments += @('-GitHubFixtureRoot',$FixtureRoot) }
    $output = @(& $pwsh @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $document = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        Get-Content -LiteralPath $OutputPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    } else { $null }
    return [ordered]@{exit_code=$exitCode;output=($output -join [Environment]::NewLine);document=$document}
}
function New-Gate([Collections.IDictionary]$Source,[string]$Path,[string]$Status='pass',[string]$Identity='forged-caller') {
    return [ordered]@{'DP-G00-EXACT-HEAD-ENGINEERING-CI'=[ordered]@{
        status=$Status
        evidence_contract='thin-harness-exact-head-engineering-evidence/v1'
        artifact_path=$Path
        evidence_digest=Get-FileDigest $Path
        source_revision=[string]$Source.revision
        producer_identity=$Identity
    }}
}
function Invoke-Gate([System.Management.Automation.PSModuleInfo]$Module,[string]$Root,[Collections.IDictionary]$Source,[Collections.IDictionary]$Gates,[string[]]$ProtectedRoots=@()) {
    try {
        $value = & $Module {
            param($Repo,$Expected,$Items,$Protected)
            Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Repo -ExpectedSource $Expected -Gates $Items -ProtectedRoots $Protected
        } $Root $Source $Gates $ProtectedRoots
        return [ordered]@{success=$true;value=$value;reason='';detail=''}
    } catch { return [ordered]@{success=$false;value=$null;reason=[string]$_.Exception.Message;detail=[string]$_.Exception.InnerException.Message} }
}
function Write-ReportVariant([string]$Path,[Collections.IDictionary]$Source,[scriptblock]$Mutation) {
    $copy = Copy-Document $Source
    & $Mutation $copy
    Set-ReportDigest $copy
    Write-Document -Path $Path -Document $copy -Compress
    return $copy
}
function New-FixtureCase([string]$ValidRoot,[string]$Name) {
    $script:caseIndex++
    $target = Join-Path (Split-Path -Parent $ValidRoot) ("case-{0:d2}-{1}" -f $script:caseIndex,$Name)
    Copy-Item -LiteralPath $ValidRoot -Destination $target -Recurse -Force
    return $target
}
function Invoke-FixtureCase([string]$ValidRoot,[string]$SubjectRoot,[string]$Name,[scriptblock]$Mutation) {
    $root = New-FixtureCase -ValidRoot $ValidRoot -Name $Name
    & $Mutation $root
    $output = Join-Path (Split-Path -Parent $ValidRoot) ("case-output-{0:d2}.json" -f $script:caseIndex)
    return Invoke-Producer -SubjectRoot $SubjectRoot -FixtureRoot $root -OutputPath $output
}
function Check-ProducerRejects([string]$ValidRoot,[string]$SubjectRoot,[string]$Name,[scriptblock]$Mutation) {
    $result = Invoke-FixtureCase -ValidRoot $ValidRoot -SubjectRoot $SubjectRoot -Name $Name -Mutation $Mutation
    Check ($result.exit_code -ne 0 -and $null -eq $result.document) "Producer rejects $Name" "Producer accepted $Name"
}
function Check-ProducerResultFalse([string]$ValidRoot,[string]$SubjectRoot,[string]$Name,[string]$ResultName,[scriptblock]$Mutation) {
    $result = Invoke-FixtureCase -ValidRoot $ValidRoot -SubjectRoot $SubjectRoot -Name $Name -Mutation $Mutation
    Check ($result.exit_code -eq 3 -and $null -ne $result.document -and -not [bool]$result.document.results[$ResultName] -and [string]$result.document.status -ceq 'unavailable') "Producer records $Name without pass" "Producer promoted or lost $Name"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-exact-head-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $subject = Join-Path $temp 'subject'
    [void][IO.Directory]::CreateDirectory($subject)
    [IO.File]::WriteAllText((Join-Path $subject 'baseline.txt'),'base',[Text.UTF8Encoding]::new($false))
    Invoke-Git $subject @('init','--initial-branch=codex/harness-v2-public-optin-beta') | Out-Null
    Invoke-Git $subject @('config','user.name','Exact Head Fixture') | Out-Null
    Invoke-Git $subject @('config','user.email','fixture@example.invalid') | Out-Null
    Invoke-Git $subject @('config','core.autocrlf','false') | Out-Null
    $env:GIT_AUTHOR_DATE='2026-01-01T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
    Invoke-Git $subject @('add','baseline.txt') | Out-Null
    Invoke-Git $subject @('commit','-m','fixture base') | Out-Null
    $baseSha = Invoke-Git $subject @('rev-parse','HEAD')
    Invoke-Git $subject @('switch','-c','codex/harness-v2-default-promotion') | Out-Null
    [IO.File]::WriteAllText((Join-Path $subject 'task-start.txt'),'task-start',[Text.UTF8Encoding]::new($false))
    $env:GIT_AUTHOR_DATE='2026-01-02T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-02T00:00:00Z'
    Invoke-Git $subject @('add','task-start.txt') | Out-Null
    Invoke-Git $subject @('commit','-m','fixture task start') | Out-Null
    $taskStartingSha = Invoke-Git $subject @('rev-parse','HEAD')

    $subjectFiles = @(
        'scripts/generate-exact-head-engineering-evidence.ps1',
        'scripts/lib/Harness.RolloutEvidence.psm1',
        'scripts/lib/Harness.AtomicWrite.psm1',
        'scripts/lib/Harness.Hashing.psm1',
        'scripts/lib/Harness.Path.psm1',
        'scripts/host-benchmark/HostBenchmark.Trial.ps1',
        'schemas/exact-head-engineering-evidence.schema.json',
        'schemas/ordinary-ci-receipt.schema.json'
    )
    foreach ($relative in $subjectFiles) { Copy-SubjectFile -SourceRoot $RepoRoot -SubjectRoot $subject -RelativePath $relative }
    [IO.File]::WriteAllText((Join-Path $subject 'head.txt'),'head',[Text.UTF8Encoding]::new($false))
    $env:GIT_AUTHOR_DATE='2026-01-03T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-03T00:00:00Z'
    Invoke-Git $subject @('add','--all') | Out-Null
    Invoke-Git $subject @('commit','-m','fixture head') | Out-Null
    $headSha = Invoke-Git $subject @('rev-parse','HEAD')
    Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue

    $subjectModule = Import-Module (Join-Path $subject 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
    $source = & $subjectModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $subject
    $reviewedDiff = & $subjectModule { param($Root,$Base,$Head) Get-ExactHeadGitDiff -RepoRoot $Root -BaseSha $Base -HeadSha $Head } $subject $baseSha $headSha
    $taskDiff = & $subjectModule { param($Root,$Base,$Head) Get-ExactHeadGitDiff -RepoRoot $Root -BaseSha $Base -HeadSha $Head } $subject $taskStartingSha $headSha

    $fixture = Join-Path $temp 'fixture-valid'
    [void][IO.Directory]::CreateDirectory($fixture)
    $template = Join-Path $RepoRoot 'tests\fixtures\exact-head-engineering'
    foreach ($name in @('pull-request.json','workflow-run.json','workflow-jobs.json','workflow-artifacts.json','review-comment.json','ordinary-ci-receipt.json')) {
        [IO.File]::Copy((Join-Path $template $name),(Join-Path $fixture $name),$false)
    }
    foreach ($name in @('pull-request.json','workflow-run.json','workflow-artifacts.json')) { Replace-FixtureTokens -Path (Join-Path $fixture $name) -BaseSha $baseSha -HeadSha $headSha }
    $definitions = @(
        [ordered]@{id=1001;check='changed-optional';job='changed-optional'},
        [ordered]@{id=1002;check='core-rollback';job='pr-core'},
        [ordered]@{id=1003;check='entry-lifecycle';job='pr-core-checks'},
        [ordered]@{id=1004;check='evaluation-release';job='pr-core-checks'},
        [ordered]@{id=1005;check='governance-approval';job='pr-core-checks'},
        [ordered]@{id=1006;check='harness-contracts';job='pr-core-checks'},
        [ordered]@{id=1007;check='install-evidence';job='pr-core-checks'}
    )
    $rawDigests = [ordered]@{}
    $receiptTemplate = Get-Content -LiteralPath (Join-Path $fixture 'ordinary-ci-receipt.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 20 -DateKind String
    foreach ($definition in $definitions) {
        $directory = Join-Path $fixture ("artifacts\{0}" -f $definition.id)
        [void][IO.Directory]::CreateDirectory($directory)
        $receipt = Copy-Document $receiptTemplate
        $receipt.head_sha=$headSha;$receipt.base_sha=$baseSha;$receipt.checkout_sha=$headSha;$receipt.job_id=$definition.job;$receipt.check_name=$definition.check
        $receiptPath = Join-Path $directory 'ordinary-ci-receipt.json'
        Write-Document -Path $receiptPath -Document $receipt -Compress
        $rawDigests[$definition.check] = Get-FileDigest $receiptPath
    }
    $receiptSetText = @($definitions | ForEach-Object { "{0}={1}" -f $_.check,[string]$rawDigests[$_.check] }) -join [char]10
    $receiptSetBytes = [Text.UTF8Encoding]::new($false).GetBytes($receiptSetText)
    $reviewReceipt = [ordered]@{
        schema_version='thin-harness-independent-review-receipt/v1'
        pull_request_number=2
        base_sha=$baseSha
        head_sha=$headSha
        reviewed_diff_digest=[string]$reviewedDiff.digest
        reviewed_diff_bytes=[long]$reviewedDiff.bytes
        task_starting_sha=$taskStartingSha
        task_diff_digest=[string]$taskDiff.digest
        task_diff_bytes=[long]$taskDiff.bytes
        reviewed_commits=@($headSha)
        ci_run_id='9001'
        ci_run_attempt=1
        ci_conclusion='success'
        receipt_set_digest=Get-BytesDigest $receiptSetBytes
        receipt_set_bytes=[long]$receiptSetBytes.Length
        artifact_ids=@($definitions.id)
        runtime_hotfix_identity='sha256:f584fc93bb80a4a06b0b488dd9f50031169d61334160a16181602c72dfbe39e0'
        reviewer_actor_id='fixture-independent-reviewer'
        reviewer_context_id='fixture-read-only-context'
        reviewer_model='not_exposed'
        reviewer_participated=$false
        read_only=$true
        zero_write=$true
        verdict='pass'
        findings=[ordered]@{p0=0;p1=0;p2=0;p3=1}
        skipped_jobs=@('release-model','release-host','release-full')
        created_at_utc='2026-08-06T00:01:00Z'
    }
    Set-ReviewReceipt -FixtureRoot $fixture -Receipt $reviewReceipt

    $reportPath = Join-Path $temp 'exact-head-test-only.json'
    $producer = Invoke-Producer -SubjectRoot $subject -FixtureRoot $fixture -OutputPath $reportPath
    $report = $producer.document
    Check ($producer.exit_code -eq 3 -and $null -ne $report -and [string]$report.status -ceq 'unavailable' -and [string]$report.reason -ceq 'non-formal-producer-mode') 'test-only Producer emits unavailable, never pass' 'test-only Producer passed or failed to emit a report'
    Check (@($report.results.Keys | Where-Object { -not [bool]$report.results[$_] }).Count -eq 0) 'sanitized exact-head Fixture satisfies every machine result' 'positive exact-head Fixture did not satisfy all machine results'
    Check ([string]$report.independent_review.reviewer_model -ceq 'not_exposed' -and [long]$report.independent_review.findings.p3 -eq 1) 'reviewer model is preserved and P3 does not block the machine contract' 'reviewer model was invented or P3 blocked the contract'
    $reportText = Get-Content -LiteralPath $reportPath -Raw -Encoding utf8
    Check ($reportText -notmatch 'Independent exact-head review fixture|fixture@example|Authorization|Bearer |GH_TOKEN|raw[ _-]?(?:api|log|diff)|[A-Za-z]:\\') 'Report omits raw API, review body, diff, token, email, and private paths' 'Report persisted non-portable or sensitive source material'
    Check ((Test-Json -Json $reportText -SchemaFile (Join-Path $subject 'schemas\exact-head-engineering-evidence.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue)) 'strict G00 Schema accepts the positive report' 'strict G00 Schema rejected the positive report'

    $testOnlyGate = New-Gate -Source $source -Path $reportPath -Status pass -Identity forged-caller
    $testOnlyAdapted = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $testOnlyGate
    Check ($testOnlyAdapted.success -and [string]$testOnlyGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].status -ceq 'unavailable' -and [string]$testOnlyGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].producer_identity -ceq 'exact-head-engineering-evidence/v1') 'G00 Adapter overwrites forged caller claims with test-only unavailability and fixed identity' 'G00 Adapter trusted caller status or identity'

    $manualSummaryPath = Join-Path $temp 'manual-pr-summary.json'
    Write-Document -Path $manualSummaryPath -Document ([ordered]@{head_sha=$headSha;ci_success=$true;artifact_ids=@($definitions.id);review_verdict='pass'}) -Compress
    $manualSummaryGate = New-Gate -Source $source -Path $manualSummaryPath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $manualSummaryGate).success) 'manual PR summary fields cannot form G00 pass' 'the Adapter treated a manual PR summary as machine evidence'

    $formalPassPath = Join-Path $temp 'exact-head-formal-pass.json'
    $formalPass = Write-ReportVariant -Path $formalPassPath -Source $report -Mutation {
        param($d)$d.producer_mode='formal';$d.status='pass';$d.reason='all-exact-head-engineering-checks-passed'
    }
    $formalPassGate = New-Gate -Source $source -Path $formalPassPath -Status fail -Identity forged-caller
    $formalPassAdapted = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $formalPassGate
    Check ($formalPassAdapted.success -and [string]$formalPassGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].status -ceq 'pass' -and [string]$formalPassGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].producer_identity -ceq 'exact-head-engineering-evidence/v1') 'strict formal Contract Fixture derives G00 pass and fixed identity' "strict formal Contract Fixture did not derive G00 pass: $($formalPassAdapted.reason) / $($formalPassAdapted.detail)"

    $formalFailPath = Join-Path $temp 'exact-head-formal-fail.json'
    $formalFail = Write-ReportVariant -Path $formalFailPath -Source $formalPass -Mutation {
        param($d)$d.workflow.conclusion='failure';$d.results.ordinary_jobs_passed=$false;$d.status='fail';$d.reason='exact-head-engineering-check-failed'
    }
    $formalFailGate = New-Gate -Source $source -Path $formalFailPath -Status pass -Identity forged-caller
    $formalFailAdapted = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $formalFailGate
    Check ($formalFailAdapted.success -and [string]$formalFailGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].status -ceq 'fail') 'formal failure overrides forged caller pass' "formal failure was promoted or rejected instead of adapted: $($formalFailAdapted.reason) / $($formalFailAdapted.detail)"

    $formalUnavailablePath = Join-Path $temp 'exact-head-formal-unavailable.json'
    $formalUnavailable = Write-ReportVariant -Path $formalUnavailablePath -Source $formalFail -Mutation {
        param($d)$d.status='unavailable';$d.reason='github-evidence-unavailable'
    }
    $formalUnavailableGate = New-Gate -Source $source -Path $formalUnavailablePath -Status pass -Identity forged-caller
    $formalUnavailableAdapted = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $formalUnavailableGate
    Check ($formalUnavailableAdapted.success -and [string]$formalUnavailableGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].status -ceq 'unavailable') 'formal unavailability overrides forged caller pass' "formal unavailability was promoted or rejected instead of adapted: $($formalUnavailableAdapted.reason) / $($formalUnavailableAdapted.detail)"

    $releaseCountedPath = Join-Path $temp 'release-skipped-counted.json'
    $releaseCounted = Write-ReportVariant -Path $releaseCountedPath -Source $formalPass -Mutation {
        param($d)$d.workflow.release_jobs['release-model']='success';$d.results.release_jobs_not_counted_as_pass=$false;$d.status='fail';$d.reason='exact-head-engineering-check-failed'
    }
    $releaseCountedGate = New-Gate -Source $source -Path $releaseCountedPath
    $releaseCountedResult = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $releaseCountedGate
    Check ($releaseCountedResult.success -and [string]$releaseCountedGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].status -ceq 'fail') 'skipped Release jobs cannot be counted as pass' "a Release job substitution formed G00 pass: $($releaseCountedResult.reason) / $($releaseCountedResult.detail)"

    $rejectMutations = [ordered]@{
        'unknown report field'={param($d)$d['unexpected']='value'}
        'wrong receipt order'={param($d)$swap=$d.ordinary_receipts.checks[0];$d.ordinary_receipts.checks[0]=$d.ordinary_receipts.checks[1];$d.ordinary_receipts.checks[1]=$swap}
        'dirty source summary'={param($d)$d.source_dirty=$true}
        'unstable source summary'={param($d)$d.source_state_stable=$false}
        'private path content'={param($d)$separator=[IO.Path]::DirectorySeparatorChar;$d.independent_review.reviewer_model=('C:'+$separator+'Users'+$separator+'sentinel')}
        'token content'={param($d)$d.independent_review.reviewer_model=('Bear'+'er '+'sentinel')}
        'raw log content'={param($d)$d.independent_review.reviewer_model=('raw'+' log: sentinel')}
        'test-only presented as formal pass'={param($d)$d.producer_mode='test-only';$d.status='pass';$d.reason='all-exact-head-engineering-checks-passed'}
        'reviewed Diff digest mismatch'={param($d)$d.independent_review.reviewed_diff_digest='sha256:'+('0'*64)}
        'reviewed Diff byte mismatch'={param($d)$d.independent_review.reviewed_diff_bytes=[long]$d.independent_review.reviewed_diff_bytes+1}
        'stale Producer input digest'={param($d)$d.source.input_digests.producer_digest='sha256:'+('1'*64)}
    }
    foreach ($entry in $rejectMutations.GetEnumerator()) {
        $path = Join-Path $temp ("adapter-reject-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $null = Write-ReportVariant -Path $path -Source $formalPass -Mutation $entry.Value
        $gate = New-Gate -Source $source -Path $path
        $result = Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $gate
        Check (-not $result.success) "G00 Adapter rejects $($entry.Key)" "G00 Adapter accepted $($entry.Key)"
    }

    $digestMismatchGate = New-Gate -Source $source -Path $formalPassPath
    $digestMismatchGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].evidence_digest='sha256:'+('2'*64)
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $digestMismatchGate).success) 'G00 Adapter rejects raw Artifact digest mismatch' 'G00 Adapter accepted a raw Artifact digest mismatch'
    $relativeGate = New-Gate -Source $source -Path $formalPassPath;$relativeGate['DP-G00-EXACT-HEAD-ENGINEERING-CI'].artifact_path='relative.json'
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $relativeGate).success) 'G00 Adapter rejects a relative Artifact path' 'G00 Adapter accepted a relative Artifact path'
    $protectedGate = New-Gate -Source $source -Path $formalPassPath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $protectedGate -ProtectedRoots @($temp)).success) 'G00 Adapter rejects Protected Root overlap' 'G00 Adapter accepted Protected Root overlap'

    $bomPath=Join-Path $temp 'adapter-bom.json';[IO.File]::WriteAllBytes($bomPath,[Text.UTF8Encoding]::new($true).GetPreamble()+[IO.File]::ReadAllBytes($formalPassPath))
    $bomGate=New-Gate -Source $source -Path $bomPath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $bomGate).success) 'G00 Adapter rejects UTF-8 BOM' 'G00 Adapter accepted UTF-8 BOM'
    $duplicatePath=Join-Path $temp 'adapter-duplicate-key.json'
    [IO.File]::WriteAllText($duplicatePath,'{"schema_version":"thin-harness-exact-head-engineering-evidence/v1","schema_version":"duplicate"}',[Text.UTF8Encoding]::new($false))
    $duplicateGate=New-Gate -Source $source -Path $duplicatePath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $duplicateGate).success) 'G00 Adapter rejects duplicate JSON keys' 'G00 Adapter accepted duplicate JSON keys'
    $digestBadPath=Join-Path $temp 'adapter-report-digest.json';$digestBad=Copy-Document $formalPass;$digestBad.report_digest='sha256:'+('3'*64);Write-Document $digestBadPath $digestBad -Compress
    $digestBadGate=New-Gate -Source $source -Path $digestBadPath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $digestBadGate).success) 'G00 Adapter rejects report_digest mismatch' 'G00 Adapter accepted report_digest mismatch'

    $hardlinkAlias=Join-Path $temp 'adapter-hardlink.json'
    $hardlinkOutput=@(& fsutil hardlink create $hardlinkAlias $formalPassPath 2>&1|ForEach-Object{[string]$_})
    if($LASTEXITCODE-ne0){throw "hardlink fixture setup failed: $($hardlinkOutput-join' | ')"}
    $hardlinkGate=New-Gate -Source $source -Path $hardlinkAlias
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $hardlinkGate).success) 'G00 Adapter rejects a multiply-linked Artifact' 'G00 Adapter accepted a multiply-linked Artifact'
    $adsPath=Join-Path $temp 'adapter-ads.json';[IO.File]::Copy($formalFailPath,$adsPath,$false);Set-Content -LiteralPath $adsPath -Stream hidden -Value sentinel -Encoding utf8NoBOM
    $adsGate=New-Gate -Source $source -Path $adsPath
    Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $adsGate).success) 'G00 Adapter rejects alternate data streams' 'G00 Adapter accepted alternate data streams'
    $reparseTarget=Join-Path $temp 'adapter-reparse-target';[void][IO.Directory]::CreateDirectory($reparseTarget);[IO.File]::Copy($formalFailPath,(Join-Path $reparseTarget 'report.json'),$false)
    $reparseAlias=Join-Path $temp 'adapter-reparse-alias';[void](New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget -ErrorAction Stop)
    try {
        $reparseGate=New-Gate -Source $source -Path (Join-Path $reparseAlias 'report.json')
        Check (-not (Invoke-Gate -Module $subjectModule -Root $subject -Source $source -Gates $reparseGate).success) 'G00 Adapter rejects a reparse path' 'G00 Adapter accepted a reparse path'
    } finally { Remove-Item -LiteralPath $reparseAlias -Force }

    Check-ProducerResultFalse $fixture $subject 'closed PR' 'pr_open' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.state='closed'}}
    Check-ProducerResultFalse $fixture $subject 'draft=false PR' 'pr_draft' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.draft=$false}}
    Check-ProducerResultFalse $fixture $subject 'merged PR' 'pr_unmerged' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.merged=$true}}
    Check-ProducerResultFalse $fixture $subject 'wrong PR number' 'exact_base' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.number=3}}
    Check-ProducerResultFalse $fixture $subject 'wrong base ref' 'exact_base' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.base.ref='main'}}
    Check-ProducerResultFalse $fixture $subject 'wrong head ref' 'exact_head' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.head.ref='main'}}
    Check-ProducerResultFalse $fixture $subject 'Workflow head mismatch' 'exact_head' {param($r)Update-Json (Join-Path $r 'workflow-run.json') {param($d)$d.head_sha='0'*40}}
    Check-ProducerResultFalse $fixture $subject 'Workflow conclusion failure' 'ordinary_jobs_passed' {param($r)Update-Json (Join-Path $r 'workflow-run.json') {param($d)$d.conclusion='failure'}}
    Check-ProducerResultFalse $fixture $subject 'ordinary Job skipped' 'ordinary_jobs_passed' {param($r)Update-Json (Join-Path $r 'workflow-jobs.json') {param($d)$d.jobs[0].conclusion='skipped'}}
    Check-ProducerResultFalse $fixture $subject 'Release Job counted as pass' 'release_jobs_not_counted_as_pass' {param($r)Update-Json (Join-Path $r 'workflow-jobs.json') {param($d)$d.jobs[7].conclusion='success'}}
    Check-ProducerResultFalse $fixture $subject 'read_only=false Review' 'review_read_only' {param($r)$d=Get-ReviewReceipt $r;$d.read_only=$false;Set-ReviewReceipt $r $d}
    Check-ProducerResultFalse $fixture $subject 'reviewer_participated=true Review' 'review_independent' {param($r)$d=Get-ReviewReceipt $r;$d.reviewer_participated=$true;Set-ReviewReceipt $r $d}
    Check-ProducerResultFalse $fixture $subject 'non-pass Review verdict' 'review_verdict_pass' {param($r)$d=Get-ReviewReceipt $r;$d.verdict='fail';Set-ReviewReceipt $r $d}
    Check-ProducerResultFalse $fixture $subject 'P0 Review finding' 'review_findings_clear' {param($r)$d=Get-ReviewReceipt $r;$d.findings.p0=1;Set-ReviewReceipt $r $d}
    Check-ProducerResultFalse $fixture $subject 'P1 Review finding' 'review_findings_clear' {param($r)$d=Get-ReviewReceipt $r;$d.findings.p1=1;Set-ReviewReceipt $r $d}
    Check-ProducerResultFalse $fixture $subject 'P2 Review finding' 'review_findings_clear' {param($r)$d=Get-ReviewReceipt $r;$d.findings.p2=1;Set-ReviewReceipt $r $d}

    Check-ProducerRejects $fixture $subject 'stale base SHA' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.base.sha='0'*40}}
    Check-ProducerRejects $fixture $subject 'stale head SHA' {param($r)Update-Json (Join-Path $r 'pull-request.json') {param($d)$d.head.sha='1'*40}}
    Check-ProducerRejects $fixture $subject 'missing ordinary Job' {param($r)Update-Json (Join-Path $r 'workflow-jobs.json') {param($d)$d.jobs=@($d.jobs|Where-Object name -cne 'changed-optional');$d.total_count=9}}
    Check-ProducerRejects $fixture $subject 'missing Receipt Artifact' {param($r)Update-Json (Join-Path $r 'workflow-artifacts.json') {param($d)$d.artifacts=@($d.artifacts|Select-Object -Skip 1);$d.total_count=6}}
    Check-ProducerRejects $fixture $subject 'duplicate Receipt Artifact' {param($r)Update-Json (Join-Path $r 'workflow-artifacts.json') {param($d)$d.artifacts+=Copy-Document $d.artifacts[0];$d.total_count=8}}
    Check-ProducerRejects $fixture $subject 'missing Receipt file' {param($r)[IO.File]::Delete((Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json'))}
    Check-ProducerRejects $fixture $subject 'wrong Receipt run ID' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.run_id='9002'}}
    Check-ProducerRejects $fixture $subject 'wrong Receipt attempt' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.run_attempt=2}}
    Check-ProducerRejects $fixture $subject 'wrong Receipt base' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.base_sha='0'*40}}
    Check-ProducerRejects $fixture $subject 'wrong Receipt head' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.head_sha='0'*40}}
    Check-ProducerRejects $fixture $subject 'wrong checkout SHA' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.checkout_sha='0'*40}}
    Check-ProducerRejects $fixture $subject 'wrong Receipt Job identity' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.job_id='pr-core'}}
    Check-ProducerRejects $fixture $subject 'wrong Receipt check identity' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.check_name='core-rollback'}}
    Check-ProducerRejects $fixture $subject 'Receipt outcome failure' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d.outcome='failure'}}
    Check-ProducerRejects $fixture $subject 'Receipt unknown field' {param($r)Update-Json (Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json') {param($d)$d['unexpected']='value'}}
    Check-ProducerRejects $fixture $subject 'Receipt Set digest mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.receipt_set_digest='sha256:'+('0'*64);Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'stale Review Head' {param($r)$d=Get-ReviewReceipt $r;$d.head_sha='0'*40;Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'Review Base mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.base_sha='0'*40;Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'Review Run mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.ci_run_id='9002';Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'Review attempt mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.ci_run_attempt=2;Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'Review Diff digest mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.reviewed_diff_digest='sha256:'+('0'*64);Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'Review Diff bytes mismatch' {param($r)$d=Get-ReviewReceipt $r;$d.reviewed_diff_bytes=[long]$d.reviewed_diff_bytes+1;Set-ReviewReceipt $r $d}
    Check-ProducerRejects $fixture $subject 'malformed Review JSON' {param($r)$p=Join-Path $r 'review-comment.json';$d=Get-Content $p -Raw|ConvertFrom-Json -AsHashtable -DateKind String;$f=([string]([char]96))*3;$d.body=$f+'json'+[Environment]::NewLine+'{'+[Environment]::NewLine+$f;Write-Document $p $d -Compress}
    Check-ProducerRejects $fixture $subject 'ambiguous Review Receipts' {param($r)$d=Get-ReviewReceipt $r;Set-ReviewReceipt $r $d -Duplicate}
    Check-ProducerRejects $fixture $subject 'Receipt UTF-8 BOM' {param($r)$p=Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json';[IO.File]::WriteAllBytes($p,[Text.UTF8Encoding]::new($true).GetPreamble()+[IO.File]::ReadAllBytes($p))}
    Check-ProducerRejects $fixture $subject 'duplicate Receipt JSON key' {param($r)$p=Join-Path $r 'artifacts\1001\ordinary-ci-receipt.json';[IO.File]::WriteAllText($p,'{"schema_version":"one","schema_version":"two"}',[Text.UTF8Encoding]::new($false))}

    $formalFixtureOutput = Join-Path $temp 'formal-fixture-rejected.json'
    $formalFixtureResult = Invoke-Producer -SubjectRoot $subject -FixtureRoot $fixture -OutputPath $formalFixtureOutput -Mode formal
    Check ($formalFixtureResult.exit_code -ne 0 -and $null -eq $formalFixtureResult.document) 'formal Producer rejects GitHubFixtureRoot instead of treating Fixture as authority' 'formal Producer accepted GitHubFixtureRoot'
    $missingFixtureOutput = Join-Path $temp 'test-only-without-fixture.json'
    $missingFixtureResult = Invoke-Producer -SubjectRoot $subject -FixtureRoot $fixture -OutputPath $missingFixtureOutput -OmitFixture
    Check ($missingFixtureResult.exit_code -ne 0 -and $null -eq $missingFixtureResult.document) 'test-only Producer requires an explicit sanitized Fixture root' 'test-only Producer ran without a Fixture root'

    $producerSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\generate-exact-head-engineering-evidence.ps1') -Raw -Encoding utf8
    $moduleSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Raw -Encoding utf8
    Check ($producerSource -match 'RepositoryFullName' -and $producerSource -match 'PullRequestNumber' -and $producerSource -match 'RunId' -and $producerSource -match 'ReviewCommentId' -and
        $producerSource -notmatch 'PullRequestState|DraftState|MergedState|BaseSha|HeadSha|WorkflowConclusion|ArtifactId|ReviewBody' -and
        $moduleSource -match "ProducerMode -ceq 'formal'" -and $moduleSource -match 'Invoke-ExactHeadGitHubJson' -and $moduleSource -match "'api',") 'formal Producer re-reads GitHub authority and exposes no caller-supplied state inputs' 'formal Producer accepts caller authority or lacks GitHub API re-read'
    $runtimeReaders=@('scripts/task.ps1','scripts/lib/Harness.Recovery.psm1','scripts/lib/Harness.RuntimeDefault.psm1')
    Check (@($runtimeReaders|Where-Object{(Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding utf8)-match'exact-head-engineering-evidence'}).Count -eq 0) 'Runtime Core, Status, and Runtime Default do not read G00 reports' 'a Runtime path began reading G00 qualification evidence'
    $workflowReaders=@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.github\workflows') -File -Filter '*.yml'|Where-Object{(Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8)-match'generate-exact-head-engineering-evidence|exact-head-engineering-evidence'})
    Check ($workflowReaders.Count -eq 0) 'Release Workflow remains unwired for formal G00 production' 'a Workflow began producing or consuming formal G00 evidence'

    $unwiredPath=Join-Path $temp 'still-unwired.json';Write-Document $unwiredPath ([ordered]@{}) -Compress
    foreach($unwiredName in @('DP-G11-RELEASE-FULL')){
        $unwiredGate=[ordered]@{};$unwiredGate[$unwiredName]=[ordered]@{status='pass';evidence_contract='fixture/v1';artifact_path=$unwiredPath;evidence_digest=(Get-FileDigest $unwiredPath);source_revision=[string]$source.revision;producer_identity='fixture'}
        $reason='';try{& $subjectModule {param($Root,$Source,$Gates)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates} $subject $source $unwiredGate}catch{$reason=[string]$_.Exception.Message}
        Check ($reason-ceq"rollout-evidence-provenance-unwired-$unwiredName") "$unwiredName remains provenance-unwired" "$unwiredName was silently wired"
    }
} finally {
    Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
