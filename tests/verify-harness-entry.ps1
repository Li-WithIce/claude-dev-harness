[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments,
        [string]$WorkingDirectory = ''
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLocation = $null
    try {
        $env:USERPROFILE = $UserProfile
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $ScriptPath @Arguments 2>&1)
        $scriptSucceeded = $?
        return [pscustomobject]@{
            Output   = $output
            ExitCode = if ($scriptSucceeded) { 0 } elseif ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 1 }
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }

        $env:USERPROFILE = $originalUserProfile
    }
}

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Invoke-GitChecked {
    param([string[]]$Arguments,[string]$Label)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} failed: {1}" -f $Label, ($output -join [Environment]::NewLine))
    }
    return @($output)
}

function Normalize-ContractText {
    param([string]$Text)

    return ([regex]::Replace($Text, "`r`n?", "`n")).TrimEnd([char[]]"`n")
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$scratchRoot = Join-Path $RepoRoot ('tmp\harness-entry-regression-' + [guid]::NewGuid().ToString('N'))

$harnessPath = Join-Path $RepoRoot 'harness.ps1'
$entryContractPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$entryContractContent = Get-Content -LiteralPath $entryContractPath -Raw -Encoding utf8
$entryContractDigest = (Get-FileHash -LiteralPath $entryContractPath -Algorithm SHA256).Hash.ToLowerInvariant()

try {
New-Item -ItemType Directory -Path $scratchRoot | Out-Null

# Case 1: bootstrap from a subdirectory inside a fresh git workspace.
$caseRoot = Join-Path $scratchRoot 'bootstrap-from-git-ancestor'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot 'src\module'
New-Item -ItemType Directory -Path $userProfile,$workingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $workspaceRoot '.git') -Force | Out-Null

$bootstrapResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $workingDirectory

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'STATUS') -ne 'PASS') {
    Add-Failure 'harness.ps1 should bootstrap a fresh workspace when run from a project subdirectory'
} else {
    Add-Check 'harness.ps1 bootstraps a fresh workspace from a project subdirectory'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
    Add-Failure 'harness.ps1 should report bootstrap-workspace mode for a fresh workspace'
} else {
    Add-Check 'harness.ps1 reports bootstrap-workspace mode for a fresh workspace'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'WorkspaceRoot') -ne $workspaceRoot) {
    Add-Failure 'harness.ps1 should infer the git ancestor as WorkspaceRoot during bootstrap'
} else {
    Add-Check 'harness.ps1 infers the git ancestor as WorkspaceRoot during bootstrap'
}

if (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant') -PathType Container)) {
    Add-Failure 'harness.ps1 should create .assistant during bootstrap'
} else {
    Add-Check 'harness.ps1 creates .assistant during bootstrap'
}

$entryShimPath = Join-Path $workspaceRoot '.assistant\entry\AGENTS.md'
if (-not (Test-Path -LiteralPath $entryShimPath -PathType Leaf)) {
    Add-Failure 'harness.ps1 should install the workspace entry shim'
} else {
    $entryShimContent = Get-Content -LiteralPath $entryShimPath -Raw -Encoding utf8
    $contractPattern = '(?ms)^<!-- BEGIN GENERATED ENTRY CONTRACT -->\r?\n<!-- source-sha256: (?<digest>[0-9a-f]{64}) -->\r?\n(?<body>.*?)\r?\n<!-- END GENERATED ENTRY CONTRACT -->$'
    $contractMatches = [regex]::Matches($entryShimContent, $contractPattern)
    if ($contractMatches.Count -ne 1) {
        Add-Failure 'workspace entry shim should contain exactly one generated entry contract block'
    } else {
        Add-Check 'workspace entry shim contains exactly one generated entry contract block'
        $contractMatch = $contractMatches[0]
        if ($contractMatch.Groups['digest'].Value -cne $entryContractDigest) {
            Add-Failure 'workspace entry shim generated entry contract digest should match the canonical source'
        } else {
            Add-Check 'workspace entry shim generated entry contract digest matches the canonical source'
        }

        if ((Normalize-ContractText -Text $contractMatch.Groups['body'].Value) -cne (Normalize-ContractText -Text $entryContractContent)) {
            Add-Failure 'workspace entry shim generated entry contract body should match the canonical source'
        } else {
            Add-Check 'workspace entry shim generated entry contract body matches the canonical source'
        }
    }

    $vaultPath = Join-Path $workspaceRoot '.assistant'
    if ($entryShimContent.Contains('Stage advance: `pwsh -File .assistant\entry\advance-stage.ps1') -and
        $entryShimContent.Contains($RepoRoot) -and
        $entryShimContent.Contains($vaultPath) -and
        $entryShimContent.Contains('`TEST -> DONE`') -and
        -not $entryShimContent.Contains('{REPO_ROOT}') -and
        -not $entryShimContent.Contains('{VAULT_PATH}')) {
        Add-Check 'workspace entry shim preserves the rendered v1 host overlay'
    } else {
        Add-Failure 'workspace entry shim should preserve the rendered v1 host overlay'
    }
}
if (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant\工作流') -PathType Container) {
    Add-Failure 'harness.ps1 should use minimal vault profile for a fresh workspace by default'
} else {
    Add-Check 'harness.ps1 uses minimal vault profile for a fresh workspace by default'
}

# Case 2: auto vault detection should not treat one weak marker as an existing full vault.
$caseRoot = Join-Path $scratchRoot 'auto-ignores-weak-vault-marker'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
New-Item -ItemType Directory -Path $userProfile,(Join-Path $workspaceRoot '.assistant\配置') -Force | Out-Null

$weakMarkerInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($weakMarkerInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed when only one weak full-vault marker exists'
} elseif (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant\工作流') -PathType Container) {
    Add-Failure 'auto vault detection should keep a workspace with only .assistant\配置 on minimal profile'
} else {
    Add-Check 'auto vault detection ignores a single weak full-vault marker'
}

# Case 3: update an existing workspace from a descendant path and repair managed drift.
$caseRoot = Join-Path $scratchRoot 'update-existing-workspace'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot '.assistant'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
    VaultProfile  = 'full'
}

if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the harness update regression runs'
} else {
    $sharedMemoryProtocolLeaf = [string]::Concat(([int[]](20849,20139,35760,24518,21327,35758,46,109,100) | ForEach-Object { [char]$_ }))
    $protocolPath = @(Get-ChildItem -LiteralPath (Join-Path $workspaceRoot '.assistant') -Recurse -File | Where-Object {
            $_.Name -eq $sharedMemoryProtocolLeaf
        } | Select-Object -First 1)

    if ($protocolPath.Count -ne 1) {
        Add-Failure 'unable to resolve managed protocol file inside the installed workspace'
    } else {
        Add-Content -LiteralPath $protocolPath[0].FullName -Value "`nLOCAL-DRIFT" -Encoding utf8

        $updateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
            RepoRoot = $RepoRoot
        } -WorkingDirectory $workingDirectory

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'STATUS') -ne 'PASS') {
            Add-Failure 'harness.ps1 should update an existing workspace when run below the workspace root'
        } else {
            Add-Check 'harness.ps1 updates an existing workspace when run below the workspace root'
        }

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'Mode') -ne 'update-existing-workspace') {
            Add-Failure 'harness.ps1 should report update-existing-workspace mode for an installed workspace'
        } else {
            Add-Check 'harness.ps1 reports update-existing-workspace mode for an installed workspace'
        }

        $protocolContent = Get-Content -LiteralPath $protocolPath[0].FullName -Raw -Encoding utf8
        if ($protocolContent.Contains('LOCAL-DRIFT')) {
            Add-Failure 'harness.ps1 should repair managed workspace drift through update-managed-assets'
        } else {
            Add-Check 'harness.ps1 repairs managed workspace drift through update-managed-assets'
        }
    }
}

# Case 4: a git submodule (.git is a gitlink file) inside an installed workspace stays part of the parent.
$caseRoot = Join-Path $scratchRoot 'submodule-stays-in-parent'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$submoduleRepo = Join-Path $workspaceRoot 'vendor\submodule'
$submoduleWorking = Join-Path $submoduleRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$submoduleInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($submoduleInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the submodule regression runs'
} else {
    $submoduleSource = Join-Path $caseRoot 'submodule-source'
    $submoduleSourceFile = Join-Path $submoduleSource 'src\source.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $submoduleSourceFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($submoduleSourceFile,"submodule`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'init','--quiet') -Label 'submodule source init')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'config','user.email','harness@example.invalid') -Label 'submodule source email config')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'config','user.name','Harness') -Label 'submodule source name config')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'add','.') -Label 'submodule source add')
    [void](Invoke-GitChecked -Arguments @('-C',$submoduleSource,'commit','--quiet','-m','source') -Label 'submodule source commit')

    $parentAnchor = Join-Path $workspaceRoot 'parent.txt'
    [System.IO.File]::WriteAllText($parentAnchor,"parent`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'init','--quiet') -Label 'submodule parent init')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.email','harness@example.invalid') -Label 'submodule parent email config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.name','Harness') -Label 'submodule parent name config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'add','parent.txt') -Label 'submodule parent add')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'commit','--quiet','-m','parent') -Label 'submodule parent commit')
    [void](Invoke-GitChecked -Arguments @('-c','protocol.file.allow=always','-C',$workspaceRoot,'submodule','add','--quiet',$submoduleSource.Replace('\','/'),'vendor/submodule') -Label 'submodule add')

    $submoduleResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $submoduleWorking

    if ((Get-StatusLineValue -Output $submoduleResult.Output -Prefix 'WorkspaceRoot') -ne $workspaceRoot) {
        Add-Failure 'harness.ps1 should resolve a submodule to the parent installed workspace, not its gitlink root'
    } else {
        Add-Check 'harness.ps1 keeps a git submodule (.git file) inside the parent installed workspace'
    }

    if ((Get-StatusLineValue -Output $submoduleResult.Output -Prefix 'Mode') -ne 'update-existing-workspace') {
        Add-Failure 'harness.ps1 should report update-existing-workspace mode for a submodule under an installed workspace'
    } else {
        Add-Check 'harness.ps1 treats a submodule as content of the parent workspace'
    }

    if (Test-Path -LiteralPath (Join-Path $submoduleRepo '.assistant') -PathType Container) {
        Add-Failure 'harness.ps1 should not bootstrap a new .assistant inside a submodule without explicit -WorkspaceRoot'
    } else {
        Add-Check 'harness.ps1 does not split a submodule into its own workspace'
    }
}

# Case 5: a linked worktree inside an installed workspace bootstraps without inheriting parent task authority.
$caseRoot = Join-Path $scratchRoot 'linked-worktree-isolated'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$linkedWorktree = Join-Path $workspaceRoot '.worktrees\feature'
$linkedWorking = Join-Path $linkedWorktree 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$worktreeInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($worktreeInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the linked-worktree regression runs'
} else {
    $parentAnchor = Join-Path $workspaceRoot 'parent.txt'
    [System.IO.File]::WriteAllText($parentAnchor,"parent`n",[System.Text.UTF8Encoding]::new($false))
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'init','--quiet') -Label 'worktree parent init')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.email','harness@example.invalid') -Label 'worktree parent email config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'config','user.name','Harness') -Label 'worktree parent name config')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'add','parent.txt') -Label 'worktree parent add')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'commit','--quiet','-m','parent') -Label 'worktree parent commit')
    [void](Invoke-GitChecked -Arguments @('-C',$workspaceRoot,'worktree','add','--quiet','-b','feature',$linkedWorktree,'HEAD') -Label 'linked worktree add')
    New-Item -ItemType Directory -Path $linkedWorking -Force | Out-Null

    $parentSentinels = [ordered]@{
        '.assistant\runtime\current.json' = '{"parent":"current"}'
        '.assistant\runtime\tasks\parent-task\task.json' = '{"parent":"task"}'
        '.assistant\runtime\tasks\parent-task\approvals\apr_parent.json' = '{"parent":"approval"}'
    }
    $parentSentinelBytes = [ordered]@{}
    foreach ($relativePath in $parentSentinels.Keys) {
        $target = Join-Path $workspaceRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$parentSentinels[$relativePath])
        [System.IO.File]::WriteAllBytes($target,$bytes)
        $parentSentinelBytes[$relativePath] = $bytes
    }

    $gitEnvironmentNames = @('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR')
    $savedGitEnvironment = [ordered]@{}
    $presentGitEnvironment = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $gitEnvironmentNames) {
        if (Test-Path -LiteralPath "Env:$name") {
            [void]$presentGitEnvironment.Add($name)
            $savedGitEnvironment[$name] = (Get-Item -LiteralPath "Env:$name").Value
        }
    }
    try {
        $env:GIT_DIR = Join-Path $workspaceRoot '.git'
        $env:GIT_WORK_TREE = $workspaceRoot
        $env:GIT_COMMON_DIR = Join-Path $workspaceRoot '.git'
        $worktreeResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
            RepoRoot = $RepoRoot
            SkipStatus = $true
        } -WorkingDirectory $linkedWorking
    } finally {
        foreach ($name in $gitEnvironmentNames) {
            if ($presentGitEnvironment.Contains($name)) {
                Set-Item -LiteralPath "Env:$name" -Value ([string]$savedGitEnvironment[$name])
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }

    if ((Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'STATUS') -ne 'PASS' -or
        (Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'WorkspaceRoot') -ne $linkedWorktree -or
        (Get-StatusLineValue -Output $worktreeResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
        Add-Failure 'harness.ps1 should bootstrap the linked worktree as an isolated workspace'
    } else {
        Add-Check 'harness.ps1 bootstraps a linked worktree as an isolated workspace despite inherited Git repository variables'
    }

    $parentUnchanged = $true
    $worktreeDidNotCopy = $true
    foreach ($relativePath in $parentSentinels.Keys) {
        $parentPath = Join-Path $workspaceRoot $relativePath
        $worktreePath = Join-Path $linkedWorktree $relativePath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Leaf) -or
            ([System.IO.File]::ReadAllBytes($parentPath) -join ',') -cne (@($parentSentinelBytes[$relativePath]) -join ',')) {
            $parentUnchanged = $false
        }
        if (Test-Path -LiteralPath $worktreePath) {
            $worktreeDidNotCopy = $false
        }
    }
    if ($parentUnchanged -and $worktreeDidNotCopy) {
        Add-Check 'linked worktree bootstrap neither changes nor copies parent current, task, or Approval state'
    } else {
        Add-Failure 'linked worktree bootstrap changed or copied parent current, task, or Approval state'
    }
}

# Case 6: an invalid gitfile fails closed instead of inheriting a parent workspace.
$caseRoot = Join-Path $scratchRoot 'invalid-gitfile-fails-closed'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$invalidRepo = Join-Path $workspaceRoot 'projects\invalid'
$invalidWorking = Join-Path $invalidRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$invalidWorking -Force | Out-Null
$invalidInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
if ($invalidInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the invalid-gitfile regression runs'
} else {
    [System.IO.File]::WriteAllText((Join-Path $invalidRepo '.git'),'gitdir: missing',[System.Text.Encoding]::ASCII)
    $invalidResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $invalidWorking
    if ((Get-StatusLineValue -Output $invalidResult.Output -Prefix 'STATUS') -eq 'FAIL' -and
        ($invalidResult.Output -join "`n") -match 'Unable to classify gitfile workspace safely') {
        Add-Check 'harness.ps1 fails closed when Git cannot classify a nested gitfile'
    } else {
        Add-Failure 'harness.ps1 should fail closed when Git cannot classify a nested gitfile'
    }
}

# Case 7: an independent nested repo (.git is a directory) under an installed workspace still bootstraps its own workspace.
$caseRoot = Join-Path $scratchRoot 'independent-nested-repo'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$nestedRepo = Join-Path $workspaceRoot 'projects\nested'
$nestedWorking = Join-Path $nestedRepo 'src'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$nestedInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($nestedInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the independent-nested-repo regression runs'
} else {
    New-Item -ItemType Directory -Path (Join-Path $nestedRepo '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path $nestedWorking -Force | Out-Null

    $nestedResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
    } -WorkingDirectory $nestedWorking

    if ((Get-StatusLineValue -Output $nestedResult.Output -Prefix 'WorkspaceRoot') -ne $nestedRepo) {
        Add-Failure 'harness.ps1 should bootstrap an independent nested repo (.git directory) at its own git root'
    } else {
        Add-Check 'harness.ps1 bootstraps an independent nested repo (.git directory) at its own git root'
    }

    if ((Get-StatusLineValue -Output $nestedResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
        Add-Failure 'harness.ps1 should report bootstrap-workspace mode for an independent nested repo'
    } else {
        Add-Check 'harness.ps1 reports bootstrap-workspace mode for an independent nested repo'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $nestedRepo '.assistant') -PathType Container)) {
        Add-Failure 'harness.ps1 should create .assistant when bootstrapping an independent nested repo'
    } else {
        Add-Check 'harness.ps1 creates a separate workspace for an independent nested repo'
    }
}

# Case 8: an independent nested repo with a separate git directory bootstraps its own workspace.
$caseRoot = Join-Path $scratchRoot 'separate-git-dir-isolated'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$nestedRepo = Join-Path $workspaceRoot 'projects\nested'
$nestedWorking = Join-Path $nestedRepo 'src'
$separateGitDirectory = Join-Path $caseRoot 'git-dirs\nested.git'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$separateInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($separateInstall.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the separate-git-dir regression runs'
} else {
    $parentSentinels = [ordered]@{
        '.assistant\runtime\current.json' = '{"parent":"current"}'
        '.assistant\runtime\tasks\parent-task\task.json' = '{"parent":"task"}'
        '.assistant\runtime\tasks\parent-task\approvals\apr_parent.json' = '{"parent":"approval"}'
    }
    $parentSentinelBytes = [ordered]@{}
    foreach ($relativePath in $parentSentinels.Keys) {
        $target = Join-Path $workspaceRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$parentSentinels[$relativePath])
        [System.IO.File]::WriteAllBytes($target,$bytes)
        $parentSentinelBytes[$relativePath] = $bytes
    }

    New-Item -ItemType Directory -Path $nestedWorking,(Split-Path -Parent $separateGitDirectory) -Force | Out-Null
    [void](Invoke-GitChecked -Arguments @('init','--quiet',("--separate-git-dir=$separateGitDirectory"),$nestedRepo) -Label 'separate-git-dir init')
    if (-not (Test-Path -LiteralPath (Join-Path $nestedRepo '.git') -PathType Leaf)) {
        Add-Failure 'separate-git-dir fixture should create a .git file'
    }

    $separateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
        RepoRoot = $RepoRoot
        SkipStatus = $true
    } -WorkingDirectory $nestedWorking

    if ((Get-StatusLineValue -Output $separateResult.Output -Prefix 'STATUS') -eq 'PASS' -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'WorkspaceRoot') -eq $nestedRepo -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'WorkspaceRootSource') -eq 'git-ancestor' -and
        (Get-StatusLineValue -Output $separateResult.Output -Prefix 'Mode') -eq 'bootstrap-workspace' -and
        (Test-Path -LiteralPath (Join-Path $nestedRepo '.assistant') -PathType Container)) {
        Add-Check 'harness.ps1 treats a separate-git-dir repository as independent, not as a submodule'
    } else {
        Add-Failure 'harness.ps1 should bootstrap a separate-git-dir repository as an independent workspace'
    }

    $parentUnchanged = $true
    $nestedDidNotCopy = $true
    foreach ($relativePath in $parentSentinels.Keys) {
        $parentPath = Join-Path $workspaceRoot $relativePath
        $nestedPath = Join-Path $nestedRepo $relativePath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Leaf) -or
            ([System.IO.File]::ReadAllBytes($parentPath) -join ',') -cne (@($parentSentinelBytes[$relativePath]) -join ',')) {
            $parentUnchanged = $false
        }
        if (Test-Path -LiteralPath $nestedPath) {
            $nestedDidNotCopy = $false
        }
    }
    if ($parentUnchanged -and $nestedDidNotCopy) {
        Add-Check 'separate-git-dir bootstrap neither changes nor copies parent task authority'
    } else {
        Add-Failure 'separate-git-dir bootstrap changed or copied parent current, task, or Approval state'
    }
}

# Case 9: running from the repo root without an explicit workspace should fail safely.
$repoRootCase = Join-Path $scratchRoot 'repo-root-guard'
$repoRootUserProfile = Join-Path $repoRootCase 'user'
New-Item -ItemType Directory -Path $repoRootUserProfile -Force | Out-Null

$guardResult = Invoke-RepoScript -UserProfile $repoRootUserProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $RepoRoot

if ((Get-StatusLineValue -Output $guardResult.Output -Prefix 'STATUS') -ne 'FAIL') {
    Add-Failure 'harness.ps1 should fail safely when run from the harness repo root without WorkspaceRoot'
} else {
    Add-Check 'harness.ps1 fails safely when run from the harness repo root without WorkspaceRoot'
}
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
