$ErrorActionPreference = 'Stop'

Import-Module PSScriptAnalyzer -ErrorAction Stop

Write-Output "PowerShell $($PSVersionTable.PSVersion)"
Write-Output "PSScriptAnalyzer $((Get-Module PSScriptAnalyzer).Version)"

$diagnostics = @(Invoke-ScriptAnalyzer -ScriptDefinition "Write-Output 'ready'")
if ($diagnostics.Count -ne 0) {
    $diagnostics | Out-String | Write-Output
    throw 'PSScriptAnalyzer smoke check returned unexpected diagnostics.'
}

Write-Output 'PowerShell smoke checks passed without downloads or cloud requests.'
