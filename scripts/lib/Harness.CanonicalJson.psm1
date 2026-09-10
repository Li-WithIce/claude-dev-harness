Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop

$script:StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:OrdinalComparer = [System.StringComparer]::Ordinal
$script:JsonPropertyComparer = [System.Collections.Generic.Comparer[object]]::Create(
    [System.Comparison[object]]{
        param($Left, $Right)
        return [System.StringComparer]::Ordinal.Compare([string]$Left.Name, [string]$Right.Name)
    })
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:MaxSafeInteger = [double]9007199254740991

function Assert-HarnessCanonicalJsonUnicode {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $insideString = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if (-not $insideString) {
            if ($character -ceq '"') { $insideString = $true }
            continue
        }
        if ($character -ceq '"') {
            $insideString = $false
            continue
        }
        if ($character -ceq '\') {
            if ($index + 1 -ge $Text.Length) { throw 'canonical JSON contains an incomplete string escape' }
            $escape = $Text[$index + 1]
            if ($escape -cne 'u') {
                if ($escape -cnotin @('"','\','/','b','f','n','r','t')) { throw 'canonical JSON contains an invalid string escape' }
                $index++
                continue
            }
            if ($index + 5 -ge $Text.Length) { throw 'canonical JSON contains an incomplete Unicode escape' }
            $hex = $Text.Substring($index + 2, 4)
            if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw 'canonical JSON contains an invalid Unicode escape' }
            $codeUnit = [uint16]::Parse($hex, [System.Globalization.NumberStyles]::AllowHexSpecifier, $script:InvariantCulture)
            if ($codeUnit -ge 0xD800 -and $codeUnit -le 0xDBFF) {
                if ($index + 11 -ge $Text.Length -or $Text[$index + 6] -cne '\' -or $Text[$index + 7] -cne 'u') {
                    throw 'canonical JSON contains a lone high-surrogate escape'
                }
                $lowHex = $Text.Substring($index + 8, 4)
                if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw 'canonical JSON contains an invalid low-surrogate escape' }
                $lowCodeUnit = [uint16]::Parse($lowHex, [System.Globalization.NumberStyles]::AllowHexSpecifier, $script:InvariantCulture)
                if ($lowCodeUnit -lt 0xDC00 -or $lowCodeUnit -gt 0xDFFF) { throw 'canonical JSON contains a lone high-surrogate escape' }
                $index += 11
                continue
            }
            if ($codeUnit -ge 0xDC00 -and $codeUnit -le 0xDFFF) { throw 'canonical JSON contains a lone low-surrogate escape' }
            $index += 5
            continue
        }
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Text.Length -or -not [char]::IsLowSurrogate($Text[$index + 1])) {
                throw 'canonical JSON contains a lone raw high surrogate'
            }
            $index++
            continue
        }
        if ([char]::IsLowSurrogate($character)) { throw 'canonical JSON contains a lone raw low surrogate' }
    }
    if ($insideString) { throw 'canonical JSON contains an unterminated string' }
}

function Add-HarnessCanonicalJsonString {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )

    [void]$Builder.Append('"')
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $codeUnit = [int]$character
        if ($codeUnit -eq 0x08) { [void]$Builder.Append('\b'); continue }
        if ($codeUnit -eq 0x09) { [void]$Builder.Append('\t'); continue }
        if ($codeUnit -eq 0x0A) { [void]$Builder.Append('\n'); continue }
        if ($codeUnit -eq 0x0C) { [void]$Builder.Append('\f'); continue }
        if ($codeUnit -eq 0x0D) { [void]$Builder.Append('\r'); continue }
        if ($codeUnit -eq 0x22) { [void]$Builder.Append('\"'); continue }
        if ($codeUnit -eq 0x5C) { [void]$Builder.Append('\\'); continue }
        if ($codeUnit -lt 0x20) {
            [void]$Builder.Append('\u')
            [void]$Builder.Append($codeUnit.ToString('x4', $script:InvariantCulture))
            continue
        }
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw 'canonical JSON contains a lone high surrogate'
            }
            [void]$Builder.Append($character)
            $index++
            [void]$Builder.Append($Value[$index])
            continue
        }
        if ([char]::IsLowSurrogate($character)) { throw 'canonical JSON contains a lone low surrogate' }
        [void]$Builder.Append($character)
    }
    [void]$Builder.Append('"')
}

function Add-HarnessCanonicalJsonNumber {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element
    )

    $raw = $Element.GetRawText()
    [double]$number = 0
    if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, $script:InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw 'canonical-json/v1 number is not a finite binary64 value'
    }
    if ([Math]::Truncate($number) -ne $number -or $number -lt -$script:MaxSafeInteger -or $number -gt $script:MaxSafeInteger) {
        throw 'canonical-json/v1 accepts only safe integer number values'
    }
    if ($number -eq 0) {
        [void]$Builder.Append('0')
        return
    }
    [void]$Builder.Append(([long]$number).ToString($script:InvariantCulture))
}

function Add-HarnessCanonicalJsonElement {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element
    )

    switch ([string]$Element.ValueKind) {
        'Object' {
            $properties = [System.Collections.Generic.List[object]]::new()
            $names = [System.Collections.Generic.HashSet[string]]::new($script:OrdinalComparer)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add([string]$property.Name)) { throw 'canonical JSON object contains a duplicate decoded property name' }
                $properties.Add($property)
            }
            $properties.Sort($script:JsonPropertyComparer)
            [void]$Builder.Append('{')
            for ($index = 0; $index -lt $properties.Count; $index++) {
                if ($index -gt 0) { [void]$Builder.Append(',') }
                $property = $properties[$index]
                Add-HarnessCanonicalJsonString -Builder $Builder -Value ([string]$property.Name)
                [void]$Builder.Append(':')
                Add-HarnessCanonicalJsonElement -Builder $Builder -Element $property.Value
            }
            [void]$Builder.Append('}')
            return
        }
        'Array' {
            [void]$Builder.Append('[')
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                if ($index -gt 0) { [void]$Builder.Append(',') }
                Add-HarnessCanonicalJsonElement -Builder $Builder -Element $item
                $index++
            }
            [void]$Builder.Append(']')
            return
        }
        'String' {
            Add-HarnessCanonicalJsonString -Builder $Builder -Value $Element.GetString()
            return
        }
        'Number' {
            Add-HarnessCanonicalJsonNumber -Builder $Builder -Element $Element
            return
        }
        'True' { [void]$Builder.Append('true'); return }
        'False' { [void]$Builder.Append('false'); return }
        'Null' { [void]$Builder.Append('null'); return }
        default { throw "unsupported canonical JSON value kind: $($Element.ValueKind)" }
    }
}

function ConvertTo-HarnessCanonicalJsonBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$JsonBytes)

    if ($null -eq $JsonBytes) { throw 'canonical JSON input bytes cannot be null' }
    if ($JsonBytes.Length -ge 3 -and $JsonBytes[0] -eq 0xEF -and $JsonBytes[1] -eq 0xBB -and $JsonBytes[2] -eq 0xBF) {
        throw 'canonical JSON input must not contain a UTF-8 BOM'
    }
    try {
        $text = $script:StrictUtf8.GetString($JsonBytes)
    } catch {
        throw 'canonical JSON input is not valid UTF-8'
    }
    Assert-HarnessCanonicalJsonUnicode -Text $text

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 64
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
    } catch {
        throw "canonical JSON input is invalid: $($_.Exception.Message)"
    }
    try {
        $builder = [System.Text.StringBuilder]::new()
        Add-HarnessCanonicalJsonElement -Builder $builder -Element $document.RootElement
        [byte[]]$result = $script:StrictUtf8.GetBytes($builder.ToString())
        Write-Output -NoEnumerate $result
    } finally {
        $document.Dispose()
    }
}

function Get-HarnessCanonicalJsonSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$JsonBytes)

    [byte[]]$canonicalBytes = ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $JsonBytes
    return Harness.Hashing\Get-HarnessSha256Bytes -Bytes $canonicalBytes
}

Export-ModuleMember -Function ConvertTo-HarnessCanonicalJsonBytes,Get-HarnessCanonicalJsonSha256
