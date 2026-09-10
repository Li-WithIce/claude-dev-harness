. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
Export-ModuleMember -Function New-HarnessProtectedOperation,Resolve-HarnessProtectedOperation,Resolve-HarnessApprovalInput,Assert-HarnessTaskApproval
