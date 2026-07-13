# Generates a fixed paired reading HTML artifact from a Markdown source.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('SourcePath')]
    [string]$Source,

    [Alias('OutputPath')]
    [string]$Output = "",

    [string]$RepoRoot = "",

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return (Resolve-Path -LiteralPath $RequestedRoot).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function ConvertTo-HtmlText {
    param([string]$Value)

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-DisplayPath {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -replace '\\', '/'
    }

    return $fullPath
}

function Convert-InlineMarkdown {
    param([string]$Text)

    $html = ConvertTo-HtmlText -Value $Text
    $html = [regex]::Replace($html, '`([^`]+)`', '<code>$1</code>')
    $html = [regex]::Replace($html, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $html = [regex]::Replace($html, '\*([^*]+)\*', '<em>$1</em>')
    return $html
}

function New-HeadingSlug {
    param(
        [string]$Text,
        [int]$Level,
        [int]$Index
    )

    $plain = $Text -replace '[`*_#\[\]\(\)]', ''
    $slug = [regex]::Replace($plain.ToLowerInvariant(), '[^\p{L}\p{Nd}]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'section'
    }

    return ('h-{0}-{1}-{2}' -f $Level, $Index, $slug)
}

function Test-TableDelimiter {
    param([string]$Line)

    return $Line -match '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$'
}

function Split-TableLine {
    param([string]$Line)

    $trimmed = $Line.Trim()
    if ($trimmed.StartsWith('|')) {
        $trimmed = $trimmed.Substring(1)
    }
    if ($trimmed.EndsWith('|')) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }

    return @($trimmed -split '\s*\|\s*')
}

function Resolve-OutputPath {
    param(
        [string]$SourcePath,
        [string]$RequestedOutput
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedOutput)) {
        if ([System.IO.Path]::IsPathRooted($RequestedOutput)) {
            return [System.IO.Path]::GetFullPath($RequestedOutput)
        }

        return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $RequestedOutput))
    }

    $sourceDir = Split-Path -Parent $SourcePath
    $sourceName = [System.IO.Path]::GetFileName($SourcePath).ToLowerInvariant()
    if ($sourceName -eq 'plan.md') {
        return (Join-Path $sourceDir 'plan.review.html')
    }
    if ($sourceName -eq 'spec.md') {
        return (Join-Path $sourceDir 'spec.review.html')
    }

    return (Join-Path $sourceDir 'review.html')
}

function Assert-ReviewOutputAllowed {
    param(
        [string]$SourcePath,
        [string]$OutputPath
    )

    if ([System.IO.Path]::GetFileName($OutputPath).ToLowerInvariant() -ne 'review.html') {
        return
    }

    $sourceDir = Split-Path -Parent $SourcePath
    $pairedSources = @('spec.md', 'plan.md') | Where-Object {
        Test-Path -LiteralPath (Join-Path $sourceDir $_) -PathType Leaf
    }
    if (@($pairedSources).Count -gt 1) {
        throw 'review.html is ambiguous when spec.md and plan.md both exist; use spec.review.html or plan.review.html.'
    }
}

function New-HeadingMap {
    param([string[]]$Lines)

    $headingMap = @{}
    $headingIndex = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $match = [regex]::Match($Lines[$i], '^(#{1,6})\s+(.+?)\s*#*\s*$')
        if (-not $match.Success) {
            continue
        }

        $headingIndex++
        $level = $match.Groups[1].Value.Length
        $text = $match.Groups[2].Value.Trim()
        $headingMap[$i] = [pscustomobject]@{
            Level = $level
            Text = $text
            Id = New-HeadingSlug -Text $text -Level $level -Index $headingIndex
        }
    }

    return $headingMap
}

function Convert-MarkdownToBodyHtml {
    param(
        [string[]]$Lines,
        [hashtable]$HeadingMap
    )

    $html = New-Object System.Collections.Generic.List[string]
    $insideCode = $false
    $insideSection = $false
    $codeLanguage = ''
    $lineIndex = 0

    while ($lineIndex -lt $Lines.Count) {
        $line = $Lines[$lineIndex]

        $fence = [regex]::Match($line, '^\s*```\s*([A-Za-z0-9_.+-]*)\s*$')
        if ($fence.Success) {
            if ($insideCode) {
                $html.Add('</code></pre>') | Out-Null
                $insideCode = $false
                $codeLanguage = ''
            } else {
                $insideCode = $true
                $codeLanguage = $fence.Groups[1].Value
                $classAttribute = ''
                if (-not [string]::IsNullOrWhiteSpace($codeLanguage)) {
                    $classAttribute = ' class="language-' + (ConvertTo-HtmlText -Value $codeLanguage) + '"'
                }
                $html.Add('<pre class="code-block"><code' + $classAttribute + '>') | Out-Null
            }
            $lineIndex++
            continue
        }

        if ($insideCode) {
            $html.Add((ConvertTo-HtmlText -Value $line)) | Out-Null
            $lineIndex++
            continue
        }

        if ($HeadingMap.ContainsKey($lineIndex)) {
            $heading = $HeadingMap[$lineIndex]
            if ($heading.Level -eq 2) {
                if ($insideSection) {
                    $html.Add('</section>') | Out-Null
                }
                $html.Add('<section class="doc-section level-2">') | Out-Null
                $insideSection = $true
            }

            $html.Add(('<h{0} id="{1}"><a class="anchor" href="#{1}" aria-label="Link to this section">#</a>{2}</h{0}>' -f $heading.Level, $heading.Id, (Convert-InlineMarkdown -Text $heading.Text))) | Out-Null
            $lineIndex++
            continue
        }

        if (($lineIndex + 1) -lt $Lines.Count -and $line.Contains('|') -and (Test-TableDelimiter -Line $Lines[$lineIndex + 1])) {
            $headers = Split-TableLine -Line $line
            $lineIndex += 2
            $html.Add('<div class="table-scroll"><table>') | Out-Null
            $html.Add('<thead><tr>') | Out-Null
            foreach ($header in $headers) {
                $html.Add(('<th>{0}</th>' -f (Convert-InlineMarkdown -Text $header.Trim()))) | Out-Null
            }
            $html.Add('</tr></thead>') | Out-Null
            $html.Add('<tbody>') | Out-Null
            while ($lineIndex -lt $Lines.Count -and $Lines[$lineIndex].Contains('|') -and -not [string]::IsNullOrWhiteSpace($Lines[$lineIndex])) {
                $cells = Split-TableLine -Line $Lines[$lineIndex]
                $html.Add('<tr>') | Out-Null
                for ($cellIndex = 0; $cellIndex -lt $headers.Count; $cellIndex++) {
                    $cellValue = ''
                    if ($cellIndex -lt $cells.Count) {
                        $cellValue = $cells[$cellIndex].Trim()
                    }
                    $html.Add(('<td>{0}</td>' -f (Convert-InlineMarkdown -Text $cellValue))) | Out-Null
                }
                $html.Add('</tr>') | Out-Null
                $lineIndex++
            }
            $html.Add('</tbody></table></div>') | Out-Null
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            $lineIndex++
            continue
        }

        if ($line -match '^\s*[-*]\s+(.+)$') {
            $html.Add(('<ul class="compact-list"><li>{0}</li></ul>' -f (Convert-InlineMarkdown -Text $Matches[1].Trim()))) | Out-Null
            $lineIndex++
            continue
        }

        if ($line -match '^\s*\d+\.\s+(.+)$') {
            $html.Add(('<ol class="compact-list"><li>{0}</li></ol>' -f (Convert-InlineMarkdown -Text $Matches[1].Trim()))) | Out-Null
            $lineIndex++
            continue
        }

        if ($line -match '^\s*>\s*(.+)$') {
            $html.Add(('<blockquote>{0}</blockquote>' -f (Convert-InlineMarkdown -Text $Matches[1].Trim()))) | Out-Null
            $lineIndex++
            continue
        }

        $html.Add(('<p>{0}</p>' -f (Convert-InlineMarkdown -Text $line.Trim()))) | Out-Null
        $lineIndex++
    }

    if ($insideCode) {
        $html.Add('</code></pre>') | Out-Null
    }
    if ($insideSection) {
        $html.Add('</section>') | Out-Null
    }

    return ($html -join "`n")
}

function Get-DocumentTitle {
    param(
        [string[]]$Lines,
        [string]$Fallback
    )

    foreach ($line in $Lines) {
        $match = [regex]::Match($line, '^#\s+(.+?)\s*#*\s*$')
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }
    }

    return $Fallback
}

function Get-HeadingEntries {
    param([hashtable]$HeadingMap)

    return @($HeadingMap.Keys | Sort-Object | ForEach-Object {
        $heading = $HeadingMap[$_]
        [pscustomobject]@{
            Line = [int]$_
            Level = [int]$heading.Level
            Text = [string]$heading.Text
            Id = [string]$heading.Id
        }
    })
}

function Get-SectionLines {
    param(
        [string[]]$Lines,
        [object[]]$HeadingEntries,
        [object]$Entry
    )

    $next = @($HeadingEntries | Where-Object { $_.Line -gt $Entry.Line -and $_.Level -le $Entry.Level } | Select-Object -First 1)
    $start = $Entry.Line + 1
    $endExclusive = $Lines.Count
    if ($next.Count -gt 0) {
        $endExclusive = $next[0].Line
    }
    if ($start -ge $endExclusive) {
        return @()
    }

    return @($Lines[$start..($endExclusive - 1)])
}

function Get-BulletItems {
    param([string[]]$Lines)

    return @($Lines | ForEach-Object {
        $match = [regex]::Match($_, '^\s*(?:[-*]|\d+\.)\s+(.+)$')
        if ($match.Success) {
            $match.Groups[1].Value.Trim()
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-FirstTextItems {
    param(
        [string[]]$Lines,
        [int]$Count = 4
    )

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^(#{1,6})\s+' -or $trimmed.Contains('|')) {
            continue
        }
        $items.Add($trimmed) | Out-Null
        if ($items.Count -ge $Count) {
            break
        }
    }

    return @($items)
}

function Get-MarkdownTables {
    param([string[]]$Lines)

    $tables = New-Object System.Collections.Generic.List[object]
    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        if (($lineIndex + 1) -ge $Lines.Count -or -not $Lines[$lineIndex].Contains('|') -or -not (Test-TableDelimiter -Line $Lines[$lineIndex + 1])) {
            continue
        }

        $tableLines = New-Object System.Collections.Generic.List[string]
        while ($lineIndex -lt $Lines.Count -and $Lines[$lineIndex].Contains('|') -and -not [string]::IsNullOrWhiteSpace($Lines[$lineIndex])) {
            $tableLines.Add($Lines[$lineIndex]) | Out-Null
            $lineIndex++
        }

        $headers = Split-TableLine -Line $tableLines[0]
        $rows = New-Object System.Collections.Generic.List[object]
        for ($rowIndex = 2; $rowIndex -lt $tableLines.Count; $rowIndex++) {
            $cells = Split-TableLine -Line $tableLines[$rowIndex]
            $row = [ordered]@{}
            for ($cellIndex = 0; $cellIndex -lt $headers.Count; $cellIndex++) {
                $cell = ''
                if ($cellIndex -lt $cells.Count) {
                    $cell = $cells[$cellIndex]
                }
                $row[$headers[$cellIndex]] = $cell
            }
            $rows.Add($row) | Out-Null
        }

        $table = New-Object psobject
        $table | Add-Member -NotePropertyName Headers -NotePropertyValue ([string[]]@($headers))
        $table | Add-Member -NotePropertyName Rows -NotePropertyValue ([object[]]@($rows.ToArray()))
        $tables.Add($table) | Out-Null
    }

    return $tables.ToArray()
}

function New-CardListHtml {
    param(
        [string]$Title,
        [string[]]$Items,
        [string]$ClassName
    )

    $html = New-Object System.Collections.Generic.List[string]
    $html.Add(('<article class="{0}">' -f $ClassName)) | Out-Null
    $html.Add(('<h3>{0}</h3>' -f (Convert-InlineMarkdown -Text $Title))) | Out-Null
    if ($Items.Count -eq 0) {
        $html.Add('<p>未从源文档中提取到明确条目。</p>') | Out-Null
    } else {
        $html.Add('<ul>') | Out-Null
        foreach ($item in $Items) {
            $html.Add(('<li>{0}</li>' -f (Convert-InlineMarkdown -Text $item))) | Out-Null
        }
        $html.Add('</ul>') | Out-Null
    }
    $html.Add('</article>') | Out-Null

    return ($html -join "`n")
}

function New-TableCardsHtml {
    param(
        [object[]]$Rows,
        [string[]]$Headers,
        [string]$ClassName
    )

    $html = New-Object System.Collections.Generic.List[string]
    $html.Add(('<div class="{0}">' -f $ClassName)) | Out-Null
    foreach ($row in $Rows) {
        if ($Headers.Count -eq 0) {
            continue
        }
        $title = [string]$row[$Headers[0]]
        $html.Add('<article class="matrix-card">') | Out-Null
        $html.Add(('<h3>{0}</h3>' -f (Convert-InlineMarkdown -Text $title))) | Out-Null
        for ($i = 1; $i -lt $Headers.Count; $i++) {
            $header = $Headers[$i]
            $value = [string]$row[$header]
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }
            $html.Add(('<p><strong>{0}</strong> {1}</p>' -f (Convert-InlineMarkdown -Text $header), (Convert-InlineMarkdown -Text $value))) | Out-Null
        }
        $html.Add('</article>') | Out-Null
    }
    $html.Add('</div>') | Out-Null

    return ($html -join "`n")
}

$repoRootResolved = Resolve-RepoRoot -RequestedRoot $RepoRoot
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$outputPath = Resolve-OutputPath -SourcePath $sourcePath -RequestedOutput $Output
Assert-ReviewOutputAllowed -SourcePath $sourcePath -OutputPath $outputPath

$rawLines = [System.IO.File]::ReadAllLines($sourcePath, [System.Text.Encoding]::UTF8)
$contentStart = 0
if ($rawLines.Count -gt 2 -and $rawLines[0] -eq '---') {
    for ($i = 1; $i -lt $rawLines.Count; $i++) {
        if ($rawLines[$i] -eq '---') {
            $contentStart = $i + 1
            break
        }
    }
}
$lines = @($rawLines | Select-Object -Skip $contentStart)
$headingMap = New-HeadingMap -Lines $lines
$title = Get-DocumentTitle -Lines $lines -Fallback ([System.IO.Path]::GetFileNameWithoutExtension($sourcePath))
$displaySource = ConvertTo-DisplayPath -Path $sourcePath -Root $repoRootResolved
$headingEntries = Get-HeadingEntries -HeadingMap $headingMap
$h2Entries = @($headingEntries | Where-Object { $_.Level -eq 2 })
$allTables = Get-MarkdownTables -Lines $lines
$riskHeading = @($headingEntries | Where-Object { $_.Text -match '风险|Risk' } | Select-Object -First 1)
$decisionHeading = @($headingEntries | Where-Object { $_.Text -match '决策|澄清|Decision' } | Select-Object -First 1)
$checkpointHeading = @($headingEntries | Where-Object { $_.Text -match '测试|验收|校验|Checkpoint|Check' } | Select-Object -First 1)
$architectureHeadings = @($h2Entries | Where-Object { $_.Text -match '架构|现状|模型|接口|后端|前端|迁移|实施|目标|MVP' } | Select-Object -First 6)

$tocItems = New-Object System.Collections.Generic.List[string]
foreach ($entry in $h2Entries) {
    $tocItems.Add(('<a href="#raw-{0}">{1}</a>' -f $entry.Id, (Convert-InlineMarkdown -Text $entry.Text))) | Out-Null
}

$summaryItems = Get-FirstTextItems -Lines $lines -Count 5
$riskTable = $null
if ($riskHeading.Count -gt 0) {
    $riskTables = @(Get-MarkdownTables -Lines (Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $riskHeading[0]))
    if ($riskTables.Count -gt 0) {
        $riskTable = $riskTables[0]
    }
}
$decisionTable = $null
if ($decisionHeading.Count -gt 0) {
    $decisionTables = @(Get-MarkdownTables -Lines (Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $decisionHeading[0]))
    if ($decisionTables.Count -gt 0) {
        $decisionTable = $decisionTables[0]
    }
}
$allTableCount = @($allTables).Count
$decisionRowCount = 0
if ($null -ne $decisionTable) {
    $decisionRowCount = @($decisionTable.Rows).Count
}
$riskRowCount = 0
if ($null -ne $riskTable) {
    $riskRowCount = @($riskTable.Rows).Count
}

$checkpointItems = @()
if ($checkpointHeading.Count -gt 0) {
    $checkpointItems = @(Get-BulletItems -Lines (Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $checkpointHeading[0]) | Select-Object -First 12)
}
if ($checkpointItems.Count -eq 0) {
    $checkpointItems = @(Get-BulletItems -Lines $lines | Select-Object -First 12)
}

$flowItems = New-Object System.Collections.Generic.List[string]
$flowHeading = @($headingEntries | Where-Object { $_.Text -match '阶段|实施|迁移|计划|MVP|目标架构' } | Select-Object -First 1)
if ($flowHeading.Count -gt 0) {
    foreach ($item in @(Get-BulletItems -Lines (Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $flowHeading[0]) | Select-Object -First 10)) {
        $flowItems.Add(('<li><span>{0}</span></li>' -f (Convert-InlineMarkdown -Text $item))) | Out-Null
    }
}
if ($flowItems.Count -eq 0) {
    foreach ($entry in ($architectureHeadings | Select-Object -First 5)) {
        $flowItems.Add(('<li><span>{0}</span></li>' -f (Convert-InlineMarkdown -Text $entry.Text))) | Out-Null
    }
}

$architectureCards = New-Object System.Collections.Generic.List[string]
foreach ($entry in $architectureHeadings) {
    $sectionLines = Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $entry
    $items = @(Get-BulletItems -Lines $sectionLines | Select-Object -First 5)
    if ($items.Count -eq 0) {
        $items = @(Get-FirstTextItems -Lines $sectionLines -Count 3)
    }
    $architectureCards.Add((New-CardListHtml -Title $entry.Text -Items $items -ClassName 'architecture-card')) | Out-Null
}

$sourceDetails = New-Object System.Collections.Generic.List[string]
foreach ($entry in $h2Entries) {
    $sectionLines = Get-SectionLines -Lines $lines -HeadingEntries $headingEntries -Entry $entry
    $sourceDetails.Add(('<details class="source-section" id="raw-{0}"><summary>{1}</summary>' -f $entry.Id, (Convert-InlineMarkdown -Text $entry.Text))) | Out-Null
    $sourceDetails.Add((Convert-MarkdownToBodyHtml -Lines $sectionLines -HeadingMap @{})) | Out-Null
    $sourceDetails.Add('</details>') | Out-Null
}

$document = @"
<style data-review-template="md-html-review-v1">
.review-html-fragment{--text:#1f2937;--muted:#64748b;--line:#d8e0eb;--panel:#fff;--soft:#f6f8fb;--accent:#2563eb;--accent-soft:#eff6ff;--risk:#b42318;--risk-soft:#fff1f0;--decision:#047857;--decision-soft:#ecfdf3;--warn:#9a3412;--warn-soft:#fff7ed;max-width:1180px;margin:0 auto;padding:24px;color:var(--text);font:15px/1.72 "Segoe UI","Microsoft YaHei",Arial,sans-serif;background:var(--soft)}
.review-html-fragment *{box-sizing:border-box}
.review-banner,.visual-block,.source-section{border:1px solid var(--line);border-radius:8px;background:var(--panel)}
.review-banner{padding:18px 20px;margin-bottom:18px;border-left:5px solid var(--accent)}
.review-banner h1{margin:0 0 8px;font-size:28px;line-height:1.3}
.review-banner p{margin:6px 0;color:var(--muted)}
.review-toc{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0 22px}
.review-toc a{padding:7px 10px;border:1px solid var(--line);border-radius:999px;background:#fff;color:#1d4ed8;text-decoration:none}
.visual-block{margin:18px 0;padding:18px}
.visual-block h2{margin:0 0 14px;font-size:20px}
.summary-grid,.architecture-grid,.decision-grid,.risk-grid,.checkpoint-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}
.info-card,.architecture-card,.matrix-card,.checkpoint-card{padding:14px;border:1px solid var(--line);border-radius:8px;background:#fff}
.info-card h3,.architecture-card h3,.matrix-card h3,.checkpoint-card h3{margin:0 0 8px;font-size:16px}
.info-card ul,.architecture-card ul,.checkpoint-card ul{margin:0;padding-left:18px}
.flow-list{display:grid;gap:10px;margin:0;padding:0;counter-reset:step}
.flow-list li{list-style:none;display:flex;gap:10px;align-items:flex-start;padding:11px 12px;border:1px solid var(--line);border-radius:8px;background:#fff}
.flow-list li:before{counter-increment:step;content:counter(step);display:inline-grid;place-items:center;min-width:26px;height:26px;border-radius:999px;background:var(--accent);color:#fff;font-weight:700}
.decision-grid .matrix-card{border-left:5px solid var(--decision);background:var(--decision-soft)}
.risk-grid .matrix-card{border-left:5px solid var(--risk);background:var(--risk-soft)}
.checkpoint-card{border-left:5px solid var(--warn);background:var(--warn-soft)}
.table-scroll{overflow-x:auto;margin:12px 0;border:1px solid var(--line);border-radius:8px;background:#fff}
table{width:100%;border-collapse:collapse;min-width:680px}
th,td{padding:9px 11px;border-bottom:1px solid #e7edf5;border-right:1px solid #edf2f7;text-align:left;vertical-align:top}
th{background:#f8fafc}
code{padding:1px 4px;border:1px solid #d7dee8;border-radius:4px;background:#f1f5f9}
pre{overflow:auto;padding:12px;border-radius:8px;background:#111827;color:#f8fafc}
.source-section{margin:12px 0;padding:0}
.source-section summary{cursor:pointer;padding:13px 15px;font-weight:700}
.source-section>*:not(summary){margin-left:15px;margin-right:15px}
.generated-note{font-size:13px;color:var(--muted)}
</style>
<section class="review-html-fragment" data-generated-artifact="paired-reading-html" data-template="md-html-review-v1">
  <header class="review-banner">
    <h1>$(Convert-InlineMarkdown -Text $title)</h1>
    <p class="generated-note">Generated paired reading HTML fragment. Markdown source: <code>$(ConvertTo-HtmlText -Value $displaySource)</code>. Treat the Markdown as the source of truth and regenerate this file after content changes.</p>
    <p>结构增强：summary / architecture flow / decision grid / risk grid / checkpoints / collapsible source sections。</p>
  </header>
  <nav class="review-toc">$($tocItems -join "`n")</nav>
  <section class="visual-block" data-visual-block="summary">
    <h2>Summary 信息卡片</h2>
    <div class="summary-grid">
      $(New-CardListHtml -Title '文档摘要' -Items $summaryItems -ClassName 'info-card')
      $(New-CardListHtml -Title '结构计数' -Items @("二级章节：$($h2Entries.Count)", "表格：$allTableCount", "决策项：$decisionRowCount", "风险项：$riskRowCount") -ClassName 'info-card')
      $(New-CardListHtml -Title '审阅重点' -Items @('确认已裁定决策是否仍成立', '优先检查高风险项和回滚条件', '按 checkpoint 逐项验收可执行性') -ClassName 'info-card')
    </div>
  </section>
  <section class="visual-block" data-visual-block="architecture-flow">
    <h2>流程 / 架构重组</h2>
    <ol class="flow-list">$($flowItems -join "`n")</ol>
    <div class="architecture-grid">$($architectureCards -join "`n")</div>
  </section>
  <section class="visual-block" data-visual-block="decision-grid">
    <h2>决策网格</h2>
    $(if ($decisionTable) { New-TableCardsHtml -Rows $decisionTable.Rows -Headers $decisionTable.Headers -ClassName 'decision-grid' } else { New-CardListHtml -Title '待补决策' -Items @('源文档没有可解析的决策表；建议在 Markdown 中加入决策矩阵。') -ClassName 'info-card' })
  </section>
  <section class="visual-block" data-visual-block="risk-grid">
    <h2>风险矩阵</h2>
    $(if ($riskTable) { New-TableCardsHtml -Rows $riskTable.Rows -Headers $riskTable.Headers -ClassName 'risk-grid' } else { New-CardListHtml -Title '待补风险' -Items @('源文档没有可解析的风险表；建议在 Markdown 中加入风险、等级、影响、缓解列。') -ClassName 'info-card' })
  </section>
  <section class="visual-block" data-visual-block="checkpoints">
    <h2>Checkpoint 验收卡片</h2>
    <div class="checkpoint-grid">
      $(New-CardListHtml -Title '检查项' -Items $checkpointItems -ClassName 'checkpoint-card')
      $(New-CardListHtml -Title '防漂移检查' -Items @('内容改动必须回写 Markdown source', 'HTML 可由同一脚本重复生成', '不得引入 script、iframe 或外部 JS') -ClassName 'checkpoint-card')
    </div>
  </section>
  <section class="visual-block" data-visual-block="collapsible-source">
    <h2>折叠源文档章节</h2>
    $($sourceDetails -join "`n")
  </section>
</section>
"@

$outputDir = Split-Path -Parent $outputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($outputPath, $document, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("Rendered paired reading HTML: {0}" -f $outputPath)
