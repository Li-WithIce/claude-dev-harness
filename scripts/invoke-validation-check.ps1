#!/usr/bin/env pwsh
#requires -Version 7.3
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-RawObjectKeys {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        throw "$Context must be a JSON object."
    }
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Expected) { [void]$expectedSet.Add($name) }
    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if (-not $actualSet.Add($property.Name)) { throw "$Context contains a duplicate property." }
        if (-not $expectedSet.Contains($property.Name)) { throw "$Context contains an unexpected property." }
    }
    if ($actualSet.Count -ne $expectedSet.Count) { throw "$Context is missing a required property." }
}

function Read-ValidationRequest {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $scratchDirectory = [IO.Directory]::GetParent($resolved)
    $scratchNameMatch = if ($null -eq $scratchDirectory) {
        $null
    } else {
        [Text.RegularExpressions.Regex]::Match(
            $scratchDirectory.Name,
            '^dev-harness-validation-([0-9a-f]{32})$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
    }
    if ($null -eq $scratchDirectory -or
        [IO.Path]::GetFileName($resolved) -cne 'request.json' -or
        $null -eq $scratchNameMatch -or -not $scratchNameMatch.Success -or
        $null -eq $scratchDirectory.Parent -or
        -not $scratchDirectory.Parent.FullName.Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Validation request path is outside the owned scratch shape.'
    }
    $pathToken = $scratchNameMatch.Groups[1].Value
    $tempItem = Get-Item -LiteralPath $tempRoot -Force -ErrorAction Stop
    $scratchItem = Get-Item -LiteralPath $scratchDirectory.FullName -Force -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($scratchItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -le 0 -or $item.Length -gt 1048576) {
        throw 'Validation request file is invalid.'
    }
    $document = $null
    $requestOwned = $false
    $request = $null
    try {
        $requestText = [IO.File]::ReadAllText($resolved,[Text.UTF8Encoding]::new($false,$true))
        $jsonOptions = [Text.Json.JsonDocumentOptions]::new()
        $jsonOptions.AllowTrailingCommas = $false
        $jsonOptions.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
        $jsonOptions.MaxDepth = 8
        $document = [Text.Json.JsonDocument]::Parse($requestText,$jsonOptions)
        $root = $document.RootElement
        Assert-RawObjectKeys -Element $root -Expected @(
            'schema_version','handshake_token','invocation_kind','target_path','working_directory','arguments','parameters'
        ) -Context 'Validation request'
        if ($root.GetProperty('schema_version').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $root.GetProperty('schema_version').GetString() -cne 'harness-validation-check/v1') {
            throw 'Validation request schema_version is invalid.'
        }
        $token = $root.GetProperty('handshake_token').GetString()
        if ($root.GetProperty('handshake_token').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            [string]::IsNullOrWhiteSpace($token) -or $token -cnotmatch '^[0-9a-f]{32}$' -or
            $token -cne $pathToken) {
            throw 'Validation request handshake_token is invalid.'
        }
        $requestOwned = $true
        $kind = $root.GetProperty('invocation_kind').GetString()
        if ($root.GetProperty('invocation_kind').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            $kind -cnotin @('Native','PowerShellScript')) {
            throw 'Validation request invocation_kind is invalid.'
        }
        $targetPath = $root.GetProperty('target_path').GetString()
        $workingDirectory = $root.GetProperty('working_directory').GetString()
        if ($root.GetProperty('target_path').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            [string]::IsNullOrWhiteSpace($targetPath) -or -not [IO.Path]::IsPathRooted($targetPath)) {
            throw 'Validation request target_path is invalid.'
        }
        if ($root.GetProperty('working_directory').ValueKind -ne [Text.Json.JsonValueKind]::String -or
            [string]::IsNullOrWhiteSpace($workingDirectory) -or -not [IO.Path]::IsPathRooted($workingDirectory)) {
            throw 'Validation request working_directory is invalid.'
        }
        $targetPath = [IO.Path]::GetFullPath($targetPath)
        $workingDirectory = [IO.Path]::GetFullPath($workingDirectory)
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
            throw 'Validation request target or working directory does not exist.'
        }
        if ($kind -ceq 'PowerShellScript' -and [IO.Path]::GetExtension($targetPath) -cne '.ps1') {
            throw 'PowerShell validation target must be a .ps1 file.'
        }

        $argumentsElement = $root.GetProperty('arguments')
        if ($argumentsElement.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $argumentsElement.GetArrayLength() -gt 2048) {
            throw 'Validation request arguments are invalid.'
        }
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in $argumentsElement.EnumerateArray()) {
            if ($argument.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'Validation request arguments must be strings.' }
            $value = $argument.GetString()
            if ($null -eq $value -or $value.Length -gt 32768) { throw 'Validation request argument is invalid.' }
            [void]$arguments.Add($value)
        }
        $parametersElement = $root.GetProperty('parameters')
        if ($parametersElement.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $parametersElement.GetArrayLength() -gt 256) {
            throw 'Validation request parameters are invalid.'
        }
        $parameterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $parameters = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($parameter in $parametersElement.EnumerateArray()) {
            Assert-RawObjectKeys -Element $parameter -Expected @('name','kind','value') -Context 'Validation parameter'
            if ($parameter.GetProperty('name').ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw 'Validation parameter name is invalid.'
            }
            $name = $parameter.GetProperty('name').GetString()
            if ([string]::IsNullOrWhiteSpace($name) -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9]*$' -or -not $parameterNames.Add($name)) {
                throw 'Validation parameter name is invalid or duplicated.'
            }
            if ($parameter.GetProperty('kind').ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw 'Validation parameter kind is invalid.'
            }
            $parameterKind = $parameter.GetProperty('kind').GetString()
            $valueElement = $parameter.GetProperty('value')
            $parameterValue = switch ($parameterKind) {
                'string' {
                    if ($valueElement.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'Validation string parameter value is invalid.' }
                    $valueElement.GetString()
                }
                'switch' {
                    if ($valueElement.ValueKind -notin @([Text.Json.JsonValueKind]::True,[Text.Json.JsonValueKind]::False)) { throw 'Validation switch parameter value is invalid.' }
                    $valueElement.GetBoolean()
                }
                'string_array' {
                    if ($valueElement.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $valueElement.GetArrayLength() -gt 2048) {
                        throw 'Validation string-array parameter value is invalid.'
                    }
                    @($valueElement.EnumerateArray() | ForEach-Object {
                        if ($_.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'Validation string-array item is invalid.' }
                        $_.GetString()
                    })
                }
                default { throw 'Validation parameter kind is unsupported.' }
            }
            $parameters.Add($name,$parameterValue)
        }
        if (($kind -ceq 'Native' -and $parameters.Count -ne 0) -or
            ($kind -ceq 'PowerShellScript' -and $arguments.Count -ne 0)) {
            throw 'Validation request mixed native arguments with PowerShell parameters.'
        }
        $request = [pscustomobject]@{
            Token = $token
            Kind = $kind
            TargetPath = $targetPath
            WorkingDirectory = $workingDirectory
            Arguments = $arguments.ToArray()
            Parameters = $parameters
        }
    } finally {
        if ($null -ne $document) { $document.Dispose() }
        if ($requestOwned) {
            $cleanupError = $null
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                try {
                    if ([IO.File]::Exists($resolved)) { [IO.File]::Delete($resolved) }
                    if ([IO.File]::Exists($resolved)) { throw 'Validation request file still exists.' }
                    if ([IO.Directory]::Exists($scratchDirectory.FullName)) {
                        [IO.Directory]::Delete($scratchDirectory.FullName,$false)
                    }
                    if ([IO.Directory]::Exists($scratchDirectory.FullName)) { throw 'Validation request directory still exists.' }
                    $cleanupError = $null
                    break
                } catch [IO.IOException] {
                    $cleanupError = $_
                } catch [UnauthorizedAccessException] {
                    $cleanupError = $_
                }
                Start-Sleep -Milliseconds 25
            }
            if ($null -ne $cleanupError) {
                throw "Owned validation request could not be removed before target entry: $($cleanupError.Exception.Message)"
            }
        }
    }
    return $request
}

$request = Read-ValidationRequest -Path $RequestPath
[Console]::Out.WriteLine(('READY:{0}' -f $request.Token))
[Console]::Out.Flush()
$command = [Console]::In.ReadLine()
if ($command -cne ('GO:{0}' -f $request.Token)) {
    [Console]::Error.WriteLine('Validation supervisor did not receive the authenticated start signal.')
    exit 125
}

if ($request.Kind -ceq 'PowerShellScript') {
    Push-Location $request.WorkingDirectory
    try {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        $targetParameters = $request.Parameters
        & $request.TargetPath @targetParameters
        $invocationSucceeded = $?
        $nativeExit = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        if ($null -ne $nativeExit -and [int]$nativeExit.Value -ne 0) { exit ([int]$nativeExit.Value) }
        if (-not $invocationSucceeded) { exit 1 }
        exit 0
    } catch {
        [Console]::Error.WriteLine(($_ | Out-String))
        exit 1
    } finally {
        Pop-Location
    }
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $request.TargetPath
$startInfo.WorkingDirectory = $request.WorkingDirectory
$startInfo.UseShellExecute = $false
foreach ($argument in $request.Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
try {
    if (-not $process.Start()) { throw 'Validation target did not start.' }
    $process.WaitForExit()
    exit $process.ExitCode
} finally {
    $process.Dispose()
}
