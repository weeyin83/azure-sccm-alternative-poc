#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$summaryScript = Join-Path $PSScriptRoot '../../scripts/discovery/Get-ArcTelemetrySummary.ps1'
$reportPath = [System.IO.Path]::GetTempFileName()
$script:subscription = [guid]::NewGuid().ToString()
$script:workspaceGuid = [guid]::NewGuid().ToString()
$script:workspaceId = "/subscriptions/$script:subscription/resourceGroups/test/providers/Microsoft.OperationalInsights/workspaces/shared"
$script:machine1 = "/subscriptions/$script:subscription/resourceGroups/test/providers/Microsoft.HybridCompute/machines/server-one"
$script:machine2 = "/subscriptions/$script:subscription/resourceGroups/test/providers/Microsoft.HybridCompute/machines/server-two"
$telemetryTestState = @{
    Scenario = 'Healthy'
    RequestCount = 0
    CliCalls = [System.Collections.Generic.List[string]]::new()
    Machine1 = $script:machine1
    Machine2 = $script:machine2
    ExpectedMachines = @($script:machine1)
}

function Assert-Telemetry {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-TestReport {
    param(
        [string] $Status = 'CollectedPendingReview',
        [int] $AgeHours = 0,
        [bool] $FailCheck = $false,
        [bool] $MalformedCheck = $false,
        [bool] $InvalidWorkspaceGuid = $false,
        [bool] $DuplicateServer = $false
    )
    $report = @{
        SchemaVersion = '1.0'
        GeneratedAtUtc = [datetime]::UtcNow.AddHours(-$AgeHours).ToString('o')
        Status = $Status
        Checks = @(@{ Status = if ($FailCheck) { 'Failed' } else { 'Succeeded' } })
        Workspaces = @(@{ Id = $script:workspaceId })
        Resources = @(@{
                id = $script:workspaceId
                type = 'Microsoft.OperationalInsights/workspaces'
                properties = @{ customerId = $script:workspaceGuid }
            })
        Servers = @(@{ Id = $script:machine1 }, @{ Id = $script:machine2 })
    }
    if ($MalformedCheck) { $report.Checks += 'invalid check' }
    if ($InvalidWorkspaceGuid) { $report.Resources[0].properties.customerId = 'invalid' }
    if ($DuplicateServer) { $report.Servers += @{ Id = $script:machine1 } }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

function az {
    $command = (@($args) | Select-Object -First 2) -join ' '
    $telemetryTestState.CliCalls.Add($command)
    $global:LASTEXITCODE = 0
    switch ($command) {
        'cloud show' {
            if ($telemetryTestState.Scenario -eq 'OtherCloud') { return 'AzureUSGovernment' }
            return 'AzureCloud'
        }
        'account get-access-token' {
            if ($telemetryTestState.Scenario -eq 'TokenFailure') {
                $global:LASTEXITCODE = 1
                return 'Mock token failure'
            }
            return 'abc.def.ghi'
        }
        default { throw "Unexpected Azure CLI command: $command" }
    }
}

function Invoke-TestLogsQuery {
    [CmdletBinding()]
    param([string] $Method, [string] $Uri, [hashtable] $Headers, [int] $TimeoutSec)

    $telemetryTestState.RequestCount++
    $parsed = [uri] $Uri
    $decoded = [uri]::UnescapeDataString($Uri)
    Assert-Telemetry ($Method -eq 'Get') 'Only GET queries are permitted'
    Assert-Telemetry ($parsed.Scheme -eq 'https' -and $parsed.Host -eq 'api.loganalytics.azure.com') 'The token is sent only to the documented public endpoint'
    Assert-Telemetry ($Headers.Authorization -eq 'Bearer abc.def.ghi') 'The token is supplied through the authorization header'
    Assert-Telemetry ($TimeoutSec -eq 60) 'A bounded request timeout is used'
    foreach ($machine in @($telemetryTestState.Machine1, $telemetryTestState.Machine2)) {
        Assert-Telemetry ($decoded.Contains($machine) -eq ($machine -in $telemetryTestState.ExpectedMachines)) 'The query contains only explicitly selected servers'
    }
    Assert-Telemetry ($decoded.Contains('timespan=PT24H')) 'The requested time range is bounded'
    if ($telemetryTestState.Scenario -eq 'HttpError') {
        throw "Mock error with private ID $($telemetryTestState.Machine1) and token abc.def.ghi"
    }
    if ($telemetryTestState.Scenario -eq 'Partial') {
        return [pscustomobject]@{ error = @{ code = 'PartialError' }; tables = @() }
    }
    if ($telemetryTestState.Scenario -eq 'NullResponse') { return $null }
    if ($telemetryTestState.Scenario -eq 'MalformedTable') {
        return [pscustomobject]@{ tables = @([pscustomobject]@{ columns = @() }) }
    }
    $row = if ($telemetryTestState.Scenario -eq 'Empty') {
        [object[]] @(0, 0, $null)
    }
    elseif ($telemetryTestState.Scenario -eq 'InvalidCount') {
        [object[]] @(1, 2, '2026-01-01T00:00:00Z')
    }
    else {
        [object[]] @(12, 1, '2026-01-01T00:00:00Z')
    }
    $rows = [object[]]::new(1)
    $rows[0] = $row
    $columns = @(
        [pscustomobject]@{ name = 'Rows' }
        [pscustomobject]@{ name = 'ServersWithData' }
        [pscustomobject]@{ name = if ($telemetryTestState.Scenario -eq 'WrongColumns') { 'Wrong' } else { 'LastObserved' } }
    )
    return [pscustomobject]@{ tables = @([pscustomobject]@{ columns = $columns; rows = $rows }) }
}
Set-Alias -Name Invoke-RestMethod -Value Invoke-TestLogsQuery -Scope Script

function Assert-SummaryFailure {
    param([scriptblock] $Operation, [string] $ExpectedText)
    $failed = $false
    try { $null = & $Operation }
    catch {
        $failed = $true
        $message = $_.Exception.Message
        Assert-Telemetry ($message.Contains($ExpectedText)) 'Failure reports the reason'
        Assert-Telemetry (-not $message.Contains($script:machine1)) 'Failure does not disclose a resource ID'
        Assert-Telemetry (-not $message.Contains('abc.def.ghi')) 'Failure does not disclose the token'
    }
    Assert-Telemetry $failed 'Invalid input or API failure must terminate'
}

try {
    Write-TestReport
    $telemetryTestState.Scenario = 'Healthy'
    $telemetryTestState.RequestCount = 0
    $result = @(& $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1)
    Assert-Telemetry ($result.Count -eq 5 -and $telemetryTestState.RequestCount -eq 5) 'All five tables are queried once'
    Assert-Telemetry ($result[0].Table -eq 'Heartbeat' -and $result[0].Rows -eq 12 -and $result[0].ServersWithData -eq 1) 'Aggregate values are returned'
    Assert-Telemetry (($result | ConvertTo-Json -Compress) -notmatch [regex]::Escape($script:machine1)) 'Output does not contain server IDs'
    Assert-Telemetry (@($telemetryTestState.CliCalls | Where-Object { $_ -notin @('cloud show', 'account get-access-token') }).Count -eq 0) 'Only read-only Azure CLI calls are used'
    Write-Output 'PASS: Healthy'

    $telemetryTestState.ExpectedMachines = @($script:machine1, $script:machine2)
    $result = @(& $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId @($script:machine1, $script:machine2))
    Assert-Telemetry (@($result | Where-Object { $_.SelectedServers -ne 2 }).Count -eq 0) 'Multiple explicitly selected servers are retained'
    $telemetryTestState.ExpectedMachines = @($script:machine1)
    Write-Output 'PASS: Multiple servers'

    $telemetryTestState.Scenario = 'Empty'
    $result = @(& $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1)
    Assert-Telemetry (@($result | Where-Object { $_.Rows -ne 0 -or $null -ne $_.LastObservedUtc }).Count -eq 0) 'Zero data remains explicit'
    Write-Output 'PASS: Empty'

    foreach ($case in @(
            @{ Scenario = 'Partial'; Message = 'partial error' }
            @{ Scenario = 'HttpError'; Message = 'failed' }
            @{ Scenario = 'InvalidCount'; Message = 'invalid counts' }
            @{ Scenario = 'WrongColumns'; Message = 'unexpected columns' }
            @{ Scenario = 'NullResponse'; Message = 'empty response' }
            @{ Scenario = 'MalformedTable'; Message = 'unexpected table shape' }
            @{ Scenario = 'OtherCloud'; Message = 'public cloud' }
            @{ Scenario = 'TokenFailure'; Message = 'could not obtain' }
        )) {
        $telemetryTestState.Scenario = $case.Scenario
        Assert-SummaryFailure -ExpectedText $case.Message -Operation {
            & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
        }
        Write-Output "PASS: $($case.Scenario)"
    }

    $telemetryTestState.Scenario = 'Healthy'
    Write-TestReport -Status 'Incomplete'
    Assert-SummaryFailure -ExpectedText 'complete discovery report' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -FailCheck $true
    Assert-SummaryFailure -ExpectedText 'checks are missing or incomplete' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -MalformedCheck $true
    Assert-SummaryFailure -ExpectedText 'checks are missing or incomplete' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -AgeHours 25
    Assert-SummaryFailure -ExpectedText 'stale or future-dated' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -AgeHours -1
    Assert-SummaryFailure -ExpectedText 'stale or future-dated' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -InvalidWorkspaceGuid $true
    Assert-SummaryFailure -ExpectedText 'no valid Log Analytics workspace ID' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport -DuplicateServer $true
    Assert-SummaryFailure -ExpectedText 'must occur exactly once' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-TestReport
    Assert-SummaryFailure -ExpectedText 'workspace must occur exactly once' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId ($script:workspaceId + '-other') -ServerResourceId $script:machine1
    }
    Assert-SummaryFailure -ExpectedText 'must occur exactly once' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId ($script:machine1 + '-other')
    }
    Assert-SummaryFailure -ExpectedText 'duplicate IDs' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId @($script:machine1, $script:machine1.ToUpperInvariant())
    }
    Set-Content -LiteralPath $reportPath -Value '{invalid json with abc.def.ghi' -Encoding utf8
    Assert-SummaryFailure -ExpectedText 'not valid JSON' -Operation {
        & $summaryScript -ReportPath $reportPath -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Assert-SummaryFailure -ExpectedText 'could not be read' -Operation {
        & $summaryScript -ReportPath ($reportPath + '-missing') -WorkspaceResourceId $script:workspaceId -ServerResourceId $script:machine1
    }
    Write-Output 'PASS: Input guards'
}
finally {
    Remove-Item -LiteralPath $reportPath -ErrorAction Stop
}
