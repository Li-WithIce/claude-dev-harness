[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments)][AllowEmptyString()][string[]]$Values)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[ordered]@{
    values = @($Values)
    git_dir_removed = $null -eq [Environment]::GetEnvironmentVariable('GIT_DIR')
    sentinel_removed = $null -eq [Environment]::GetEnvironmentVariable('GIT_TK07_SENTINEL')
    optional_locks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS')
    terminal_prompt = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT')
    no_system_config = [Environment]::GetEnvironmentVariable('GIT_CONFIG_NOSYSTEM')
    no_system_attributes = [Environment]::GetEnvironmentVariable('GIT_ATTR_NOSYSTEM')
    global_config_disabled = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL') -ceq $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
} | ConvertTo-Json -Compress
