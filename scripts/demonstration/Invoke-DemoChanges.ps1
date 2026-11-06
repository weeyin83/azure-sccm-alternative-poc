#Requires -Version 7.4
<#
.SYNOPSIS
Prepares, changes or restores synthetic items on one designated Windows test server.
.DESCRIPTION
This Build-phase script is not approval to run a demonstration. It operates
locally, records private recovery state and never installs software or calls
Azure. A test event and bounded CPU load are optional and explicitly requested.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Prepare')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $TestComputerName,
    [Parameter(Mandatory)][switch] $AcknowledgeTestOnly,

    [Parameter(Mandatory, ParameterSetName = 'Prepare')][ValidateNotNullOrEmpty()][string] $TestServiceName,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][ValidateNotNullOrEmpty()][string] $TestFilePath,
    [Parameter(Mandatory, ParameterSetName = 'Prepare')][ValidateNotNullOrEmpty()][string] $TestRegistryKey,

    [Parameter(Mandatory, ParameterSetName = 'Change')][switch] $Change,
    [Parameter(Mandatory, ParameterSetName = 'Change')][switch] $BaselineObserved,
    [Parameter(Mandatory, ParameterSetName = 'Revert')][switch] $Revert,
    [Parameter(Mandatory, ParameterSetName = 'Change')]
    [Parameter(Mandatory, ParameterSetName = 'Revert')]
    [ValidateNotNullOrEmpty()][string] $StatePath,

    [Parameter(ParameterSetName = 'Change')][switch] $WriteTestEvent,
    [Parameter(ParameterSetName = 'Change')][string] $EventSource,
    [Parameter(ParameterSetName = 'Change')][int] $EventId,
    [Parameter(ParameterSetName = 'Change')][ValidateRange(0, 15)][int] $CpuSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (($PSCmdlet.ParameterSetName -eq 'Change' -and -not $Change) -or
    ($PSCmdlet.ParameterSetName -eq 'Revert' -and -not $Revert)) {
    throw 'The selected change or revert switch must be explicitly enabled.'
}

Import-Module (Join-Path $PSScriptRoot 'ArcDemoEngine.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ArcDemoHost.psm1') -ErrorAction Stop
$mode = $PSCmdlet.ParameterSetName
$parameters = @{
    Adapter = Get-ArcDemoWindowsAdapter
    Mode = $mode
    ComputerName = $TestComputerName
    AcknowledgeTestOnly = $AcknowledgeTestOnly
    WhatIf = $WhatIfPreference
}
if ($PSBoundParameters.ContainsKey('Confirm')) { $parameters['Confirm'] = $PSBoundParameters['Confirm'] }
if ($mode -eq 'Prepare') {
    $parameters['ServiceName'] = $TestServiceName
    $parameters['FilePath'] = $TestFilePath
    $parameters['RegistryKey'] = $TestRegistryKey
}
else {
    $parameters['StatePath'] = $StatePath
}
if ($mode -eq 'Change') {
    $parameters['BaselineObserved'] = $BaselineObserved
    $parameters['WriteTestEvent'] = $WriteTestEvent
    $parameters['EventSource'] = $EventSource
    $parameters['EventId'] = $EventId
    $parameters['CpuSeconds'] = $CpuSeconds
}
Invoke-ArcDemoEngine @parameters
