[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$Environment=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$VerbosePreference='SilentlyContinue'
$InformationPreference='SilentlyContinue'
$utf8=[Text.UTF8Encoding]::new($false,$true)
[Console]::InputEncoding=$utf8
[Console]::OutputEncoding=$utf8
$OutputEncoding=$utf8

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.ControlledWrite.psm1') -Force -ErrorAction Stop

function Write-McpMessage {
    param($Value)
    [Console]::Out.WriteLine(($Value|ConvertTo-Json -Depth 64 -Compress))
    [Console]::Out.Flush()
}

function ConvertFrom-McpJsonElement {
    param([Parameter(Mandatory)][Text.Json.JsonElement]$Element)
    switch($Element.ValueKind){
        'Object'{$value=[Management.Automation.OrderedHashtable]::new();foreach($property in $Element.EnumerateObject()){if($value.Contains($property.Name)){throw 'duplicate JSON object key'};$value[$property.Name]=ConvertFrom-McpJsonElement -Element $property.Value};return $value}
        'Array'{$items=[Collections.Generic.List[object]]::new();foreach($item in $Element.EnumerateArray()){$items.Add((ConvertFrom-McpJsonElement -Element $item))};return ,$items.ToArray()}
        'String'{return $Element.GetString()}
        'Number'{[long]$integer=0;if($Element.TryGetInt64([ref]$integer)){return $integer};[decimal]$decimal=0;if($Element.TryGetDecimal([ref]$decimal)){return $decimal};return $Element.GetDouble()}
        'True'{return $true}
        'False'{return $false}
        'Null'{return $null}
        default{throw 'unsupported JSON value kind'}
    }
}

function ConvertFrom-McpJson {
    param([string]$Json)
    $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=64;$options.AllowTrailingCommas=$false;$options.CommentHandling=[Text.Json.JsonCommentHandling]::Disallow
    $document=[Text.Json.JsonDocument]::Parse($Json,$options)
    try{return ConvertFrom-McpJsonElement -Element $document.RootElement}finally{$document.Dispose()}
}

function New-McpError {
    param($Id,[int]$Code,[string]$Message)
    return [ordered]@{jsonrpc='2.0';id=$Id;error=[ordered]@{code=$Code;message=$Message}}
}

function New-McpResult {
    param($Id,$Result)
    return [ordered]@{jsonrpc='2.0';id=$Id;result=$Result}
}

function Test-McpExactKeys {
    param([Collections.IDictionary]$Value,[string[]]$Required,[string[]]$Optional=@())
    if($null-eq$Value){return $false}
    $actual=@($Value.Keys|ForEach-Object{[string]$_})
    return @($Required|Where-Object{$actual-cnotcontains$_}).Count-eq0-and@($actual|Where-Object{$_-cnotin@($Required+$Optional)}).Count-eq0
}

function Get-McpSha256Text {
    param([string]$Text)
    return 'sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant())
}

function Get-McpToolDefinition {
    return [ordered]@{
        name='write_file'
        description='Atomically write one workspace file after Harness path, policy, workflow, governance, and compare-and-swap validation.'
        inputSchema=[ordered]@{
            type='object';additionalProperties=$false
            properties=[ordered]@{
                path=[ordered]@{type='string';minLength=1}
                content=[ordered]@{type='string'}
                expected_current_sha256=[ordered]@{type='string';pattern='^(?:missing|sha256:[0-9a-f]{64})$'}
                task_id=[ordered]@{type='string'}
                expected_version=[ordered]@{type='integer';minimum=1}
                execution_profile=[ordered]@{type='string';enum=@('governed','critical')}
                contract_path=[ordered]@{type='string'}
                contract_digest=[ordered]@{type='string';pattern='^sha256:[0-9a-f]{64}$'}
                approval_id=[ordered]@{type='string'}
                dry_run=[ordered]@{type='boolean'}
            }
            required=@('path','content','expected_current_sha256')
        }
        annotations=[ordered]@{readOnlyHint=$false;destructiveHint=$true;idempotentHint=$false;openWorldHint=$false}
    }
}

function Invoke-McpWriteTool {
    param([Collections.IDictionary]$Arguments)
    $required=@('path','content','expected_current_sha256')
    $optional=@('task_id','expected_version','execution_profile','contract_path','contract_digest','approval_id','dry_run')
    if(-not(Test-McpExactKeys -Value $Arguments -Required $required -Optional $optional)){throw 'write_file arguments have missing or unknown fields'}
    foreach($name in @('path','content','expected_current_sha256','task_id','execution_profile','contract_path','contract_digest','approval_id')){if($Arguments.Contains($name)-and$Arguments[$name]-isnot[string]){throw "write_file argument '$name' must be a string"}}
    if($Arguments.Contains('expected_version')-and($Arguments.expected_version-isnot[int]-and$Arguments.expected_version-isnot[long])){throw "write_file argument 'expected_version' must be an integer"}
    if($Arguments.Contains('dry_run')-and$Arguments.dry_run-isnot[bool]){throw "write_file argument 'dry_run' must be a boolean"}
    $invoke=@{RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot;Environment=$Environment;Path=[string]$Arguments.path;Content=[string]$Arguments.content;ExpectedSourceDigest=(Get-McpSha256Text -Text ([string]$Arguments.content));ExpectedCurrentDigest=[string]$Arguments.expected_current_sha256}
    if($Arguments.Contains('task_id')){$invoke.TaskId=[string]$Arguments.task_id}
    if($Arguments.Contains('expected_version')){$invoke.ExpectedVersion=[int]$Arguments.expected_version}
    if($Arguments.Contains('execution_profile')){$invoke.ExecutionProfile=[string]$Arguments.execution_profile}
    if($Arguments.Contains('contract_path')){$invoke.ContractPath=[string]$Arguments.contract_path}
    if($Arguments.Contains('contract_digest')){$invoke.ContractDigest=[string]$Arguments.contract_digest}
    if($Arguments.Contains('approval_id')){$invoke.ApprovalId=[string]$Arguments.approval_id}
    if($Arguments.Contains('dry_run')){$invoke.DryRun=[bool]$Arguments.dry_run}
    return Invoke-HarnessControlledWrite @invoke
}

while($true){
    $line=[Console]::In.ReadLine()
    if($null-eq$line){break}
    $request=$null;$id=$null;$hasId=$false
    try{$request=ConvertFrom-McpJson -Json $line}catch{Write-McpMessage (New-McpError -Id $null -Code -32700 -Message 'Parse error');continue}
    if($request-isnot[Collections.IDictionary]-or-not$request.Contains('jsonrpc')-or[string]$request.jsonrpc-cne'2.0'-or-not$request.Contains('method')-or$request.method-isnot[string]){Write-McpMessage (New-McpError -Id $null -Code -32600 -Message 'Invalid Request');continue}
    $hasId=$request.Contains('id');if($hasId){$id=$request.id}
    $method=[string]$request.method
    if(-not$hasId){continue}
    try{
        switch($method){
            'initialize'{
                $result=[ordered]@{protocolVersion='2025-11-25';capabilities=[ordered]@{tools=[ordered]@{listChanged=$false}};serverInfo=[ordered]@{name='dev-harness-write';version='1.0.0'};instructions='Writes are confined to the configured workspace and enforced by Harness policy.'}
                Write-McpMessage (New-McpResult -Id $id -Result $result)
            }
            'ping'{Write-McpMessage (New-McpResult -Id $id -Result ([ordered]@{}))}
            'tools/list'{Write-McpMessage (New-McpResult -Id $id -Result ([ordered]@{tools=@(Get-McpToolDefinition)}))}
            'tools/call'{
                if(-not$request.Contains('params')-or$request.params-isnot[Collections.IDictionary]-or-not(Test-McpExactKeys -Value $request.params -Required @('name','arguments') -Optional @('_meta'))-or$request.params.name-isnot[string]-or$request.params.arguments-isnot[Collections.IDictionary]-or($request.params.Contains('_meta')-and$request.params._meta-isnot[Collections.IDictionary])){Write-McpMessage (New-McpError -Id $id -Code -32602 -Message 'Invalid params');continue}
                if([string]$request.params.name-cne'write_file'){Write-McpMessage (New-McpError -Id $id -Code -32602 -Message 'Unknown tool');continue}
                try{
                    $toolResult=Invoke-McpWriteTool -Arguments $request.params.arguments
                    $text=$toolResult|ConvertTo-Json -Depth 20 -Compress
                    Write-McpMessage (New-McpResult -Id $id -Result ([ordered]@{content=@([ordered]@{type='text';text=$text});structuredContent=$toolResult;isError=$false}))
                }catch{
                    Write-McpMessage (New-McpResult -Id $id -Result ([ordered]@{content=@([ordered]@{type='text';text=$_.Exception.Message});isError=$true}))
                }
            }
            default{Write-McpMessage (New-McpError -Id $id -Code -32601 -Message 'Method not found')}
        }
    }catch{
        [Console]::Error.WriteLine('internal MCP server error')
        Write-McpMessage (New-McpError -Id $id -Code -32603 -Message 'Internal error')
    }
}
