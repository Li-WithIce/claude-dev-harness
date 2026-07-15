[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    throw 'invoke-harness-skill dispatcher requires PowerShell 7.3 or newer.'
}

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $actualKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Value.Keys) {
        if ($key -isnot [string] -or -not $actualKeys.Add([string]$key)) {
            throw "$Label has a duplicate or non-string key."
        }
    }
    $expectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Expected) { [void]$expectedKeys.Add($key) }
    if (-not $actualKeys.SetEquals($expectedKeys)) {
        throw "$Label has an invalid key set."
    }
}

function Assert-RawJsonObjectKeys {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.Json.JsonElement]$Element,

        [Parameter(Mandatory = $true)]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        throw "$Label must be a JSON object."
    }
    $actualKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if (-not $actualKeys.Add($property.Name)) {
            throw "$Label contains a duplicate JSON property."
        }
    }
    $expectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Expected) { [void]$expectedKeys.Add($key) }
    if (-not $actualKeys.SetEquals($expectedKeys)) {
        throw "$Label has an invalid JSON property set."
    }
}

$resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetScriptPath)
if (-not [System.IO.Path]::IsPathRooted($TargetScriptPath) -or
    [System.IO.Path]::GetExtension($resolvedTargetPath) -cne '.ps1' -or
    -not (Test-Path -LiteralPath $resolvedTargetPath -PathType Leaf)) {
    throw 'Dispatcher target must be an absolute existing PowerShell script.'
}
$targetItem = Get-Item -LiteralPath $resolvedTargetPath -Force
if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Dispatcher target must not be a reparse point.'
}

$resolvedRequestPath = [System.IO.Path]::GetFullPath($RequestPath)
$tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
if (-not $resolvedRequestPath.StartsWith($tempPrefix, $pathComparison) -or
    (Split-Path -Leaf $resolvedRequestPath) -cnotmatch '^invoke-harness-skill-request-[0-9a-f]{32}\.json$' -or
    -not (Test-Path -LiteralPath $resolvedRequestPath -PathType Leaf)) {
    throw 'Dispatcher request must be an existing adapter JSON file under the system temp directory.'
}
$requestItem = Get-Item -LiteralPath $resolvedRequestPath -Force
if (($requestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Dispatcher request must not be a reparse point.'
}

try {
    $requestText = [System.IO.File]::ReadAllText($resolvedRequestPath, [System.Text.UTF8Encoding]::new($false, $true))
    $jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $jsonOptions.AllowTrailingCommas = $false
    $jsonOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $jsonOptions.MaxDepth = 8
    $jsonDocument = [System.Text.Json.JsonDocument]::Parse($requestText, $jsonOptions)
    try {
        Assert-RawJsonObjectKeys -Element $jsonDocument.RootElement -Expected @('schema_version', 'parameters') -Label 'Dispatcher request'
        $rawParameters = $jsonDocument.RootElement.GetProperty('parameters')
        if ($rawParameters.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
            throw 'Dispatcher request parameters must be a JSON array.'
        }
        foreach ($rawEntry in $rawParameters.EnumerateArray()) {
            Assert-RawJsonObjectKeys -Element $rawEntry -Expected @('name', 'kind', 'value') -Label 'Dispatcher parameter entry'
        }
    } finally {
        $jsonDocument.Dispose()
    }
    $request = $requestText | ConvertFrom-Json -AsHashtable -Depth 8
} catch {
    throw 'Dispatcher request must be valid UTF-8 JSON.'
}
if ($request -isnot [System.Collections.IDictionary]) {
    throw 'Dispatcher request must be a JSON object.'
}
Assert-ExactKeys -Value $request -Expected @('schema_version', 'parameters') -Label 'Dispatcher request'
if ([string]$request.schema_version -cne 'invoke-harness-skill-dispatch/v1' -or $request.parameters -isnot [array]) {
    throw 'Dispatcher request schema is invalid.'
}

$allowedParameterKinds = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
$allowedParameterKinds.Add('Task', 'string')
$allowedParameterKinds.Add('Workspace', 'string')
$allowedParameterKinds.Add('File', 'string-array')
$allowedParameterKinds.Add('Session', 'string')
$allowedParameterKinds.Add('Model', 'string')
$allowedParameterKinds.Add('Reasoning', 'string')
$allowedParameterKinds.Add('TimeoutSeconds', 'int32')
$allowedParameterKinds.Add('ReadOnly', 'switch')
$allowedParameterKinds.Add('Output', 'string')
$seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$targetParameters = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
foreach ($entry in @($request.parameters)) {
    if ($entry -isnot [System.Collections.IDictionary]) {
        throw 'Dispatcher parameter entries must be JSON objects.'
    }
    Assert-ExactKeys -Value $entry -Expected @('name', 'kind', 'value') -Label 'Dispatcher parameter entry'
    $name = $entry.name
    $kind = $entry.kind
    if ($name -isnot [string] -or $kind -isnot [string] -or
        -not $allowedParameterKinds.ContainsKey($name) -or
        [string]$allowedParameterKinds[$name] -cne $kind -or
        -not $seenNames.Add($name)) {
        throw 'Dispatcher parameter identity is invalid.'
    }

    switch ($kind) {
        'string' {
            if ($entry.value -isnot [string]) { throw "Dispatcher parameter '$name' must be a string." }
            $targetParameters[$name] = [string]$entry.value
        }
        'string-array' {
            if ($entry.value -isnot [array] -or @($entry.value | Where-Object { $_ -isnot [string] }).Count -gt 0) {
                throw "Dispatcher parameter '$name' must be an array of strings."
            }
            $targetParameters[$name] = [string[]]@($entry.value)
        }
        'int32' {
            if (($entry.value -isnot [int] -and $entry.value -isnot [long]) -or
                [long]$entry.value -lt [int]::MinValue -or [long]$entry.value -gt [int]::MaxValue) {
                throw "Dispatcher parameter '$name' must be an Int32."
            }
            $targetParameters[$name] = [int]$entry.value
        }
        'switch' {
            if ($entry.value -isnot [bool]) { throw "Dispatcher parameter '$name' must be a Boolean switch value." }
            $targetParameters[$name] = [bool]$entry.value
        }
        default { throw "Dispatcher parameter '$name' has an unsupported kind." }
    }
}

if ($targetParameters.Contains('Output')) {
    $expectedOutput = [System.IO.Path]::GetFullPath($ExpectedOutputPath)
    $requestedOutput = [System.IO.Path]::GetFullPath([string]$targetParameters.Output)
    if (-not $requestedOutput.Equals($expectedOutput, $pathComparison)) {
        throw 'Dispatcher Output parameter does not match the supervisor output path.'
    }
}

# The request is parsed only as typed data. No request value is evaluated as PowerShell source.
try {
    [System.IO.File]::Delete($resolvedRequestPath)
    if (Test-Path -LiteralPath $resolvedRequestPath) {
        throw 'dispatch request still exists after delete'
    }
} catch {
    throw "Dispatcher request cleanup failed: $($_.Exception.Message)"
}
& $resolvedTargetPath @targetParameters *>&1
$exitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if ($null -eq $exitCodeVariable -or $exitCodeVariable.Value -isnot [int]) { exit 0 }
exit ([int]$exitCodeVariable.Value)
