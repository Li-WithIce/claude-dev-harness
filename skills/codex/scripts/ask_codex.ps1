#!/usr/bin/env pwsh
#requires -Version 7.3

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'invoke_codex.ps1') @args
