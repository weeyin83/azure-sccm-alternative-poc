#Requires -Version 7.4
[CmdletBinding()]
param([switch] $EmitSyntheticQueries)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$discoveryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/discovery'))
$scriptPath = Join-Path $PSScriptRoot '../../scripts/deployment/New-ArcAlertParameters.ps1'
$reviewScript = Join-Path $discoveryDirectory 'New-ArcCutoverReview.ps1'
Import-Module (Join-Path $discoveryDirectory 'ArcPrivateEvidence.psm1') -ErrorAction Stop

$subscription = [guid]::NewGuid().ToString()
$workspaceGuid = [guid]::NewGuid().ToString()
$prefix = "/subscriptions/$subscription/resourceGroups/test/providers/"
$workspaceId = $prefix + 'Microsoft.OperationalInsights/workspaces/shared'
$server1 = $prefix + 'Microsoft.HybridCompute/machines/server-one'
$server2 = $prefix + 'Microsoft.HybridCompute/machines/server-two'
$groupId = $prefix + 'Microsoft.Insights/actionGroups/existing'
$alertId = $prefix + 'Microsoft.Insights/metricAlerts/existing'
$testDirectory = New-ArcPrivateEvidenceDirectory -DiscoveryDirectory $discoveryDirectory `
    -DirectoryName ('alert-test-' + [guid]::NewGuid().ToString('N'))
$reportPath = New-ArcPrivateEvidenceFile -Directory $testDirectory -FileName 'report.json'
$configurationPath = New-ArcPrivateEvidenceFile -Directory $testDirectory -FileName 'configuration.json'
$createdOutputs = [System.Collections.Generic.List[string]]::new()

function Assert-AlertTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-TestReport {
    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @(
            "Subscription access: $subscription"
            "Arc Windows inventory: $subscription"
            "Policy assignments: $subscription"
            "Workspace linked services: $workspaceId"
            "Extensions: $server1"
            "DCR associations: $server1"
            "Extensions: $server2"
            "DCR associations: $server2"
        )) {
        $checks.Add(@{ Name = $name; Status = 'Succeeded' })
    }
    foreach ($type in @(
            'Microsoft.Insights/dataCollectionRules'
            'Microsoft.OperationalInsights/workspaces'
            'Microsoft.OperationsManagement/solutions'
            'Microsoft.Automation/automationAccounts'
            'Microsoft.Insights/metricAlerts'
            'Microsoft.Insights/scheduledQueryRules'
            'Microsoft.Insights/activityLogAlerts'
            'Microsoft.Insights/actionGroups'
        )) {
        $checks.Add(@{ Name = "Resource list: $subscription/$type"; Status = 'Succeeded' })
    }
    return @{
        SchemaVersion = '1.0'
        GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
        Status = 'CollectedPendingReview'
        SubscriptionScope = @($subscription)
        Checks = @($checks.ToArray())
        Workspaces = @(@{ Id = $workspaceId; Name = 'shared'; Location = 'uksouth' })
        Servers = @(
            @{
                Id = $server1; Location = 'uksouth'
                Extensions = @{ Status = 'Succeeded'; Items = @() }
                Associations = @{ Status = 'Succeeded'; Items = @() }
            }
            @{
                Id = $server2; Location = 'uksouth'
                Extensions = @{ Status = 'Succeeded'; Items = @() }
                Associations = @{ Status = 'Succeeded'; Items = @() }
            }
        )
        Resources = @(
            @{ id = $workspaceId; type = 'Microsoft.OperationalInsights/workspaces'; properties = @{ customerId = $workspaceGuid } }
            @{ id = $groupId; type = 'Microsoft.Insights/actionGroups'; properties = @{ enabled = $true; emailReceivers = @() } }
            @{ id = $alertId; type = 'Microsoft.Insights/metricAlerts'; properties = @{ enabled = $true } }
        )
        PolicyAssignments = @()
    }
}

function Get-TestAlert {
    param(
        [string] $Kind,
        [System.Collections.IDictionary] $Datasets,
        [System.Collections.IDictionary] $Thresholds,
        [string] $Window = 'PT15M',
        [string] $History = 'PT15M'
    )
    return @{
        kind = $Kind; name = "test-$Kind"; displayName = "Test $Kind"; description = 'Synthetic alert'
        evaluationFrequency = 'PT5M'; windowSize = $Window; queryTimeRange = $History
        autoMitigate = $false; splitByResourceId = $true; severity = 2
        datasets = $Datasets; thresholds = $Thresholds
    }
}

function Get-TestConfiguration {
    $onlineSince = [datetime]::UtcNow.AddHours(-2).ToString('o')
    return @{
        schemaVersion = '1.0'
        scope = @{ subscriptionId = $subscription; resourceGroupName = 'test' }
        location = 'uksouth'
        tags = @{}
        actionGroup = @{ mode = 'existing'; resourceId = $groupId }
        alerts = @(
            (Get-TestAlert -Kind 'cpu' -Datasets @{ ExpectedServers = @(@{ ResourceId = $server1 }) } `
                -Thresholds @{ ThresholdPercent = 91.25 })
            (Get-TestAlert -Kind 'memory' -Datasets @{ ExpectedServers = @(@{ ResourceId = $server1 }) } `
                -Thresholds @{ ThresholdMBytes = 750 })
            (Get-TestAlert -Kind 'disk' -Datasets @{ ExpectedVolumes = @(@{ ResourceId = $server1; Volume = 'C:' }) } `
                -Thresholds @{ ThresholdPercent = 12; ThresholdMBytes = 4096 })
            (Get-TestAlert -Kind 'events' -Datasets @{
                    ExpectedEvents = @(@{ ResourceId = $server1; EventLog = 'System'; Source = 'Quote"Provider ] | union Other'; EventID = 42 })
                } -Thresholds @{} -Window 'PT10M' -History 'PT10M')
            (Get-TestAlert -Kind 'service' -Datasets @{
                    ExpectedServices = @(@{ ResourceId = $server1; SvcName = 'SyntheticService' })
                } -Thresholds @{} -Window 'PT1H' -History 'P2D')
            (Get-TestAlert -Kind 'software' -Datasets @{
                    ExpectedServers = @(@{ ResourceId = $server1 }, @{ ResourceId = $server2 })
                    AllowedSoftware = @(
                        @{ ResourceId = $server1; SoftwareName = 'Synthetic App'; Publisher = 'Synthetic' }
                        @{ ResourceId = $server2; SoftwareName = 'Synthetic App'; Publisher = 'Synthetic' }
                    )
                } -Thresholds @{} -Window 'PT1H' -History 'PT1H')
            (Get-TestAlert -Kind 'configuration' -Datasets @{
                    RegistryItems = @(@{ ResourceId = $server1; Hive = 'HKEY_LOCAL_MACHINE'; RegistryKey = 'SOFTWARE\Demo'; ValueName = '' })
                    FileItems = @(@{ ResourceId = $server1; FileSystemPath = 'C:\Demo\Test.txt' })
                } -Thresholds @{} -Window 'PT2H' -History 'PT2H')
            (Get-TestAlert -Kind 'heartbeat' -Datasets @{
                    ExpectedServers = @(@{ ResourceId = $server1; ExpectedOnlineSince = $onlineSince })
                } -Thresholds @{} -Window 'PT1H' -History 'P1D')
        )
    }
}

function Write-TestJson {
    param([System.Collections.IDictionary] $Value, [string] $Path)
    [System.IO.File]::WriteAllText(
        $Path, (ConvertTo-Json -InputObject $Value -Depth 100), [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-TestAlertParameter {
    $result = & $scriptPath -ReportPath $reportPath -ConfigurationPath $configurationPath `
        -WorkspaceResourceId $workspaceId -ServerResourceId @($server1, $server2)
    $createdOutputs.Add($result.ParameterPath)
    $createdOutputs.Add($result.ReviewPath)
    return $result
}

function Assert-AlertFailure {
    param([string] $Message)
    $failed = $false
    try { $null = & $scriptPath -ReportPath $reportPath -ConfigurationPath $configurationPath `
            -WorkspaceResourceId $workspaceId -ServerResourceId @($server1, $server2) }
    catch {
        $failed = $true
        Assert-AlertTest ($_.Exception.Message.Contains($Message)) 'Invalid input reports the reason'
        Assert-AlertTest (-not $_.Exception.Message.Contains($server1)) 'Errors do not disclose resource IDs'
    }
    Assert-AlertTest $failed 'Invalid alert input must terminate without producing parameters'
}

try {
    $report = Get-TestReport
    $configuration = Get-TestConfiguration
    Write-TestJson -Value $report -Path $reportPath
    Write-TestJson -Value $configuration -Path $configurationPath
    $result = Invoke-TestAlertParameter
    Assert-AlertTest ($result.Status -eq 'ReviewRequired' -and -not $result.ReadyForWhatIf -and
        -not $result.ReadyForDeployment -and $result.AlertCount -eq 8) 'Generated parameters are review-only'
    $parameters = Get-Content -LiteralPath $result.ParameterPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $review = Get-Content -LiteralPath $result.ReviewPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    if ($EmitSyntheticQueries) {
        [ordered]@{
            Server1 = $server1
            Alerts = $parameters.parameters.alerts.value
        } | ConvertTo-Json -Depth 100 -Compress
        return
    }
    Assert-AlertTest ($parameters.parameters.stage.value -eq 'alerting' -and
        $parameters.parameters.workspaceResourceId.value -eq $workspaceId -and
        $parameters.parameters.actionGroups.value.Count -eq 0) 'The existing workspace and Action Group are reused'
    Assert-AlertTest ($review.ParameterSha256 -eq (Get-FileHash -LiteralPath $result.ParameterPath -Algorithm SHA256).Hash) `
        'The private review identifies the generated parameters'
    Assert-AlertTest (-not $review.ReadyForWhatIf -and -not $review.ReadyForDeployment) `
        'The private review cannot authorise what-if or deployment'
    $alerts = @($parameters.parameters.alerts.value)
    Assert-AlertTest (@($alerts | Where-Object { $_.actionGroupResourceId -ne $groupId }).Count -eq 0) `
        'Every alert targets the selected Action Group'
    foreach ($alert in $alerts) {
        Assert-AlertTest ($alert.query -notmatch 'datatable\s*\([^)]*\)\s*\[\s*\]') 'Every generated dataset is populated'
        Assert-AlertTest ($alert.query.Contains($server1)) 'Every generated query includes an approved server'
    }
    $cpu = @($alerts | Where-Object { $_.name -eq 'test-cpu' })[0]
    $memory = @($alerts | Where-Object { $_.name -eq 'test-memory' })[0]
    $disk = @($alerts | Where-Object { $_.name -eq 'test-disk' })[0]
    $events = @($alerts | Where-Object { $_.name -eq 'test-events' })[0]
    $config = @($alerts | Where-Object { $_.name -eq 'test-configuration' })[0]
    $heartbeat = @($alerts | Where-Object { $_.name -eq 'test-heartbeat' })[0]
    Assert-AlertTest ($cpu.query.Contains('let ThresholdPercent = 91.25;') -and
        $memory.query.Contains('let ThresholdMBytes = 750.0;') -and
        $disk.query.Contains('let ThresholdPercent = 12.0;') -and
        $disk.query.Contains('let ThresholdMBytes = 4096.0;')) 'Thresholds are rendered as invariant KQL numbers'
    Assert-AlertTest ($events.query.Contains('@"Quote""Provider ] | union Other"') -and
        $config.query.Contains('@"SOFTWARE\Demo"') -and
        $config.query.Contains('@"C:\Demo\Test.txt"') -and $config.query.Contains('@""]')) `
        'Quotes, Windows paths and a default registry value are rendered literally'
    Assert-AlertTest ($heartbeat.query -match 'datetime\(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z\)') `
        'Expected-online time is rendered as an explicit UTC datetime'
    Assert-AlertTest ((Get-Content -LiteralPath $result.ReviewPath -Raw) -notmatch 'Quote""Provider|Synthetic App') `
        'Review findings do not copy private query contents'
    if (-not $IsWindows) {
        Assert-AlertTest (([System.IO.File]::GetUnixFileMode($result.ParameterPath)).ToString() -eq 'UserWrite, UserRead') `
            'Generated parameter file has mode 600'
        Assert-AlertTest (([System.IO.File]::GetUnixFileMode((Split-Path $result.ParameterPath -Parent))).ToString() -eq
            'UserExecute, UserWrite, UserRead') 'Generated directory has mode 700'
    }
    $cutover = & $reviewScript -ReportPath $reportPath -WorkspaceResourceId $workspaceId `
        -ServerResourceId @($server1, $server2) -ParametersPath $result.ParameterPath
    $createdOutputs.Add($cutover.ManifestPath)
    Assert-AlertTest ($cutover.PlanStage -eq 'alerting' -and -not $cutover.ReadyForWhatIf -and
        -not $cutover.ReadyForDeployment) 'Generated parameters integrate with the private cutover review'
    Write-Output 'PASS: All eight private, scoped alert candidates'

    $precision = Get-TestConfiguration
    $precision.alerts = @($precision.alerts[0])
    $precision.alerts[0].thresholds.ThresholdPercent = 1e-20
    Write-TestJson -Value $precision -Path $configurationPath
    $precisionResult = Invoke-TestAlertParameter
    $precisionParameters = Get-Content -LiteralPath $precisionResult.ParameterPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    Assert-AlertTest ($precisionParameters.parameters.alerts.value[0].query.Contains('let ThresholdPercent = 1E-20;')) `
        'Small numeric thresholds are not rounded to zero'
    Write-Output 'PASS: Numeric threshold precision'

    $stateful = Get-TestConfiguration
    $stateful.alerts = @($stateful.alerts[4])
    $stateful.alerts[0].autoMitigate = $true
    Write-TestJson -Value $stateful -Path $configurationPath
    $statefulResult = Invoke-TestAlertParameter
    $statefulReview = Get-Content -LiteralPath $statefulResult.ReviewPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-AlertTest ('AlertAutomaticRecoveryReview' -in @($statefulReview.PlanAssessment.Findings.Code) -and
        -not $statefulReview.ReadyForDeployment) 'Stateful service recovery remains an explicit review gate'
    Write-Output 'PASS: Stateful recovery remains review-only'

    $newGroup = Get-TestConfiguration
    $email = '{0}@{1}.invalid' -f ('user-' + [guid]::NewGuid().ToString('N')), 'synthetic'
    $newGroup.actionGroup = @{
        mode = 'new'; name = 'test-new-group'; groupShortName = 'testgroup'
        emailReceivers = @(@{ emailAddress = $email })
    }
    Write-TestJson -Value $newGroup -Path $configurationPath
    $newResult = Invoke-TestAlertParameter
    $newParameters = Get-Content -LiteralPath $newResult.ParameterPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $newReview = Get-Content -LiteralPath $newResult.ReviewPath -Raw
    Assert-AlertTest ($newParameters.parameters.actionGroups.value.Count -eq 1 -and
        $newParameters.parameters.actionGroups.value[0].emailReceivers[0].emailAddress -eq $email) `
        'A new disabled group can be proposed with explicit private receivers'
    Assert-AlertTest (-not $newReview.Contains($email)) 'The review does not copy receiver destinations'
    Assert-AlertTest ($newReview.Contains('ExistingActionGroupReview')) 'Existing groups still require reuse review'
    Write-Output 'PASS: Explicit new Action Group remains review-only'

    $cases = @(
        @{ Change = { param($c) $c.alerts[0].datasets.ExpectedServers = @() }; Message = 'must contain between 1 and 100 rows' }
        @{ Change = { param($c) $c.alerts[0].datasets.ExpectedServers = @(@{ ResourceId = "$server1-other" }) }; Message = 'outside the explicitly selected scope' }
        @{ Change = { param($c) $c.alerts[0].datasets.ExpectedServers += @{ ResourceId = $server1.ToUpperInvariant() } }; Message = 'duplicate rows' }
        @{ Change = { param($c) $c.alerts[0].datasets.ExpectedServers[0].Unrecognised = 'value' }; Message = 'missing or unrecognised fields' }
        @{ Change = { param($c) $c.alerts[0].thresholds.ThresholdPercent = 101 }; Message = 'threshold is missing or invalid' }
        @{ Change = { param($c) $c.alerts[1].thresholds.ThresholdMBytes = '500' }; Message = 'threshold is missing or invalid' }
        @{ Change = { param($c) $c.alerts[3].datasets.ExpectedEvents[0].EventLog = 'Security' }; Message = 'System or Application' }
        @{ Change = { param($c) $c.alerts[3].datasets.ExpectedEvents[0].EventID = 65536 }; Message = 'field is missing or invalid' }
        @{ Change = { param($c) $c.alerts[5].datasets.AllowedSoftware = @(@{ ResourceId = $server1; SoftwareName = 'App'; Publisher = 'Vendor' }) }; Message = 'explicit allowlist' }
        @{ Change = { param($c) $c.alerts[6].datasets.RegistryItems = @() }; Message = 'must contain between 1 and 100 rows' }
        @{ Change = { param($c) $c.alerts[6].datasets.RegistryItems[0].Hive = 'HKCU' }; Message = 'must use the HKLM hive' }
        @{ Change = { param($c) $c.alerts[7].datasets.ExpectedServers[0].ExpectedOnlineSince = [datetime]::UtcNow.AddMinutes(5).ToString('o') }; Message = 'non-future date and time' }
        @{ Change = { param($c) $c.alerts[7].datasets.ExpectedServers[0].ExpectedOnlineSince = '2026-01-01T00:00:00' }; Message = 'UTC offset' }
        @{ Change = { param($c) $c.alerts[7].datasets.ExpectedServers += @{ ResourceId = $server1; ExpectedOnlineSince = [datetime]::UtcNow.AddHours(-3).ToString('o') } }; Message = 'duplicate rows' }
        @{ Change = { param($c) $c.alerts[4].queryTimeRange = 'P1D' }; Message = 'history or evaluation window is too short' }
        @{ Change = { param($c) $c.alerts[0].queryTimeRange = 'PT10M' }; Message = 'history or evaluation window is too short' }
        @{ Change = { param($c) $c.alerts[0].windowSize = 'PT10M' }; Message = 'history or evaluation window is too short' }
        @{ Change = { param($c) $c.alerts[0].windowSize = 'PT10M'; $c.alerts[0].evaluationFrequency = 'PT15M' }; Message = 'history or evaluation window is too short' }
        @{ Change = { param($c) $c.alerts[0].autoMitigate = 'false' }; Message = 'invalid timing or recovery settings' }
        @{ Change = { param($c) $c.alerts[1].name = $c.alerts[0].name }; Message = 'valid and unique' }
        @{ Change = { param($c) $c.alerts[1].kind = $c.alerts[0].kind }; Message = 'supported and unique' }
        @{ Change = { param($c) $c.actionGroup.resourceId = "$groupId-other" }; Message = 'uniquely present in discovery' }
        @{ Change = { param($c) $c.alerts[0].datasets.ExpectedServers[0].ResourceId = $server1 + "`n" }; Message = 'field is missing or invalid' }
    )
    foreach ($case in $cases) {
        $invalid = Get-TestConfiguration
        & $case.Change $invalid
        Write-TestJson -Value $invalid -Path $configurationPath
        Assert-AlertFailure -Message $case.Message
    }
    Write-Output 'PASS: Invalid scopes, baselines, timing and settings are rejected'

    $configuration = Get-TestConfiguration
    $configuration.actionGroup = @{
        mode = 'new'; name = 'existing'; groupShortName = 'test'
        emailReceivers = @(@{ emailAddress = $email })
    }
    Write-TestJson -Value $configuration -Path $configurationPath
    Assert-AlertFailure -Message 'conflicts with known resource names'
    $configuration = Get-TestConfiguration
    $report.Resources += @{
        id = $prefix + 'Microsoft.Insights/scheduledQueryRules/test-cpu'
        type = 'Microsoft.Insights/scheduledQueryRules'; properties = @{ enabled = $true }
    }
    Write-TestJson -Value $report -Path $reportPath
    Write-TestJson -Value $configuration -Path $configurationPath
    Assert-AlertFailure -Message 'conflicts with known resource names'
    Write-Output 'PASS: Existing resource names cannot be proposed for overwrite'

    $report = Get-TestReport
    Write-TestJson -Value $report -Path $reportPath
    $invalidGroupId = 'invalid-action-group-id'
    $report.Resources += @{ id = $invalidGroupId; type = 'Microsoft.Insights/actionGroups'; properties = @{ enabled = $true } }
    Write-TestJson -Value $report -Path $reportPath
    $configuration = Get-TestConfiguration
    $configuration.actionGroup.resourceId = $invalidGroupId
    Write-TestJson -Value $configuration -Path $configurationPath
    Assert-AlertFailure -Message 'valid resource ID in an enumerated subscription'
    $report = Get-TestReport
    Write-TestJson -Value $report -Path $reportPath
    [System.IO.File]::WriteAllText($configurationPath, '{"schemaVersion":"1.0","SCHEMAVERSION":"1.0"}')
    Assert-AlertFailure -Message 'duplicate JSON fields'
    [System.IO.File]::WriteAllText($configurationPath, '{"items":[{"name":"first","NAME":"second"}]}')
    Assert-AlertFailure -Message 'duplicate JSON fields'
    [System.IO.File]::WriteAllText($configurationPath, '{invalid')
    Assert-AlertFailure -Message 'valid JSON'
    $stream = [System.IO.File]::Open($configurationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $stream.SetLength(2MB + 1) }
    finally { $stream.Dispose() }
    Assert-AlertFailure -Message 'exceeds the 2 MiB limit'
    Write-TestJson -Value (Get-TestConfiguration) -Path $configurationPath
    $report.GeneratedAtUtc = [datetime]::UtcNow.AddMinutes(-61).ToString('o')
    Write-TestJson -Value $report -Path $reportPath
    Assert-AlertFailure -Message 'stale or future-dated'
    Write-TestJson -Value (Get-TestReport) -Path $reportPath
    if (-not $IsWindows) {
        [System.IO.File]::SetUnixFileMode(
            $configurationPath, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
            [System.IO.UnixFileMode]::GroupRead
        )
        Assert-AlertFailure -Message 'owner-only mode 600'
        [System.IO.File]::SetUnixFileMode(
            $configurationPath, [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        )
        $linkPath = Join-Path $testDirectory 'linked.json'
        $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $configurationPath
        $failed = $false
        try {
            $null = & $scriptPath -ReportPath $reportPath -ConfigurationPath $linkPath `
                -WorkspaceResourceId $workspaceId -ServerResourceId @($server1)
        }
        catch { $failed = $_.Exception.Message -match 'single-link file' }
        finally { Remove-Item -LiteralPath $linkPath -ErrorAction Stop }
        Assert-AlertTest $failed 'A symbolic-link input is rejected'
    }
    Write-Output 'PASS: Private input, JSON and freshness safeguards'
}
finally {
    $directories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $createdOutputs) {
        if (Test-Path -LiteralPath $file) {
            $null = $directories.Add((Split-Path $file -Parent))
            Remove-Item -LiteralPath $file -ErrorAction Stop
        }
    }
    foreach ($directory in $directories) {
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -ErrorAction Stop
        }
    }
    foreach ($file in @($reportPath, $configurationPath)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -ErrorAction Stop }
    }
    if (@(Get-ChildItem -LiteralPath $testDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $testDirectory -ErrorAction Stop
    }
}
