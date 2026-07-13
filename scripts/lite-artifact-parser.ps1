function Assert-LiteTaskId {
    param([string]$TaskId)

    if (-not (Test-CanonicalRuntimeTaskId -TaskId $TaskId)) {
        throw "TaskId must be a lowercase slug with 1-64 letters, digits, or hyphens and must not be reserved (none, idle, unknown): $TaskId"
    }
}

$runtimeStateCommonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeStateCommonPath -PathType Leaf)) {
    throw "Missing canonical runtime state helper: $runtimeStateCommonPath"
}
. $runtimeStateCommonPath

function Get-LitePlanMutexName {
    param([string]$TaskId)

    Assert-LiteTaskId -TaskId $TaskId
    # ponytail: same task ids serialize across workspaces; add a stable workspace id only if measured contention requires it.
    return "Global\dev-harness.plan-md.$TaskId"
}

function Enter-LitePlanMutex {
    param(
        [string]$TaskId,
        [int]$TimeoutMilliseconds = 5000
    )

    $mutex = New-Object System.Threading.Mutex($false, (Get-LitePlanMutexName -TaskId $TaskId))
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for task plan lock: $TaskId"
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-LitePlanMutex {
    param([System.Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex() | Out-Null
    } finally {
        $Mutex.Dispose()
    }
}

function Write-LiteUtf8BomAtomic {
    param(
        [string]$Path,
        [string]$Content
    )

    Write-CanonicalRuntimeUtf8BomAtomic -Path $Path -Content $Content
}

function Resolve-LiteContainedPath {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$Label = 'path'
    )

    return Resolve-CanonicalRuntimeContainedPath -Root $Root -RelativePath $RelativePath -Label $Label
}

function Get-LiteFrontmatter {
    param([string]$Content)

    $match = [regex]::Match($Content, '\A---\r?\n(.*?)\r?\n---\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw 'missing frontmatter block'
    }

    $fields = [ordered]@{}
    foreach ($line in ($match.Groups[1].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -notmatch '^([a-z_]+):\s*(.+)$') {
            throw "invalid frontmatter line: $line"
        }

        $key = $Matches[1]
        if ($fields.Contains($key)) {
            throw "duplicate frontmatter field: $key"
        }
        $fields[$key] = $Matches[2].Trim()
    }

    return [pscustomobject]@{
        Fields = $fields
        Body = $Content.Substring($match.Length)
    }
}

function Get-LiteVisibleMarkdownText {
    param([string]$Content)

    if ([string]::IsNullOrEmpty($Content)) {
        return ''
    }

    $visible = $Content.ToCharArray()
    $inHtmlComment = $false
    $fenceCharacter = $null
    $fenceLength = 0
    $lines = [regex]::Matches($Content, '(?m)^[^\r\n]*(?:\r\n|\n|\z)')

    foreach ($lineMatch in $lines) {
        if ($lineMatch.Length -eq 0) {
            continue
        }

        $line = [regex]::Replace($lineMatch.Value, '\r?\n\z', '')
        $hideLine = $false
        if ($null -ne $fenceCharacter) {
            $hideLine = $true
            $closingFencePattern = '^ {0,3}' + [regex]::Escape([string]$fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
            if ([regex]::IsMatch($line, $closingFencePattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $fenceCharacter = $null
                $fenceLength = 0
            }
        } elseif ($inHtmlComment) {
            $hideLine = $true
            if ($line.IndexOf('-->', [System.StringComparison]::Ordinal) -ge 0) {
                $inHtmlComment = $false
            }
        } else {
            $openingFence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if ($openingFence.Success) {
                $fenceRun = $openingFence.Groups[1].Value
                $fenceTail = $openingFence.Groups[2].Value
                if ($fenceRun[0] -eq '~' -or $fenceTail.IndexOf('`') -lt 0) {
                    $fenceCharacter = $fenceRun[0]
                    $fenceLength = $fenceRun.Length
                    $hideLine = $true
                }
            }

            if (-not $hideLine) {
                $blockComment = [regex]::Match($line, '^ {0,3}<!--', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
                if ($blockComment.Success) {
                    if ($line.IndexOf('-->', $blockComment.Index + $blockComment.Length, [System.StringComparison]::Ordinal) -lt 0) {
                        $inHtmlComment = $true
                    }
                    $hideLine = $true
                } elseif ($line -match '^ {0,3}<') {
                    throw 'Block-position angle-bracket syntax is not supported in lite task sections; use Markdown links or fenced code'
                }
            }
        }

        if (-not $hideLine) {
            $htmlScanCharacters = $line.ToCharArray()
            foreach ($codeSpan in [regex]::Matches($line, '(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)')) {
                for ($offset = $codeSpan.Index; $offset -lt ($codeSpan.Index + $codeSpan.Length); $offset++) {
                    $htmlScanCharacters[$offset] = ' '
                }
            }
            $htmlScan = -join $htmlScanCharacters
            $commentOffset = 0
            while ($commentOffset -lt $htmlScan.Length) {
                $commentStart = $htmlScan.IndexOf('<!--', $commentOffset, [System.StringComparison]::Ordinal)
                if ($commentStart -lt 0) {
                    break
                }
                $commentEnd = $line.IndexOf('-->', $commentStart + 4, [System.StringComparison]::Ordinal)
                if ($commentEnd -lt 0) {
                    throw 'Inline HTML comments in lite task sections must close on the same line'
                }
                for ($offset = $commentStart; $offset -lt ($commentEnd + 3); $offset++) {
                    $visible[$lineMatch.Index + $offset] = ' '
                }
                $commentOffset = $commentEnd + 3
            }
        }

        if ($hideLine) {
            $markerWritten = $false
            for ($offset = $lineMatch.Index; $offset -lt ($lineMatch.Index + $lineMatch.Length); $offset++) {
                if ($visible[$offset] -ne "`r" -and $visible[$offset] -ne "`n") {
                    $visible[$offset] = if ($markerWritten) { ' ' } else { '!' }
                    $markerWritten = $true
                }
            }
        }
    }

    return (-join $visible)
}

function Get-LiteSections {
    param([string]$Content)

    $visible = Get-LiteVisibleMarkdownText -Content $Content
    $headings = @([regex]::Matches($visible, '(?m)^##[ \t]+(.+?)[ \t]*\r?\n'))

    for ($index = 0; $index -lt $headings.Count; $index++) {
        $contentStart = $headings[$index].Index + $headings[$index].Length
        $contentEnd = if ($index + 1 -lt $headings.Count) { $headings[$index + 1].Index } else { $Content.Length }
        $rawContent = $Content.Substring($contentStart, $contentEnd - $contentStart)
        $visibleContent = $visible.Substring($contentStart, $contentEnd - $contentStart)
        [pscustomobject]@{
            Name = $headings[$index].Groups[1].Value
            Content = $rawContent.Trim()
            RawContent = $rawContent
            VisibleContent = $visibleContent.Trim()
        }
    }
}

function Get-LiteSectionContent {
    param(
        [object[]]$Sections,
        [string]$Name
    )

    $section = @($Sections | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1)
    if ($section.Count -eq 0) {
        return ''
    }
    return $section[0].VisibleContent
}

function Get-LiteUserConfirmationStatus {
    param([object[]]$Sections)

    $confirmationSections = @($Sections | Where-Object { $_.Name -ceq 'User Confirmation' })
    if ($confirmationSections.Count -ne 1) {
        throw 'User Confirmation must contain exactly one case-exact top-level status line'
    }

    $lines = @(([string]$confirmationSections[0].RawContent) -split '\r?\n')
    $first = 0
    $last = $lines.Count - 1
    while ($first -le $last -and [string]::IsNullOrWhiteSpace($lines[$first])) {
        $first += 1
    }
    while ($last -ge $first -and [string]::IsNullOrWhiteSpace($lines[$last])) {
        $last -= 1
    }
    if ($first -ne $last) {
        throw 'User Confirmation must contain exactly one case-exact top-level status line'
    }

    $match = [regex]::Match($lines[$first], '^- status:[ \t]*(draft|confirmed)[ \t]*$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw 'User Confirmation must contain exactly one case-exact top-level status line'
    }
    return $match.Groups[1].Value
}

function Test-LitePlainScalar {
    param(
        [string]$Value,
        [switch]$Literal
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $normalized = [regex]::Replace($Value, '[\p{Cc}\p{Cf}]', '')
    if (-not $Literal.IsPresent) {
        $codeSpan = [regex]::Match($normalized.Trim(), '^(?<ticks>`+)(?!`)(?<body>.*?)(?<!`)\k<ticks>$')
        if ($codeSpan.Success) {
            $ticks = $codeSpan.Groups['ticks'].Value
            $body = $codeSpan.Groups['body'].Value
            $innerDelimiter = '(?<!`)' + [regex]::Escape($ticks) + '(?!`)'
            if (-not [regex]::IsMatch($body, $innerDelimiter)) {
                return Test-LitePlainScalar -Value $body -Literal
            }
        }
    }

    $semantic = [regex]::Match($normalized, '[\p{L}\p{N}]')
    if (-not $semantic.Success) {
        return $false
    }

    if ($Literal.IsPresent) {
        return $true
    }

    foreach ($hiddenWrapper in @('[', '<', '&')) {
        $wrapperIndex = $normalized.IndexOf($hiddenWrapper, [System.StringComparison]::Ordinal)
        if ($wrapperIndex -ge 0 -and $wrapperIndex -lt $semantic.Index) {
            return $false
        }
    }
    return $true
}

function Test-LiteTopLevelFieldValue {
    param(
        [string]$Content,
        [string]$FieldPattern
    )

    foreach ($field in [regex]::Matches($Content, ('(?m)^- {0}:([^\r\n]*)\r?$' -f $FieldPattern))) {
        if (Test-LitePlainScalar -Value $field.Groups[1].Value) {
            return $true
        }

        $valueStart = $field.Index + $field.Length
        $remaining = $Content.Substring($valueStart)
        foreach ($line in ($remaining -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line -notmatch '^[ \t]{2,}') {
                break
            }
            $payload = $line.Trim() -replace '^(?:[-*+]|\d+\.)[ \t]*', ''
            if (Test-LitePlainScalar -Value $payload) {
                return $true
            }
        }
    }
    return $false
}

function Get-LiteMissingClarificationAspects {
    param([string]$Content)

    $requirements = @(
        [pscustomobject]@{ Label = '验收'; Field = '验收(?:标准)?' }
        [pscustomobject]@{ Label = '非目标'; Field = '非目标' }
        [pscustomobject]@{ Label = '受影响'; Field = '受影响[^:\r\n]*' }
        [pscustomobject]@{ Label = '回滚 或 兼容'; Field = '(?:回滚|兼容)[^:\r\n]*' }
        [pscustomobject]@{ Label = 'ui:'; Field = 'ui' }
    )

    foreach ($requirement in $requirements) {
        if (-not (Test-LiteTopLevelFieldValue -Content $Content -FieldPattern $requirement.Field)) {
            $requirement.Label
        }
    }
}

function Get-LiteRunBlocks {
    param([string]$SectionContent)

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        return
    }

    $visible = Get-LiteVisibleMarkdownText -Content $SectionContent
    $runHeadings = [regex]::Matches($visible, '(?m)^###[ \t]+Run\b[^\r\n]*\r?$')
    $runBlocks = [regex]::Matches($visible, '(?ms)^###[ \t]+Run[ \t]+(\d+)[ \t]*·[ \t]*(\d{4}-\d{2}-\d{2}[ \t]+\d{2}:\d{2})[ \t]*·[ \t]*runner:[ \t]*(.+?)\r?\n(.*?)(?=^###[ \t]+Run[ \t]+\d+|\z)')
    if ($runHeadings.Count -ne $runBlocks.Count) {
        throw 'invalid Run heading or unparsed Run block'
    }
    for ($index = 0; $index -lt $runBlocks.Count; $index++) {
        $match = $runBlocks[$index]
        if ($match.Index -ne $runHeadings[$index].Index) {
            throw 'invalid Run heading or unparsed Run block'
        }

        $runner = $match.Groups[3].Value.Trim()
        if (-not (Test-LitePlainScalar -Value $runner)) {
            throw 'Run runner must contain a plain visible scalar value'
        }

        [pscustomobject]@{
            Number = [int]$match.Groups[1].Value
            When = [datetime]::ParseExact($match.Groups[2].Value, 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            Runner = $runner
            Body = $match.Groups[4].Value.Trim()
            Raw = $SectionContent.Substring($match.Index, $match.Length).Trim()
        }
    }
}

function Get-LiteLatestRun {
    param(
        [object[]]$Sections,
        [string]$Name
    )

    $runs = @(Get-LiteRunBlocks -SectionContent (Get-LiteSectionContent -Sections $Sections -Name $Name))
    if ($runs.Count -eq 0) {
        return $null
    }
    return $runs[-1]
}

function Get-LiteReviewRunContract {
    param([object]$Run)

    $lines = @($Run.Body -split '\r?\n')
    $verdictIndexes = @()
    $findingsIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^- verdict:') {
            $verdictIndexes += $index
        }
        if ($lines[$index] -match '^- findings:') {
            $findingsIndexes += $index
        }
    }

    $verdictMatch = if ($verdictIndexes.Count -eq 1) { [regex]::Match($lines[$verdictIndexes[0]], '^- verdict:\s*(pass|revise)\s*$') } else { $null }
    if ($null -eq $verdictMatch -or -not $verdictMatch.Success) {
        throw 'review run must contain exactly one - verdict: pass | revise'
    }
    $verdict = $verdictMatch.Groups[1].Value

    if ($findingsIndexes.Count -ne 1) {
        throw 'review run must contain exactly one - findings: none or bounded P0-P3 list'
    }

    $findingsIndex = $findingsIndexes[0]
    $findingsNone = $lines[$findingsIndex] -match '^- findings:\s*none\s*$'
    $severities = @()
    if ($findingsNone) {
        for ($index = $findingsIndex + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^- [A-Za-z][A-Za-z0-9_.-]*:') {
                break
            }
            if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
                throw 'inline findings none cannot contain nested content'
            }
        }
    } else {
        if ($lines[$findingsIndex] -notmatch '^- findings:\s*$') {
            throw 'review run findings must be none or a bounded P0-P3 list'
        }

        $findingLines = @()
        for ($index = $findingsIndex + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^- [A-Za-z][A-Za-z0-9_.-]*:') {
                break
            }
            $findingLines += $lines[$index]
        }
        if ($findingLines.Count -eq 0) {
            throw 'review run findings list must contain at least one P0-P3 finding'
        }
        foreach ($line in $findingLines) {
            $finding = [regex]::Match($line, '^  - (P[0-3]):[ \t]+(.+)$')
            if (-not $finding.Success -or -not (Test-LitePlainScalar -Value $finding.Groups[2].Value)) {
                throw 'review run findings list may contain only indented P0-P3 findings'
            }
            $severities += $finding.Groups[1].Value
        }
    }

    return [pscustomobject]@{
        Verdict = $verdict
        FindingsNone = $findingsNone
        Severities = @($severities)
    }
}

function Assert-LiteLatestReviewConsistency {
    param([object]$Review)

    if ($Review.Verdict -eq 'pass' -and @($Review.Severities | Where-Object { $_ -in @('P0', 'P1') }).Count -gt 0) {
        throw 'latest review verdict pass cannot contain P0/P1 findings'
    }
    if ($Review.Verdict -eq 'revise' -and $Review.FindingsNone) {
        throw 'latest review verdict revise requires at least one finding'
    }
}
