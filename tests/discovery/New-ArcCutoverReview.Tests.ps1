#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$reviewScript = Join-Path $PSScriptRoot '../../scripts/discovery/New-ArcCutoverReview.ps1'
$discoveryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../scripts/discovery'))
Import-Module (Join-Path $discoveryDirectory 'ArcPrivateEvidence.psm1') -ErrorAction Stop
$testDirectory = New-ArcPrivateEvidenceDirectory -DiscoveryDirectory $discoveryDirectory `
    -DirectoryName ('review-input-test-' + [guid]::NewGuid().ToString('N'))
$reportPath = New-ArcPrivateEvidenceFile -Directory $testDirectory -FileName 'report.json'
$baselinePath = New-ArcPrivateEvidenceFile -Directory $testDirectory -FileName 'baseline.json'
$parameterPath = New-ArcPrivateEvidenceFile -Directory $testDirectory -FileName 'parameters.json'
$createdFiles = [System.Collections.Generic.List[string]]::new()
$subscription = [guid]::NewGuid().ToString()
$workspaceGuid = [guid]::NewGuid().ToString()
$prefix = "/subscriptions/$subscription/resourceGroups/test/providers/"
$workspaceId = $prefix + 'Microsoft.OperationalInsights/workspaces/shared'
$server1 = $prefix + 'Microsoft.HybridCompute/machines/server-one'
$server2 = $prefix + 'Microsoft.HybridCompute/machines/server-two'
$ruleId = $prefix + 'Microsoft.Insights/dataCollectionRules/monitoring'
$alertId = $prefix + 'Microsoft.Insights/metricAlerts/existing'
$groupId = $prefix + 'Microsoft.Insights/actionGroups/existing'
$associationId = $server1 + '/providers/Microsoft.Insights/dataCollectionRuleAssociations/monitoring'

function Assert-Review {
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
        Workspaces = @(@{
                Id = $workspaceId; Name = 'shared'; Location = 'uksouth'
                RetentionInDays = 30; PricingTier = 'PerGB2018'; Solutions = @()
            })
        Servers = @(
            @{
                Id = $server1; Location = 'uksouth'; ConnectionStatus = 'Connected'; AMA = 'Provisioned'; ChangeTracking = 'NotObserved'
                Extensions = @{
                    Status = 'Succeeded'
                    Items = @(@{
                            Id = $server1 + '/extensions/ama'; Name = 'ama'; Category = 'AMA'
                            Publisher = 'Microsoft.Azure.Monitor'; Type = 'AzureMonitorWindowsAgent'
                            Version = '1.0'; InstanceVersion = '1.0'; ProvisioningState = 'Succeeded'
                        })
                }
                Associations = @{
                    Status = 'Succeeded'
                    Items = @(@{ id = $associationId; properties = @{ dataCollectionRuleId = $ruleId } })
                }
            }
            @{
                Id = $server2; Location = 'uksouth'; ConnectionStatus = 'Connected'; AMA = 'NotObserved'; ChangeTracking = 'NotObserved'
                Extensions = @{ Status = 'Succeeded'; Items = @() }
                Associations = @{ Status = 'Succeeded'; Items = @() }
            }
        )
        Resources = @(
            @{
                id = $workspaceId; type = 'Microsoft.OperationalInsights/workspaces'; properties = @{ customerId = $workspaceGuid }
            }
            @{
                id = $ruleId; type = 'Microsoft.Insights/dataCollectionRules'; location = 'uksouth'; kind = 'Windows'
                properties = @{
                    dataSources = @{ performanceCounters = @(@{
                                streams = @('Microsoft-Perf'); samplingFrequencyInSeconds = 60
                                counterSpecifiers = @('\Processor(_Total)\% Processor Time')
                            }) }
                    destinations = @{ logAnalytics = @(@{ name = 'workspace'; workspaceResourceId = $workspaceId }) }
                    dataFlows = @(@{ streams = @('Microsoft-Perf'); destinations = @('workspace') })
                }
            }
            @{
                id = $alertId; type = 'Microsoft.Insights/metricAlerts'; DiscoveryRelationship = 'UnresolvedReviewRequired'
                properties = @{ enabled = $true; scopes = @($server1); criteria = @{ threshold = 90 } }
            }
            @{
                id = $groupId; type = 'Microsoft.Insights/actionGroups'
                properties = @{ enabled = $true; emailReceivers = @(@{ emailAddress = 'sensitive-synthetic-receiver' }) }
            }
        )
        PolicyAssignments = @(@{
                id = "/subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/test"
                scope = "/subscriptions/$subscription"
                policyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/test'
                enforcementMode = 'Default'
            })
    }
}

function Write-TestReport {
    param([System.Collections.IDictionary] $Report)
    $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

function Assert-ReviewFailure {
    param([string] $ExpectedText)
    $failed = $false
    try { $null = & $reviewScript -ReportPath $reportPath -WorkspaceResourceId $workspaceId -ServerResourceId @($server1, $server2) }
    catch {
        $failed = $true
        $message = $_.Exception.Message
        Assert-Review ($message.Contains($ExpectedText)) 'Failure reports the cause'
        Assert-Review (-not $message.Contains($server1)) 'Failure does not disclose server IDs'
    }
    Assert-Review $failed 'Invalid evidence must terminate'
}

function Assert-PlanFailure {
    param([string] $ExpectedText)
    $failed = $false
    try {
        $null = & $reviewScript -ReportPath $reportPath -WorkspaceResourceId $workspaceId `
            -ServerResourceId @($server1, $server2) -ParametersPath $parameterPath
    }
    catch {
        $failed = $true
        $message = $_.Exception.Message
        Assert-Review ($message.Contains($ExpectedText)) 'Invalid plan reports the cause'
        Assert-Review (-not $message.Contains($server1)) 'Invalid plan does not disclose server IDs'
    }
    Assert-Review $failed 'Invalid plan must terminate'
}

function Assert-TestPlanFailure {
    param([string] $Stage, [System.Collections.IDictionary] $Operations, [string] $ExpectedText)
    $failed = $false
    try { $null = Invoke-TestPlan -Stage $Stage -Operations $Operations }
    catch {
        $failed = $true
        Assert-Review ($_.Exception.Message.Contains($ExpectedText)) 'Invalid operation reports the cause'
        Assert-Review (-not $_.Exception.Message.Contains($server1)) 'Invalid operation does not disclose server IDs'
    }
    Assert-Review $failed 'An invalid operation must terminate'
}

function Invoke-TestPlan {
    param([string] $Stage, [System.Collections.IDictionary] $Operations)
    $parameters = @{
        stage = @{ value = $Stage }
        workspaceResourceId = @{ value = $workspaceId }
    }
    foreach ($key in $Operations.Keys) { $parameters[$key] = @{ value = $Operations[$key] } }
    @{ parameters = $parameters } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    $result = & $reviewScript -ReportPath $reportPath -WorkspaceResourceId $workspaceId `
        -ServerResourceId @($server1, $server2) -ParametersPath $parameterPath
    $createdFiles.Add($result.ManifestPath)
    Assert-Review (-not $result.ReadyForWhatIf -and -not $result.ReadyForDeployment) 'A partial plan comparison never authorises deployment'
    $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    return $manifest.PlanAssessment
}

function Invoke-TestComparison {
    $result = & $reviewScript -ReportPath $reportPath -BaselineReportPath $baselinePath `
        -WorkspaceResourceId $workspaceId -ServerResourceId @($server1, $server2)
    $createdFiles.Add($result.ManifestPath)
    Assert-Review (-not $result.ReadyForWhatIf -and -not $result.ReadyForDeployment) 'A comparison never authorises deployment'
    return Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

function Assert-ComparisonFailure {
    param([string] $ExpectedText, [string[]] $SelectedServers = @($server1, $server2))
    $failed = $false
    try {
        $null = & $reviewScript -ReportPath $reportPath -BaselineReportPath $baselinePath `
            -WorkspaceResourceId $workspaceId -ServerResourceId $SelectedServers
    }
    catch {
        $failed = $true
        Assert-Review ($_.Exception.Message.Contains($ExpectedText)) 'Invalid comparison reports the cause'
        Assert-Review (-not $_.Exception.Message.Contains($server1)) 'Invalid comparison does not disclose server IDs'
    }
    Assert-Review $failed 'Invalid comparison must terminate'
}

try {
    $report = Get-TestReport
    Write-TestReport $report
    $missingReport = Join-Path $testDirectory ('missing-private-' + [guid]::NewGuid().ToString('N'))
    $failed = $false
    try { $null = & $reviewScript -ReportPath $missingReport -WorkspaceResourceId $workspaceId -ServerResourceId @($server1) }
    catch {
        $failed = $_.Exception.Message -match 'private input file could not be read' -and
            -not $_.Exception.Message.Contains($missingReport)
    }
    Assert-Review $failed 'A missing input produces a sanitised error'
    $outsidePath = Join-Path ([System.IO.Path]::GetTempPath()) ('outside-private-' + [guid]::NewGuid().ToString('N'))
    $failed = $false
    try { $null = & $reviewScript -ReportPath $outsidePath -WorkspaceResourceId $workspaceId -ServerResourceId @($server1) }
    catch {
        $failed = $_.Exception.Message -match 'dedicated discovery output directory' -and
            -not $_.Exception.Message.Contains($outsidePath)
    }
    Assert-Review $failed 'An input outside the private evidence directory is rejected without disclosing its path'
    if (-not $IsWindows) {
        foreach ($testInput in @(
                @{ Path = $reportPath; Kind = 'Report' }
                @{ Path = $baselinePath; Kind = 'Baseline' }
                @{ Path = $parameterPath; Kind = 'Parameters' }
            )) {
            $originalMode = [System.IO.File]::GetUnixFileMode($testInput.Path)
            try {
                [System.IO.File]::SetUnixFileMode($testInput.Path, ($originalMode -bor [System.IO.UnixFileMode]::GroupRead))
                switch ($testInput.Kind) {
                    'Report' { Assert-ReviewFailure -ExpectedText 'owner-only mode 600' }
                    'Baseline' { Assert-ComparisonFailure -ExpectedText 'owner-only mode 600' }
                    'Parameters' { Assert-PlanFailure -ExpectedText 'owner-only mode 600' }
                }
            }
            finally { [System.IO.File]::SetUnixFileMode($testInput.Path, $originalMode) }
        }
        $linkPath = Join-Path $testDirectory 'linked-report.json'
        try {
            $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $reportPath -ErrorAction Stop
            $failed = $false
            try { $null = & $reviewScript -ReportPath $linkPath -WorkspaceResourceId $workspaceId -ServerResourceId @($server1) }
            catch { $failed = $_.Exception.Message -match 'single-link file' }
            Assert-Review $failed 'A linked private input is rejected'
        }
        finally {
            if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -ErrorAction Stop }
        }
        $hardLinkPath = Join-Path $testDirectory 'hard-linked-report.json'
        try {
            $null = New-Item -ItemType HardLink -Path $hardLinkPath -Target $reportPath -ErrorAction Stop
            $failed = $false
            try { $null = & $reviewScript -ReportPath $hardLinkPath -WorkspaceResourceId $workspaceId -ServerResourceId @($server1) }
            catch { $failed = $_.Exception.Message -match 'single-link file' }
            Assert-Review $failed 'A hard-linked private input is rejected'
            Assert-ReviewFailure -ExpectedText 'single-link file'
        }
        finally {
            if (Test-Path -LiteralPath $hardLinkPath) { Remove-Item -LiteralPath $hardLinkPath -ErrorAction Stop }
        }
    }
    foreach ($invalidJson in @(
            '{"parameters":{"stage":{"value":"ama"},"STAGE":{"value":"alerting"}}}'
            '{"parameters":{"stage":{"value":"ama","VALUE":"alerting"}}}'
        )) {
        [System.IO.File]::WriteAllText($parameterPath, $invalidJson)
        Assert-PlanFailure -ExpectedText 'duplicate JSON fields'
    }
    $nestedJson = ('[' * 70) + '0' + (']' * 70)
    $nestedValue = ConvertFrom-ArcPrivateJson -Json $nestedJson -Label 'stage parameters'
    Assert-Review ($nestedValue -is [array]) 'Valid nested JSON retains the previous 100-level limit'
    $tooDeepJson = ('[' * 101) + '0' + (']' * 101)
    $failed = $false
    try { $null = ConvertFrom-ArcPrivateJson -Json $tooDeepJson -Label 'stage parameters' }
    catch { $failed = $_.Exception.Message -match 'valid JSON' }
    Assert-Review $failed 'Excessively nested JSON is rejected'
    [System.IO.File]::WriteAllText($parameterPath, (' ' * (2MB + 1)))
    Assert-PlanFailure -ExpectedText 'exceeds the 2 MiB limit'
    Write-Output 'PASS: Private input, link, JSON and size safeguards'

    $result = & $reviewScript -ReportPath $reportPath -WorkspaceResourceId $workspaceId -ServerResourceId @($server1, $server2)
    $createdFiles.Add($result.ManifestPath)
    $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    Assert-Review (-not $result.ReadyForWhatIf -and -not $result.ReadyForDeployment) 'The review never authorises what-if or deployment'
    Assert-Review ($manifest.Status -eq 'ReviewRequired' -and -not $manifest.ReadyForDeployment) 'The manifest remains review-only'
    Assert-Review ($manifest.Workspace.ProposedAction -match '^Reuse unchanged') 'The workspace is reused without changes'
    Assert-Review ($manifest.Servers.Count -eq 2 -and $manifest.Servers[1].Extensions.Count -eq 0 -and $manifest.Servers[1].Associations.Count -eq 0) 'Empty extension and association arrays remain empty'
    Assert-Review ($manifest.Servers[0].Associations[0].ResourceId -eq $associationId -and $manifest.Servers[0].Associations[0].ProposedAction -eq 'Preserve') 'Existing associations are preserved by default'
    Assert-Review ($manifest.DataCollectionRules[0].SelectedServerAssociations[0].AssociationResourceId -eq $associationId) 'The rule identifies its known selected-server association'
    Assert-Review ($manifest.DataCollectionRules[0].ExistingProperties.destinations.logAnalytics[0].workspaceResourceId -eq $workspaceId) 'DCR selectors and destinations are retained for review'
    Assert-Review ($manifest.Alerts[0].ExistingProperties.criteria.threshold -eq 90 -and $manifest.Alerts[0].Relationship -eq 'UnresolvedReviewRequired') 'Unresolved existing alert intent is preserved'
    Assert-Review ($manifest.ActionGroups[0].ReceiverCounts[0].Count -eq 1) 'Action Group receiver types are counted'
    Assert-Review ((Get-Content -LiteralPath $result.ManifestPath -Raw) -notmatch 'sensitive-synthetic-receiver') 'Receiver destinations are not copied'
    Assert-Review ($manifest.PolicyAssignments.Count -eq 1 -and $manifest.RequiredReview.Count -gt 0) 'Policy and remaining review gates are recorded'
    Assert-Review ($null -eq $manifest.PlanAssessment) 'No plan assessment is invented without parameters'
    if (-not $IsWindows) {
        $directoryMode = [int] [System.IO.File]::GetUnixFileMode((Split-Path -Parent $result.ManifestPath))
        $fileMode = [int] [System.IO.File]::GetUnixFileMode($result.ManifestPath)
        Assert-Review (($directoryMode -band 63) -eq 0 -and ($fileMode -band 63) -eq 0) 'Private outputs exclude group and other access'
    }
    Write-Output 'PASS: Review-only private manifest'

    $planScope = @{ subscriptionId = $subscription; resourceGroupName = 'test' }
    $ama = @{
        scope = $planScope; machineName = 'server-one'; extensionName = 'different-ama'
        location = 'uksouth'; typeHandlerVersion = '1.45'
    }
    $cti = @{
        scope = $planScope; machineName = 'server-two'; extensionName = 'cti'
        location = 'uksouth'; typeHandlerVersion = '2.42'
    }
    $assessment = Invoke-TestPlan -Stage 'ama' -Operations @{
        amaExtensions = @($ama)
        changeTrackingExtensions = @($cti)
    }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ExistingExtensionRequiresReview' -in $codes -and 'InactiveOperations' -in $codes) 'Existing renamed AMA and inactive CTI operations are flagged'
    Assert-Review ($assessment.OperationCount -eq 1) 'The AMA stage does not include CTI operations'
    Assert-Review ('GuestAndVersionReview' -in $codes -and 'CompletePreflightRequired' -in $codes) 'Guest state and complete preflight remain required'
    $assessment = Invoke-TestPlan -Stage 'change-tracking-extension' -Operations @{ changeTrackingExtensions = @($cti) }
    Assert-Review ($assessment.OperationCount -eq 1 -and $assessment.Stage -eq 'change-tracking-extension') 'CTI has a separate stage'
    Write-Output 'PASS: Agent plan risks'

    $performance = @{
        scope = $planScope; name = 'monitoring'; location = 'uksouth'
        counterSpecifiers = @('\Processor(_Total)\% Processor Time')
        samplingFrequencyInSeconds = 60
        eventXPathQueries = @('Security!*[System[(Level=1)]]')
    }
    $assessment = Invoke-TestPlan -Stage 'collection-rules' -Operations @{ performanceRules = @($performance) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ExistingResourceName' -in $codes -and 'ExistingCollectionReview' -in $codes) 'Existing names and potential collection overlap are flagged'
    Assert-Review ('SecurityCollectionReview' -in $codes) 'Security event collection requires specific review'
    Write-Output 'PASS: Collection rule risks'

    $ctiRule = @{
        scope = @{ subscriptionId = $subscription; resourceGroupName = 'other' }
        name = 'cti-new'; location = 'uksouth'; registryInfo = @(@{ key = 'synthetic' }); fileInfo = @(@{ path = 'synthetic' })
        fileCollectionFrequency = 1800; serviceCollectionFrequency = 600
    }
    $assessment = Invoke-TestPlan -Stage 'collection-rules' -Operations @{ changeTrackingRules = @($ctiRule) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ChangeTrackingScopeMismatch' -in $codes -and 'ChangeTrackingSchemaReview' -in $codes) 'CTI scope and unresolved schema are identified'
    Write-Output 'PASS: Change Tracking rule risks'

    $association = @{
        scope = $planScope; machineName = 'server-one'; associationName = 'new-association'
        dataCollectionRuleId = $ruleId
    }
    $secondAssociation = @{
        scope = $planScope; machineName = 'server-one'; associationName = 'another-association'
        dataCollectionRuleId = $ruleId
    }
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($association, $secondAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ExistingAssociation' -in $codes -and 'PlannedAssociationOverlap' -in $codes) 'Existing and repeated DCR associations are flagged'
    Assert-Review ('DestinationAndTransformReview' -in $codes) 'DCR destinations and transformations require review'
    Assert-Review ('WorkspaceDestinationMismatch' -notin $codes -and 'WorkspaceDestinationNotVerified' -notin $codes) 'The nominated workspace is recognised as a destination'
    Write-Output 'PASS: Association plan risks'

    $report = Get-TestReport
    $secondRuleId = $prefix + 'Microsoft.Insights/dataCollectionRules/second-monitoring'
    $report.Resources += @{
        id = $secondRuleId; type = 'Microsoft.Insights/dataCollectionRules'
        properties = @{
            dataSources = @{ performanceCounters = @(@{ counterSpecifiers = @('\Memory\Available MBytes') }) }
            destinations = @{ logAnalytics = @(@{ workspaceResourceId = $workspaceId + '-other' }) }
        }
    }
    Write-TestReport $report
    $otherAssociation = @{
        scope = $planScope; machineName = 'server-one'; associationName = 'second-monitoring'
        dataCollectionRuleId = $secondRuleId
    }
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($otherAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ExistingAssociationOverlap' -in $codes) 'Potential overlap with a different existing rule is not treated as safe'
    Assert-Review ('WorkspaceDestinationMismatch' -in $codes -and 'AdditionalDestinationsReview' -in $codes) 'Different workspace destinations are identified'
    $otherAssociation.dataCollectionRuleId += '-missing'
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($otherAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('TargetDcrNotDiscovered' -in $codes) 'An undiscovered target rule is blocked'
    Write-TestReport (Get-TestReport)
    Write-Output 'PASS: Existing and missing DCR risks'

    $report = Get-TestReport
    $literalRuleId = $prefix + 'Microsoft.Insights/dataCollectionRules/literal-match'
    $literalRule = $report.Resources[1] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $literalRule.id = $literalRuleId
    $report.Resources += $literalRule
    $literalAssociation = @{
        scope = $planScope; machineName = 'server-one'; associationName = 'literal-match'
        dataCollectionRuleId = $literalRuleId
    }
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -in $codes -and 'MatchingLiteralCollectionSettings' -in $codes) 'Matching literal selector, stream, workspace and settings are flagged'
    $literalRule.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds = 120
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -in $codes -and 'MatchingLiteralCollectionSettings' -notin $codes) 'A different interval is not reported as identical settings'
    $literalRule.properties.dataSources.performanceCounters[0].samplingFrequencyInSeconds = 60
    $literalRule.properties.dataFlows[0].transformKql = 'source | where false'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -in $codes -and 'MatchingLiteralCollectionSettings' -notin $codes) 'A different transformation is not reported as identical settings'
    $literalRule.properties.dataFlows[0].transformKql = $null
    $literalRule.properties.dataFlows[0].outputStream = 'Custom-Synthetic'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -in $codes -and 'MatchingLiteralCollectionSettings' -notin $codes) 'A different output stream is not reported as identical settings'
    $literalRule.properties.dataFlows[0].outputStream = $null
    $literalRule.properties.dataSources.performanceCounters[0].transform = 'named-synthetic-transform'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('LiteralCollectionComparisonIncomplete' -in $codes -and 'MatchingLiteralCollectionSettings' -notin $codes) 'Named transforms are not treated as equivalent'
    $literalRule.properties.dataSources.performanceCounters[0].transform = $null
    $literalRule.properties.dataSources.performanceCounters[0].streams = @('Microsoft-InsightsMetrics')
    $literalRule.properties.dataFlows[0].streams = @('Microsoft-InsightsMetrics')
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -notin $codes -and 'ExistingAssociationOverlap' -in $codes) 'Different streams still require category-level review'
    $literalRule.properties.dataSources.performanceCounters[0].streams = @('Microsoft-Perf')
    $literalRule.properties.dataFlows[0].streams = @('Microsoft-Perf')
    $literalRule.properties.destinations.logAnalytics[0].workspaceResourceId += '-other'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -notin $codes -and 'ExistingAssociationOverlap' -in $codes) 'Different destinations remain a possible category overlap, not a literal destination match'
    $literalRule.properties.destinations.logAnalytics[0].workspaceResourceId = $workspaceId
    $literalRule.properties.dataSources.performanceCounters[0].counterSpecifiers[0] = '\Memory\Available MBytes'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -notin $codes -and 'ExistingAssociationOverlap' -in $codes) 'Different selectors do not imply absence of semantic overlap'
    $literalRule.properties.dataFlows[0].destinations = @('unrecognised')
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('LiteralCollectionComparisonIncomplete' -in $codes) 'Unknown destination aliases are explicitly flagged'

    $report = Get-TestReport
    $eventRule = $report.Resources[1]
    $eventRule.properties.dataSources = @{ windowsEventLogs = @(@{
                streams = @('Microsoft-Event'); xPathQueries = @('System!*[System[(Level=1)]]')
            }) }
    $eventRule.properties.dataFlows = @(@{ streams = @('Microsoft-Event'); destinations = @('workspace') })
    $eventTarget = $eventRule | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $eventTarget.id = $literalRuleId
    $report.Resources += $eventTarget
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -in $codes -and 'MatchingLiteralCollectionSettings' -in $codes) 'Matching event XPath paths are flagged'
    $eventTarget.properties.dataSources.windowsEventLogs[0].xPathQueries[0] = 'Application!*[System[(Level=1)]]'
    Write-TestReport $report
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($literalAssociation) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('MatchingLiteralSelectorDestination' -notin $codes -and 'ExistingAssociationOverlap' -in $codes) 'Different event XPath selectors still need semantic review'
    $eventTarget.properties.dataSources.windowsEventLogs[0].xPathQueries[0] = 'System!*[System[(Level=1)]]'
    Write-TestReport $report
    $plannedOne = @{ scope = $planScope; machineName = 'server-two'; associationName = 'first'; dataCollectionRuleId = $ruleId }
    $plannedTwo = @{ scope = $planScope; machineName = 'server-two'; associationName = 'second'; dataCollectionRuleId = $literalRuleId }
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($plannedOne, $plannedTwo) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('PlannedAssociationOverlap' -in $codes -and 'MatchingLiteralCollectionSettings' -in $codes) 'Overlapping associations within one stage are flagged'
    Write-TestReport (Get-TestReport)
    Write-Output 'PASS: Literal DCR path, interval, transform and destination comparison'

    $report = Get-TestReport
    $oldCtiId = $prefix + 'Microsoft.Insights/dataCollectionRules/cti-old'
    $newCtiId = $prefix + 'Microsoft.Insights/dataCollectionRules/cti-new'
    $oldCtiAssociation = $server1 + '/providers/Microsoft.Insights/dataCollectionRuleAssociations/cti-old'
    foreach ($ctiId in @($oldCtiId, $newCtiId)) {
        $report.Resources += @{
            id = $ctiId; type = 'Microsoft.Insights/dataCollectionRules'
            properties = @{
                dataSources = @{ extensions = @(@{ extensionName = 'ChangeTracking-Windows'; streams = @('Microsoft-ConfigurationData') }) }
                destinations = @{ logAnalytics = @(@{ workspaceResourceId = $workspaceId }) }
            }
        }
    }
    $report.Servers[0].Associations.Items += @{ id = $oldCtiAssociation; properties = @{ dataCollectionRuleId = $oldCtiId } }
    Write-TestReport $report
    $ctiAssociation = @{
        scope = $planScope; machineName = 'server-one'; associationName = 'cti-new'
        dataCollectionRuleId = $newCtiId
    }
    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ associations = @($ctiAssociation) }
    $ctiOverlaps = @($assessment.Findings | Where-Object { $_.Code -eq 'ExistingAssociationOverlap' })
    Assert-Review (@($ctiOverlaps | Where-Object { $oldCtiId -in $_.RelatedResourceIds }).Count -eq 1) 'A second Change Tracking DCR on the same server is flagged'
    Write-TestReport (Get-TestReport)
    Write-Output 'PASS: Single Change Tracking rule constraint'

    $newGroupId = $prefix + 'Microsoft.Insights/actionGroups/new-group'
    $group = @{
        scope = $planScope; name = 'new-group'; groupShortName = 'new'
        emailReceivers = @(@{ emailAddress = 'sensitive-synthetic-receiver' })
    }
    $alert = @{
        scope = $planScope; name = 'new-alert'; displayName = 'new'; location = 'uksouth'
        description = 'Synthetic alert'; actionGroupResourceId = $newGroupId; query = 'sensitive-synthetic-query'; severity = 2
        evaluationFrequency = 'PT5M'; windowSize = 'PT1H'; queryTimeRange = 'P2D'
        autoMitigate = $true; splitByResourceId = $true
    }
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ actionGroups = @($group); alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ExistingActionGroupReview' -in $codes -and 'ExistingAlertIntentReview' -in $codes) 'Existing alert and Action Group intent is flagged'
    Assert-Review ('ActionGroupNotDiscovered' -notin $codes -and 'AlertScopeAndQueryReview' -in $codes) 'Planned group references are resolved and alert scope is reviewed'
    Assert-Review ('AlertAutomaticRecoveryReview' -in $codes -and 'AlertDimensionReview' -in $codes) 'Automatic resolution and dimension costs require review'
    Assert-Review ('AlertHistoryTooShort' -notin $codes) 'Two days of history covers the one-hour evaluation window'
    $assessmentJson = ConvertTo-Json -InputObject $assessment -Depth 100
    Assert-Review ($assessmentJson -notmatch 'sensitive-synthetic-(receiver|query)') 'Parameter recipients and query text are not copied into the assessment'
    $alert.actionGroupResourceId = $groupId
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('ReferencedActionGroupReview' -in $codes -and 'ActionGroupNotDiscovered' -notin $codes) 'Reused Action Groups require owner and receiver review'
    $alert.queryTimeRange = 'PT15M'
    $alert.autoMitigate = $false
    $alert.splitByResourceId = $false
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('AlertHistoryTooShort' -in $codes -and 'AlertStatelessNotificationReview' -in $codes) 'Short history and stateless notification risks are flagged'
    Assert-Review ('AlertDimensionReview' -notin $codes) 'No per-resource series are claimed without dimensions'

    $alert.windowSize = 'PT10M'
    $alert.queryTimeRange = 'PT15M'
    $alert.query = 'let ExpectedServers = datatable(ResourceId:string)[]; Heartbeat | where TimeGenerated >= ago(1d)'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('EmptyAlertDataList' -in $codes -and 'AlertHistoryTooShortForLookback' -in $codes) 'An empty scope and insufficient KQL history are flagged'
    $alert.query = 'let Scope = dynamic([]); Heartbeat | where TimeGenerated >= ago(1.5h)'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('EmptyAlertDataList' -in $codes -and 'AlertHistoryTooShortForLookback' -in $codes) 'Empty dynamic lists and fractional lookbacks are flagged'
    $alert.queryTimeRange = 'P2D'
    $alert.query = 'Heartbeat | where TimeGenerated >= ago(2d)'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('AlertHistoryTooShortForLookback' -notin $codes) 'History equal to the literal lookback is not flagged as too short'
    $alert.queryTimeRange = 'PT15M'
    $alert.query = 'Heartbeat | where TimeGenerated >= ago(900001ms)'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    Assert-Review ('AlertHistoryTooShortForLookback' -in @($assessment.Findings | ForEach-Object { $_.Code })) 'Millisecond lookbacks above the boundary are flagged'
    $alert.query = 'Heartbeat | where TimeGenerated >= ago(999999999999999999999999999999999d)'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    Assert-Review ('AlertLookbackUninterpretable' -in @($assessment.Findings | ForEach-Object { $_.Code })) 'An unparseable lookback is not treated as safe'
    $alert.queryTimeRange = 'P2D'
    foreach ($queryPath in @(
            '../../queries/alerts/high-cpu.kql'
            '../../queries/alerts/low-memory.kql'
            '../../queries/alerts/low-disk-space.kql'
            '../../queries/alerts/critical-windows-events.kql'
            '../../queries/alerts/unexpected-software.kql'
            '../../queries/alerts/configuration-changes.kql'
            '../../queries/services-expected-running.kql'
            '../../queries/heartbeat-missing.kql'
        )) {
        $alert.query = Get-Content -LiteralPath (Join-Path $PSScriptRoot $queryPath) -Raw
        $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
        Assert-Review ('EmptyAlertDataList' -in @($assessment.Findings | ForEach-Object { $_.Code })) 'Each empty-scope template is flagged for review'
    }
    $alert.query = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../queries/services-expected-running.kql') -Raw
    $alert.queryTimeRange = 'P1D'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    Assert-Review ('AlertHistoryTooShortForLookback' -in @($assessment.Findings | ForEach-Object { $_.Code })) 'A one-day alert range cannot cover two days of service history'
    $alert.query = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../queries/heartbeat-missing.kql') -Raw
    $alert.queryTimeRange = 'PT2H'
    $assessment = Invoke-TestPlan -Stage 'alerting' -Operations @{ alerts = @($alert) }
    Assert-Review ('AlertHistoryTooShortForLookback' -in @($assessment.Findings | ForEach-Object { $_.Code })) 'A two-hour alert range cannot cover one day of heartbeat history'
    $alert.queryTimeRange = 'invalid'
    $null = @{ parameters = @{
            stage = @{ value = 'alerting' }; workspaceResourceId = @{ value = $workspaceId }
            alerts = @{ value = @($alert) }
        } } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    Assert-PlanFailure -ExpectedText 'invalid timing or recovery settings'
    Write-Output 'PASS: Alert plan risks'

    $assessment = Invoke-TestPlan -Stage 'associations' -Operations @{ amaExtensions = @($ama) }
    $codes = @($assessment.Findings | ForEach-Object { $_.Code })
    Assert-Review ('InactiveOperations' -in $codes -and 'EmptyStage' -in $codes) 'Ignored operations and empty stages are identified'
    Write-Output 'PASS: Inactive and empty stage'

    $badPerformance = $performance | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $badPerformance.samplingFrequencyInSeconds = 0
    Assert-TestPlanFailure -Stage 'collection-rules' -Operations @{ performanceRules = @($badPerformance) } `
        -ExpectedText 'invalid samplingFrequencyInSeconds'
    $badPerformance.samplingFrequencyInSeconds = 60
    $badPerformance.counterSpecifiers = @('')
    Assert-TestPlanFailure -Stage 'collection-rules' -Operations @{ performanceRules = @($badPerformance) } `
        -ExpectedText 'invalid counterSpecifiers array'
    $badCtiRule = $ctiRule | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $badCtiRule.serviceCollectionFrequency = 599
    Assert-TestPlanFailure -Stage 'collection-rules' -Operations @{ changeTrackingRules = @($badCtiRule) } `
        -ExpectedText 'invalid serviceCollectionFrequency'
    $badCtiRule.serviceCollectionFrequency = 600
    $badCtiRule.fileInfo = @()
    Assert-TestPlanFailure -Stage 'collection-rules' -Operations @{ changeTrackingRules = @($badCtiRule) } `
        -ExpectedText 'invalid registry or file item array'
    $badGroup = $group | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $badGroup.emailReceivers = @()
    Assert-TestPlanFailure -Stage 'alerting' -Operations @{ actionGroups = @($badGroup) } `
        -ExpectedText 'invalid short name or empty receiver list'
    $badGroup.emailReceivers = @(@{ emailAddress = 'sensitive-synthetic-receiver' })
    $badGroup.groupShortName = '1234567890123'
    Assert-TestPlanFailure -Stage 'alerting' -Operations @{ actionGroups = @($badGroup) } `
        -ExpectedText 'invalid short name or empty receiver list'
    $badAlert = $alert | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $badAlert.queryTimeRange = 'P2D'
    $badAlert.severity = 5
    Assert-TestPlanFailure -Stage 'alerting' -Operations @{ alerts = @($badAlert) } -ExpectedText 'invalid severity'
    $badAlert.severity = 2
    $badAlert.extra = $true
    Assert-TestPlanFailure -Stage 'alerting' -Operations @{ alerts = @($badAlert) } `
        -ExpectedText 'missing or unrecognised fields'
    Write-Output 'PASS: Invalid staged-operation shapes and limits'

    $invalidPlan = @{
        parameters = @{
            stage = @{ value = 'ama' }
            workspaceResourceId = @{ value = $workspaceId }
            amaExtensions = @{ reference = @{ keyVault = 'synthetic' } }
        }
    }
    $invalidPlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    Assert-PlanFailure -ExpectedText 'unknown or non-literal parameter'
    $invalidPlan.parameters.amaExtensions = @{ value = @() }
    $invalidPlan.parameters.stage.value = 'agents'
    $invalidPlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    Assert-PlanFailure -ExpectedText 'supported stage'
    $invalidPlan.parameters.stage.value = 'ama'
    $invalidPlan.parameters.amaExtensions = @{ value = @(@{
                scope = $planScope; machineName = 'outside-selection'; extensionName = 'ama'
                location = 'uksouth'; typeHandlerVersion = '1.45'
            }) }
    $invalidPlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    Assert-PlanFailure -ExpectedText 'outside the explicitly selected scope'
    $invalidPlan.parameters.workspaceResourceId.value = $workspaceId + '-other'
    $invalidPlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath -Encoding utf8
    Assert-PlanFailure -ExpectedText 'explicitly selected existing workspace'
    Write-Output 'PASS: Invalid plan guards'

    $report = Get-TestReport
    $report.Checks = @($report.Checks | Where-Object { $_.Name -notlike '*Microsoft.Insights/metricAlerts' })
    Write-TestReport $report
    Assert-ReviewFailure -ExpectedText 'required discovery check is missing or duplicated'
    Write-Output 'PASS: Missing discovery coverage'

    $report = Get-TestReport
    $report.Resources += $report.Resources[1]
    Write-TestReport $report
    Assert-ReviewFailure -ExpectedText 'duplicate resource IDs'
    Write-Output 'PASS: Duplicate resources'

    $report = Get-TestReport
    $report.Resources = @($report.Resources | Where-Object { $_.id -ne $ruleId })
    Write-TestReport $report
    Assert-ReviewFailure -ExpectedText 'associated DCR is missing or duplicated'
    Write-Output 'PASS: Missing associated rule'

    $report = Get-TestReport
    $report.Servers[0].Extensions.Status = 'Failed'
    Write-TestReport $report
    Assert-ReviewFailure -ExpectedText 'missing or incomplete extension or association evidence'
    Write-Output 'PASS: Incomplete server evidence'

    $report = Get-TestReport
    $report.GeneratedAtUtc = [datetime]::UtcNow.AddMinutes(-61).ToString('o')
    Write-TestReport $report
    Assert-ReviewFailure -ExpectedText 'stale or future-dated'
    Write-Output 'PASS: Stale report'

    $baseline = Get-TestReport
    $baseline.GeneratedAtUtc = [datetime]::UtcNow.AddDays(-2).ToString('o')
    $baseline.PolicyDefinitions = @(@{
            id = '/providers/Microsoft.Authorization/policyDefinitions/test'
            displayName = 'Synthetic monitoring policy'
            policyRule = @{ then = @{ effect = 'Audit' } }
            metadata = @{ emptyObject = @{}; emptyArray = @(); nullValue = $null }
        })
    $baseline.Checks += @{ Name = 'Policy definition: /providers/Microsoft.Authorization/policyDefinitions/test'; Status = 'Succeeded' }
    $baseline.Workspaces[0].LinkedServices = @{ Status = 'Succeeded'; Items = @() }
    $baseline.Servers[0].Extensions.Items += @{
        Id = $server1 + '/extensions/other'; Name = 'other'; Category = 'Other'
        Publisher = 'Synthetic'; Type = 'Test'; Version = '1.0'; InstanceVersion = '1.0'; ProvisioningState = 'Succeeded'
    }
    $baseline.Servers[0].Associations.Items += @{
        id = $server1 + '/providers/Microsoft.Insights/dataCollectionRuleAssociations/endpoint'
        properties = @{ dataCollectionEndpointId = $prefix + 'Microsoft.Insights/dataCollectionEndpoints/example' }
    }
    $baselineRule = @($baseline.Resources | Where-Object { $_.id -eq $ruleId })[0]
    $baselineRule.properties.dataSources.performanceCounters[0].counterSpecifiers += '\Memory\Available MBytes'
    $removedAlertId = $prefix + 'Microsoft.Insights/metricAlerts/removed'
    $baseline.Resources += @{
        id = $removedAlertId; type = 'Microsoft.Insights/metricAlerts'
        properties = @{ enabled = $false; criteria = @{ threshold = 95 } }
    }
    foreach ($resource in $baseline.Resources) {
        $baseline.Checks += @{ Name = "Resource detail: $($resource.id)"; Status = 'Succeeded' }
    }
    $baseline | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $baselinePath -Encoding utf8
    $current = $baseline | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $current.GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    $current.CollectionStartedAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
    [array]::Reverse($current.Resources)
    [array]::Reverse($current.Servers[0].Extensions.Items)
    [array]::Reverse($current.Servers[0].Associations.Items)
    $rule = @($current.Resources | Where-Object { $_.id -eq $ruleId })[0]
    $reorderedProperties = [ordered]@{}
    foreach ($key in @($rule.properties.Keys | Sort-Object -Descending)) {
        $reorderedProperties[$key] = $rule.properties[$key]
    }
    $rule.properties = $reorderedProperties
    Write-TestReport $current
    $manifest = Invoke-TestComparison
    Assert-Review ($manifest.EvidenceComparison.Status -eq 'NoDriftObserved') 'Entity, extension and association order and JSON object-key order do not create drift'
    Assert-Review ($manifest.EvidenceComparison.Changes.Count -eq 0) 'Unchanged evidence produces no changes'
    Assert-Review ($manifest.EvidenceComparison.BaselineReportSha256 -eq (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash) 'The baseline hash is recorded'
    Write-Output 'PASS: Fresh evidence comparison without drift'

    foreach ($field in @('Selector', 'Stream', 'Transform', 'Destination', 'ArrayOrder')) {
        $singleChange = $baseline | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
        $singleChange.GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
        $singleChange.CollectionStartedAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
        $singleRule = @($singleChange.Resources | Where-Object { $_.id -eq $ruleId })[0]
        switch ($field) {
            'Selector' { $singleRule.properties.dataSources.performanceCounters[0].counterSpecifiers[0] = '\Synthetic\Changed' }
            'Stream' { $singleRule.properties.dataFlows[0].streams[0] = 'Synthetic-Changed' }
            'Transform' { $singleRule.properties.dataFlows[0].transformKql = 'source | where false' }
            'Destination' { $singleRule.properties.destinations.logAnalytics[0].workspaceResourceId += '-other' }
            'ArrayOrder' { [array]::Reverse($singleRule.properties.dataSources.performanceCounters[0].counterSpecifiers) }
        }
        Write-TestReport $singleChange
        $singleManifest = Invoke-TestComparison
        Assert-Review ($singleManifest.EvidenceComparison.Status -eq 'DriftDetected') "$field changes are not overlooked"
        Assert-Review (@($singleManifest.EvidenceComparison.Changes | Where-Object { $_.ResourceId -eq $ruleId -and $_.Change -eq 'Modified' }).Count -eq 1) "$field identifies the modified rule"
    }
    Write-Output 'PASS: Individual DCR selectors, streams, transforms, destinations and array order'

    $rule.properties.dataSources.performanceCounters[0].counterSpecifiers = @('\Memory\Available MBytes')
    $rule.properties.dataFlows[0].transformKql = 'source | where true'
    $group = @($current.Resources | Where-Object { $_.id -eq $groupId })[0]
    $group.properties.emailReceivers[0].emailAddress = 'changed-sensitive-synthetic-receiver'
    $alert = @($current.Resources | Where-Object { $_.id -eq $alertId })[0]
    $alert.properties.criteria.threshold = 80
    $current.Resources = @($current.Resources | Where-Object { $_.id -ne $removedAlertId })
    $current.Checks = @($current.Checks | Where-Object { $_.Name -ne "Resource detail: $removedAlertId" })
    $addedAlertId = $prefix + 'Microsoft.Insights/scheduledQueryRules/added'
    $current.Resources += @{
        id = $addedAlertId; type = 'Microsoft.Insights/scheduledQueryRules'; properties = @{ enabled = $false }
    }
    $current.Checks += @{ Name = "Resource detail: $addedAlertId"; Status = 'Succeeded' }
    $current.Servers[0].Associations.Items[0].properties.description = 'changed association'
    $current.Workspaces[0].RetentionInDays = 45
    $current.PolicyAssignments[0].enforcementMode = 'DoNotEnforce'
    $current.PolicyDefinitions[0].policyRule.then.effect = 'DeployIfNotExists'
    Write-TestReport $current
    $manifest = Invoke-TestComparison
    $changes = $manifest.EvidenceComparison.Changes
    Assert-Review ($manifest.EvidenceComparison.Status -eq 'DriftDetected') 'Modified evidence is flagged as drift'
    foreach ($id in @($ruleId, $groupId, $alertId, $server1, $workspaceId, $current.PolicyAssignments[0].id, $current.PolicyDefinitions[0].id)) {
        Assert-Review (@($changes | Where-Object { $_.ResourceId -eq $id -and $_.Change -eq 'Modified' }).Count -eq 1) 'Each modified evidence item is identified'
    }
    Assert-Review (@($changes | Where-Object { $_.ResourceId -eq $addedAlertId -and $_.Change -eq 'Added' }).Count -eq 1) 'Added resources are identified'
    Assert-Review (@($changes | Where-Object { $_.ResourceId -eq $removedAlertId -and $_.Change -eq 'Removed' }).Count -eq 1) 'Removed resources are identified'
    Assert-Review ((Get-Content -LiteralPath $createdFiles[$createdFiles.Count - 1] -Raw) -notmatch 'sensitive-synthetic-receiver') 'Comparison does not copy receiver destinations'
    Write-Output 'PASS: DCR, alert, receiver, association, workspace and policy drift'

    $invalid = $baseline | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100
    $invalid.GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'valid collection start time'
    $invalid.CollectionStartedAtUtc = [datetime]::UtcNow.AddMinutes(-16).ToString('o')
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'start within 15 minutes'
    $invalid.CollectionStartedAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
    $invalid.PolicyDefinitions += $invalid.PolicyDefinitions[0]
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'missing or duplicate IDs'
    $invalid.PolicyDefinitions = @($invalid.PolicyDefinitions[0])
    $invalid.Checks = @($invalid.Checks | Where-Object { $_.Name -ne "Resource detail: $groupId" })
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'required discovery check is missing or duplicated'
    $invalid.Checks += @{ Name = "Resource detail: $groupId"; Status = 'Succeeded' }
    $invalid.PolicyDefinitions = @()
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'policy assignment has missing definition evidence'
    $invalid.PolicyDefinitions = @($baseline.PolicyDefinitions[0])
    $invalid.Checks = @($invalid.Checks | Where-Object { $_.Name -ne "Extensions: $server2" })
    Write-TestReport $invalid
    Assert-ComparisonFailure -ExpectedText 'required discovery check is missing or duplicated' -SelectedServers @($server1)
    Write-Output 'PASS: Comparison freshness, completeness and duplicate guards'
}
finally {
    foreach ($file in $createdFiles) {
        Remove-Item -LiteralPath $file -ErrorAction Stop
        Remove-Item -LiteralPath (Split-Path -Parent $file) -ErrorAction Stop
    }
    Remove-Item -LiteralPath $reportPath -ErrorAction Stop
    Remove-Item -LiteralPath $baselinePath -ErrorAction Stop
    Remove-Item -LiteralPath $parameterPath -ErrorAction Stop
    Remove-Item -LiteralPath $testDirectory -ErrorAction Stop
}
