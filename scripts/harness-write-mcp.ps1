[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$Environment=''
)

$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'
$utf8=[Text.UTF8Encoding]::new($false,$true)
[Console]::InputEncoding=$utf8
[Console]::OutputEncoding=$utf8
$OutputEncoding=$utf8

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.AdapterAction.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'lib\Harness.RuntimeKernel.ps1')

function Send-McpMessage {
    param($Message)
    [Console]::Out.WriteLine(($Message | ConvertTo-Json -Depth 64 -Compress))
    [Console]::Out.Flush()
}

function New-McpMessage {
    param($Id,$Result,[int]$ErrorCode=0,[string]$ErrorMessage='')
    $message = [ordered]@{jsonrpc='2.0'
        id=$Id}
    if ($ErrorCode) { $Result = [ordered]@{code=$ErrorCode;message=$ErrorMessage} }
    $message[$(if($ErrorCode){'error'}else{'result'})] = $Result
    return $message
}

function New-McpToolResult {
    param($Value,[switch]$Error)
    $text = if ($Error) { [string]$Value } else { $Value | ConvertTo-Json -Depth 20 -Compress }
    $result = [ordered]@{content=@([ordered]@{type='text';text=$text});isError=[bool]$Error}
    if (-not $Error) { $result.structuredContent = $Value }
    return $result
}

$script:ToolDefinition = [ordered]@{name='write_file'
    description='Atomically write one workspace file after Harness path, policy, workflow, governance, and compare-and-swap validation.'
    inputSchema=Read-HarnessKernelJsonPath -Path (Join-Path $RepoRoot 'schemas\mcp-write-file.schema.json') -Label 'write_file schema'
    annotations=[ordered]@{readOnlyHint=$false
        destructiveHint=$true
        idempotentHint=$false
        openWorldHint=$false}}
$script:StaticResults = [ordered]@{
    initialize=[ordered]@{protocolVersion='2025-11-25'
        capabilities=[ordered]@{tools=[ordered]@{listChanged=$false}}
        serverInfo=[ordered]@{name='dev-harness-write';version='1.0.0'}
        instructions='Writes are confined to the configured workspace and enforced by Harness policy.'}
    ping=[ordered]@{}
    'tools/list'=[ordered]@{tools=@($script:ToolDefinition)}
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    try {
        $request = ConvertFrom-HarnessKernelJson -Json $line -Label 'MCP request'
    } catch {
        Send-McpMessage (New-McpMessage -Id $null -ErrorCode -32700 -ErrorMessage 'Parse error')
        continue
    }
    if (-not ($request -is [Collections.IDictionary] -and $request.Contains('jsonrpc') -and
        [string]$request.jsonrpc -ceq '2.0' -and $request.Contains('method') -and
        $request.method -is [string])) {
        Send-McpMessage (New-McpMessage -Id $null -ErrorCode -32600 -ErrorMessage 'Invalid Request')
        continue
    }
    if (-not $request.Contains('id')) { continue }
    $id = $request.id
    try {
        $response = if ($script:StaticResults.Contains([string]$request.method)) {
            New-McpMessage -Id $id -Result $script:StaticResults[[string]$request.method]
        } elseif ([string]$request.method -ceq 'tools/call') {
                $params = if ($request.Contains('params')) { $request.params } else { $null }
                if (-not ($params -is [Collections.IDictionary] -and
                    $params.Contains('name') -and $params.Contains('arguments') -and
                    -not @($params.Keys | Where-Object { [string]$_ -cnotin @('name','arguments','_meta') }).Count -and
                    $params.name -is [string] -and
                    $params.arguments -is [Collections.IDictionary] -and
                    (-not $params.Contains('_meta') -or $params._meta -is [Collections.IDictionary]))) {
                    New-McpMessage -Id $id -ErrorCode -32602 -ErrorMessage 'Invalid params'
                } elseif ([string]$params.name -cne 'write_file') {
                    New-McpMessage -Id $id -ErrorCode -32602 -ErrorMessage 'Unknown tool'
                } else {
                    try {
                        Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $params.arguments -Schema mcp-write-file.schema.json -Label 'write_file arguments' -FailureMessage 'write_file arguments have missing, unknown, or invalid fields'
                        $body = (Invoke-HarnessAdapterControlledWrite -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot `
                            -Environment $Environment -TargetPath $params.arguments.path -Content $params.arguments.content `
                            -ExpectedCurrentSha256 $params.arguments.expected_current_sha256 -TaskId ([string]$params.arguments['task_id']) `
                            -ExpectedVersion $params.arguments['expected_version'] -ExecutionProfile ([string]$params.arguments['execution_profile']) `
                            -ContractPath ([string]$params.arguments['contract_path']) -ContractDigest ([string]$params.arguments['contract_digest']) `
                            -ApprovalId ([string]$params.arguments['approval_id']) -DryRun $params.arguments['dry_run']).body
                        [void]$body.Remove('operation')
                        $result = New-McpToolResult -Value $body
                    } catch {
                        $result = New-McpToolResult -Value $_.Exception.Message -Error
                    }
                    New-McpMessage -Id $id -Result $result
                }
        } else {
            New-McpMessage -Id $id -ErrorCode -32601 -ErrorMessage 'Method not found'
        }
    } catch {
        [Console]::Error.WriteLine('internal MCP server error')
        $response = New-McpMessage -Id $id -ErrorCode -32603 -ErrorMessage 'Internal error'
    }
    Send-McpMessage $response
}
