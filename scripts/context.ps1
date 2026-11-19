#requires -Version 7.3
[CmdletBinding()]
param(
    [Parameter(Position=0,Mandatory)][ValidateSet('recall','read')][string]$Command,
    [string]$Query = '',
    [string]$Ref = '',
    [string]$WorkspaceRoot = '',
    [switch]$IncludeSessions,
    [string]$CodexHome = '',
    [ValidateRange(1,50)][int]$Limit = 6,
    [ValidateRange(1,20000)][int]$Budget = 2400
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Harness.Hashing.psm1') -Force
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$timer = [Diagnostics.Stopwatch]::StartNew()
$diagnostics = [Collections.Generic.List[object]]::new()
function Get-ContextPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\?\')) { $full = $full.Substring(4) }
    return [IO.Path]::TrimEndingDirectorySeparator($full)
}
if (!$WorkspaceRoot) {
    $WorkspaceRoot = if ($env:DEV_HARNESS_WORKSPACE_ROOT) { $env:DEV_HARNESS_WORKSPACE_ROOT } elseif ($env:WORKSPACE_ROOT) { $env:WORKSPACE_ROOT } else { (Get-Location).Path }
}
$WorkspaceRoot = Get-ContextPath (Resolve-Path -LiteralPath $WorkspaceRoot).Path
if (!$CodexHome) { $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' } }

function Get-ContextItems([string]$Path, [string]$Kind, [int]$OnlyLine = 0) {
    if ($Kind -eq 'document') {
        $text = [IO.File]::ReadAllText($Path)
        $status = 'current'; $successor = ''
        $frontmatter = [regex]::Match($text, '\A---\r?\n(?<body>[\s\S]*?)\r?\n---(?:\r?\n|$)')
        if ($frontmatter.Success) {
            foreach ($line in $frontmatter.Groups['body'].Value -split '\r?\n') {
                if ($line -match '^status:\s*superseded\s*$') { $status = 'superseded' }
                if ($line -match '^superseded_by:\s*(.+?)\s*$') { $successor = $Matches[1].Trim('"',"'"); $status = 'superseded' }
            }
        }
        [pscustomobject]@{ path=$Path; kind=$Kind; line=1; text=$text; status=$status; superseded_by=$successor; score=0; match_index=0 }
        return
    }

    # Only user/assistant messages from this workspace; never tool output or analysis.
    # Codex appends to active transcripts; allow its writer while taking a read-only view.
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try {
        $first = $reader.ReadLine()
        if (!$first) { $diagnostics.Add(@{path=$Path;status='empty';message='No session metadata or messages'}); return }
        $metadata = ConvertFrom-Json -InputObject $first -AsHashtable
        if ($metadata.type -ne 'session_meta') { throw "Missing Codex session_meta: $Path" }
        if ((Get-ContextPath ([string]$metadata.payload.cwd)) -ine $WorkspaceRoot) { return }
        $lineNumber = 1
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($OnlyLine -and $lineNumber -ne $OnlyLine) { continue }
            $record = ConvertFrom-Json -InputObject $line -AsHashtable
            if ($record.type -ne 'response_item') { continue }
            $message = $record.payload
            if ($message.type -ne 'message' -or $message.role -notin @('user','assistant') -or $message['channel'] -eq 'analysis') { continue }
            $text = (@($message.content | Where-Object { $_.type -in @('input_text','output_text') } | ForEach-Object { $_.text }) -join "`n")
            if ($text) { [pscustomobject]@{ path=$Path; kind=$Kind; line=$lineNumber; text=$text; status='historical'; superseded_by=''; score=0; match_index=0 } }
            if ($OnlyLine) { break }
        }
    } finally { $reader.Dispose() }
}

# rg respects project ignore files; runtime/current state and dependency trees are not sources.
$paths = @(& rg --files --hidden -g '!**/.git/**' -g '!**/.assistant/**' -g '!**/node_modules/**' -g '!**/tmp/**' -- $WorkspaceRoot)
if ($LASTEXITCODE -gt 1) { throw "Document enumeration failed: rg exit $LASTEXITCODE" }
$sources = [ordered]@{}
foreach ($path in $paths) { if ([IO.Path]::GetExtension($path) -ieq '.md') { $sources[(Get-ContextPath $path)] = 'document' } }
foreach ($relative in @('AGENTS.md','CLAUDE.md','PROJECT.md','.assistant/MEMORY.md')) {
    $memoryPath = Join-Path $WorkspaceRoot $relative
    if (Test-Path -LiteralPath $memoryPath -PathType Leaf) { $sources[$memoryPath] = 'document' }
}
if ($IncludeSessions) {
    foreach ($directory in @('sessions','archived_sessions')) {
        $sessionRoot = Join-Path $CodexHome $directory
        if (!(Test-Path -LiteralPath $sessionRoot -PathType Container)) { continue }
        $sessionPaths = @(& rg --files --hidden --no-ignore -g '*.jsonl' -- $sessionRoot)
        if ($LASTEXITCODE -gt 1) { throw "Session enumeration failed: rg exit $LASTEXITCODE" }
        foreach ($path in $sessionPaths) { $sources[(Get-ContextPath $path)] = 'codex' }
    }
}

if ($Command -eq 'read') {
    if (!$Ref.StartsWith('ctx:')) { throw 'read requires a ctx: reference returned by recall' }
    $reference = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Ref.Substring(4))) | ConvertFrom-Json -AsHashtable
    if (!$sources.Contains([string]$reference.path) -or $sources[[string]$reference.path] -ne $reference.kind) { throw 'Reference is outside the selected sources; session references require -IncludeSessions' }
    $items = @(Get-ContextItems -Path $reference.path -Kind $reference.kind -OnlyLine $reference.line)
    if ($items.Count -ne 1 -or (Get-HarnessUtf8TextSha256 -Text $items[0].text).Substring(7) -cne $reference.digest) { throw 'Source changed or reference is invalid; run recall again' }
    [ordered]@{ command='read'; path=$reference.path; line=$reference.line; kind=$reference.kind; authority='advisory'; text=$items[0].text } | ConvertTo-Json -Depth 8
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Query)) { throw 'recall requires -Query' }
$terms = @([regex]::Matches($Query.ToLowerInvariant(), '[\p{L}\p{Nd}_-]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
if (!$terms.Count) { throw 'Query must contain a word or a number' }
$documents = @{}; $candidates = [Collections.Generic.List[object]]::new()
foreach ($source in $sources.GetEnumerator()) {
    foreach ($item in Get-ContextItems -Path $source.Key -Kind $source.Value) {
        if ($item.kind -eq 'document') { $documents[$item.path] = $item }
        $searchText = $item.text.ToLowerInvariant()
        $firstMatch = [int]::MaxValue
        foreach ($term in $terms) {
            $index = $searchText.IndexOf($term, [StringComparison]::Ordinal)
            if ($index -ge 0) { $item.score++; $firstMatch = [Math]::Min($firstMatch,$index) }
        }
        if ($item.score) {
            if ($searchText.Contains($Query.ToLowerInvariant())) { $item.score += $terms.Count }
            $item.match_index = $firstMatch
            $candidates.Add($item)
        }
    }
}

# Follow explicitly declared replacements, even when the successor uses different words.
foreach ($candidate in @($candidates.ToArray())) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $current = $candidate
    while ($current.superseded_by) {
        if (!$seen.Add($current.path)) { throw "Cyclic superseded_by: $($candidate.path)" }
        $nextPath = Get-ContextPath (Join-Path $WorkspaceRoot $current.superseded_by)
        if (!$documents.ContainsKey($nextPath)) { throw "superseded_by target is not a project Markdown source: $($current.superseded_by)" }
        $next = $documents[$nextPath]
        $next.score = [Math]::Max($next.score, $candidate.score)
        if (!$candidates.Contains($next)) { $candidates.Add($next) }
        $current = $next
    }
}

$sorted = @($candidates | Sort-Object @{Expression={ if ($_.status -eq 'current') { 0 } elseif ($_.status -eq 'superseded') { 2 } else { 1 } }}, @{Expression='score';Descending=$true}, path, line)
$results = [Collections.Generic.List[object]]::new()
$digests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$used = 0
foreach ($item in $sorted) {
    if ($results.Count -ge $Limit -or $used -ge $Budget) { break }
    $digest = (Get-HarnessUtf8TextSha256 -Text $item.text).Substring(7)
    if (!$digests.Add($digest)) { continue }
    $available = [Math]::Min(400, $Budget - $used)
    $start = [Math]::Max(0, $item.match_index - [Math]::Min(100,[int]($available / 4)))
    $length = [Math]::Min($available, $item.text.Length - $start)
    $excerpt = $item.text.Substring($start,$length)
    $line = if ($item.kind -eq 'document') { 1 + [regex]::Matches($item.text.Substring(0,$start), "`n").Count } else { $item.line }
    $reference = @{path=$item.path;kind=$item.kind;line=$item.line;digest=$digest} | ConvertTo-Json -Compress
    $results.Add([ordered]@{path=$item.path;line=$line;kind=$item.kind;status=$item.status;superseded_by=$item.superseded_by;excerpt=$excerpt;ref=('ctx:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($reference)))})
    $used += $length
}
[ordered]@{ command='recall'; authority='advisory'; query=$Query; workspace=$WorkspaceRoot; sessions_included=[bool]$IncludeSessions; results=@($results.ToArray()); diagnostics=@($diagnostics.ToArray()); excerpt_chars=$used; budget=$Budget; elapsed_ms=$timer.ElapsedMilliseconds } | ConvertTo-Json -Depth 8
exit 0
