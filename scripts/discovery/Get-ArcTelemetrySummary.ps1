#Requires -Version 7.2
<#
.SYNOPSIS
Returns aggregate telemetry availability for explicitly selected Arc servers.
.DESCRIPTION
Reads a recent, complete discovery report and queries only the nominated
existing workspace. It returns counts and timestamps, not guest records or
resource IDs. The query is read-only and can incur Azure Monitor query charges.
No result proves agent health, complete coverage or a successful deployment.
.PARAMETER ReportPath
Path to a private, complete report.json produced by Invoke-ArcDiscovery.ps1.
.PARAMETER WorkspaceResourceId
Resource ID of the owner-approved existing workspace in the report.
.PARAMETER ServerResourceId
One to ten Arc machine resource IDs present in the report.
.PARAMETER LookbackHours
Bounded query interval in hours; defaults to 24.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ReportPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WorkspaceResourceId,

    [Parameter(Mandatory)]
    [ValidateCount(1, 10)]
    [ValidateNotNullOrEmpty()]
    [string[]] $ServerResourceId,

    [ValidateRange(1, 48)]
    [int] $LookbackHours = 24
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required to obtain a read-only Logs API token.'
}

Import-Module (Join-Path $PSScriptRoot 'ArcDiscoveryEvidence.psm1') -ErrorAction Stop
$report = Read-ArcDiscoveryReport -ReportPath $ReportPath
$scope = Resolve-ArcDiscoveryScope -Report $report -WorkspaceResourceId $WorkspaceResourceId -ServerResourceId $ServerResourceId

$cloud = & az cloud show --query name --output tsv --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0 -or ($cloud -join "`n").Trim() -ne 'AzureCloud') {
    throw 'The Logs API check currently supports an authenticated Azure public cloud context only.'
}
$tokenOutput = & az account get-access-token --subscription $scope.WorkspaceSubscription `
    --resource 'https://api.loganalytics.io' --query accessToken --output tsv --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI could not obtain a Logs API token for the workspace subscription.'
}
$token = ($tokenOutput -join "`n").Trim()
if ($token -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
    throw 'Azure CLI returned an invalid Logs API token response.'
}

$serverIdsJson = ConvertTo-Json -InputObject @($scope.ServerResourceIds) -Compress
$results = [System.Collections.Generic.List[object]]::new()
foreach ($tableName in @('Heartbeat', 'Perf', 'Event', 'ConfigurationData', 'ConfigurationChange')) {
    $query = @"
let ServerIds = dynamic($serverIdsJson);
$tableName
| where TimeGenerated >= ago(${LookbackHours}h)
| where _ResourceId in~ (ServerIds)
| summarize Rows=count(), ServersWithData=dcount(tolower(_ResourceId)), LastObserved=max(TimeGenerated)
"@
    $encodedQuery = [uri]::EscapeDataString($query)
    $uri = "https://api.loganalytics.azure.com/v1/workspaces/$($scope.WorkspaceGuid)/query?query=$encodedQuery&timespan=PT${LookbackHours}H"
    try {
        $response = Invoke-RestMethod -Method Get -Uri $uri `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 60
    }
    catch {
        $status = 'unavailable'
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($responseProperty -and $responseProperty.Value) {
            $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($statusProperty) { $status = [string] [int] $statusProperty.Value }
        }
        throw "The read-only Logs query for $tableName failed (HTTP status: $status). No results were accepted."
    }
    if ($null -eq $response) {
        throw "The read-only Logs query for $tableName returned an empty response."
    }
    if ($response.PSObject.Properties['error'] -and $null -ne $response.error) {
        throw "The read-only Logs query for $tableName returned a partial error. No results were accepted."
    }
    if (-not $response.PSObject.Properties['tables'] -or @($response.tables).Count -ne 1) {
        throw "The read-only Logs query for $tableName returned an unexpected table shape."
    }
    $table = $response.tables[0]
    if ($null -eq $table -or -not $table.PSObject.Properties['columns'] -or
        -not $table.PSObject.Properties['rows']) {
        throw "The read-only Logs query for $tableName returned an unexpected table shape."
    }
    $columnNames = @($table.columns | ForEach-Object { $_.name })
    $rows = @($table.rows)
    if ($columnNames.Count -ne 3 -or $rows.Count -ne 1 -or @($rows[0]).Count -ne 3) {
        throw "The read-only Logs query for $tableName returned an unexpected row shape."
    }
    $rowIndex = [array]::IndexOf($columnNames, 'Rows')
    $serverIndex = [array]::IndexOf($columnNames, 'ServersWithData')
    $timeIndex = [array]::IndexOf($columnNames, 'LastObserved')
    if ($rowIndex -lt 0 -or $serverIndex -lt 0 -or $timeIndex -lt 0) {
        throw "The read-only Logs query for $tableName returned unexpected columns."
    }
    $count = [long] 0
    $serverCount = [long] 0
    if (-not [long]::TryParse([string] $rows[0][$rowIndex], [ref] $count) -or
        -not [long]::TryParse([string] $rows[0][$serverIndex], [ref] $serverCount) -or
        $count -lt 0 -or $serverCount -lt 0 -or
        $serverCount -gt $scope.ServerResourceIds.Count -or $serverCount -gt $count) {
        throw "The read-only Logs query for $tableName returned invalid counts."
    }
    $lastObserved = $null
    $rawTime = $rows[0][$timeIndex]
    if ($null -ne $rawTime) {
        try { $lastObserved = ([datetimeoffset] $rawTime).ToUniversalTime().ToString('o') }
        catch { throw "The read-only Logs query for $tableName returned an invalid timestamp." }
    }
    if (($count -eq 0 -and $null -ne $lastObserved) -or
        ($count -gt 0 -and ($null -eq $lastObserved -or $serverCount -eq 0))) {
        throw "The read-only Logs query for $tableName returned inconsistent aggregate values."
    }
    $results.Add([pscustomobject]@{
            Table = $tableName
            LookbackHours = $LookbackHours
            SelectedServers = $scope.ServerResourceIds.Count
            ServersWithData = $serverCount
            Rows = $count
            LastObservedUtc = $lastObserved
        })
}
$results
