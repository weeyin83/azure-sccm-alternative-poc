#Requires -Version 7.2
<#
.SYNOPSIS
Collects read-only Azure Arc and monitoring configuration evidence.
.DESCRIPTION
Requires an existing Azure CLI login and the resource-graph CLI extension.
Only list/show commands, Resource Graph queries and ARM GET requests are used.
Customer evidence is written beneath output; the tracked findings document is
not overwritten. Collection errors produce partial reports and a terminating error.
.PARAMETER SubscriptionId
One or more subscription GUIDs to inspect, in the currently selected Azure cloud.
.EXAMPLE
./Invoke-ArcDiscovery.ps1 -SubscriptionId $subscriptionIds
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [guid[]] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()
$resources = @{}
$servers = [System.Collections.Generic.List[object]]::new()
$workspaceEvidence = [System.Collections.Generic.List[object]]::new()
$policyAssignments = @{}
$policyDefinitions = @{}
$subscriptions = @($SubscriptionId | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
$runPath = Join-Path $PSScriptRoot ('output/{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runPath

function Invoke-AzRead {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $prefix = ($Arguments | Select-Object -First 3) -join ' '
    if ($prefix -notmatch '^(account show|cloud show|extension list|resource (list|show)|graph query|policy assignment list|policy (definition|set-definition) show|rest --method get)( |$)') {
        throw "Non-discovery Azure CLI command refused: $prefix"
    }

    $errorPath = Join-Path $runPath 'cli-stderr.txt'
    try {
        $text = & az @Arguments --output json --only-show-errors 2> $errorPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = Get-Content -LiteralPath $errorPath -Raw
            throw "Azure CLI exited with code ${exitCode}: $detail"
        }
        if ([string]::IsNullOrWhiteSpace(($text -join "`n"))) {
            throw 'Azure CLI returned no JSON.'
        }
        ConvertFrom-Json -InputObject ($text -join "`n") -AsHashtable -Depth 100
    }
    finally {
        if (Test-Path -LiteralPath $errorPath) {
            Remove-Item -LiteralPath $errorPath
        }
    }
}

function Invoke-DiscoveryCheck {
    param([string] $Name, [scriptblock] $Operation)

    try {
        $items = @(& $Operation)
        $checks.Add(@{ Name = $Name; Status = 'Succeeded'; Count = $items.Count; Error = $null })
        return @{ Status = 'Succeeded'; Items = $items }
    }
    catch {
        $checks.Add(@{ Name = $Name; Status = 'Failed'; Count = $null; Error = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace })
        Write-Warning "Discovery check failed: $Name. See report.json for details."
        return @{ Status = 'Failed'; Items = @() }
    }
}

function Get-ArmList {
    param([string] $Url, [string] $Subscription)

    $seen = @{}
    do {
        if (-not $Url.StartsWith($armEndpoint, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'ARM pagination returned a URL outside the selected cloud endpoint.'
        }
        if ($seen.ContainsKey($Url)) { throw 'ARM pagination repeated a nextLink.' }
        $seen[$Url] = $true
        $page = Invoke-AzRead -Arguments @('rest', '--method', 'get', '--url', $Url, '--subscription', $Subscription)
        if (-not $page.Contains('value')) { throw 'ARM list response has no value array.' }
        foreach ($item in $page.value) { $item }
        $Url = $page.nextLink
    } while ($Url)
}

function Get-ResourceDetail {
    param([string] $Id, [string] $Subscription = $subscriptions[0])

    if (-not $resources.ContainsKey($Id)) {
        $resourceSubscription = if ($Id -match '^/subscriptions/([^/]+)/') { $Matches[1] } else { $Subscription }
        $result = Invoke-DiscoveryCheck -Name "Resource detail: $Id" -Operation {
            Invoke-AzRead -Arguments @('resource', 'show', '--ids', $Id, '--subscription', $resourceSubscription)
        }
        if ($result.Status -eq 'Succeeded') {
            $resources[$Id] = $result.Items[0]
        }
    }
    $resources[$Id]
}

function Get-GraphServer {
    param([string] $Subscription)

    $query = "Resources | where type =~ 'microsoft.hybridcompute/machines' | where properties.osType =~ 'Windows' or properties.osName =~ 'Windows' | project id, name, resourceGroup, location, subscriptionId, properties | order by id asc"
    $token = $null
    $seen = @{}
    $received = 0
    do {
        $arguments = @('graph', 'query', '--graph-query', $query, '--subscriptions', $Subscription, '--first', '1000')
        if ($token) { $arguments += @('--skip-token', $token) }
        $page = Invoke-AzRead -Arguments $arguments
        if (-not $page.Contains('data')) { throw 'Resource Graph response has no data array.' }
        foreach ($item in $page.data) { $item }
        $received += @($page.data).Count
        $token = $page.skip_token
        if (-not $token) { $token = $page.'$skipToken' }
        if ($token) {
            if ($seen.ContainsKey($token)) { throw 'Resource Graph repeated a skip token.' }
            $seen[$token] = $true
        }
        elseif ($page.resultTruncated -eq $true -or $page.resultTruncated -eq 'true' -or $page.total_records -gt $received) {
            throw 'Resource Graph truncated results without a continuation token.'
        }
    } while ($token)
}

function Get-ExtensionCategory {
    param($Extension)

    $key = '{0}/{1}' -f $Extension.properties.publisher, $Extension.properties.type
    switch ($key) {
        'Microsoft.Azure.Monitor/AzureMonitorWindowsAgent' { 'AMA' }
        'Microsoft.Azure.ChangeTrackingAndInventory/ChangeTracking-Windows' { 'ChangeTracking' }
        'Microsoft.Azure.Monitoring.DependencyAgent/DependencyAgentWindows' { 'DependencyAgent' }
        'Microsoft.EnterpriseCloud.Monitoring/MicrosoftMonitoringAgent' { 'LegacyMMA' }
        default { 'Other' }
    }
}

function Get-AgentState {
    param($Extensions, [string] $Category)

    if ($Extensions.Status -ne 'Succeeded') { return 'Unknown' }
    $matching = @($Extensions.Items | Where-Object { $_.Category -eq $Category })
    if ($matching.Count -eq 0) { return 'NotObserved' }
    if (@($matching | Where-Object { $_.ProvisioningState -ne 'Succeeded' }).Count -gt 0) { return 'NeedsReview' }
    'Provisioned'
}

function Get-PolicyDefinition {
    param([string] $Id, [string] $Subscription)

    if ($policyDefinitions.ContainsKey($Id)) { return }
    $result = Invoke-DiscoveryCheck -Name "Policy definition: $Id" -Operation {
        if ($Id -notmatch '/providers/Microsoft.Authorization/(policyDefinitions|policySetDefinitions)/([^/]+)$') {
            throw "Unsupported policy definition identifier: $Id"
        }
        $kind = if ($Matches[1] -eq 'policySetDefinitions') { 'set-definition' } else { 'definition' }
        $definitionName = $Matches[2]
        $arguments = @('policy', $kind, 'show', '--name', $definitionName)
        if ($Id -match '^/subscriptions/([^/]+)/') { $Subscription = $Matches[1] }
        if ($Id -match '^/providers/Microsoft.Management/managementGroups/([^/]+)/') {
            $arguments += @('--management-group', $Matches[1])
        }
        $arguments += @('--subscription', $Subscription)
        $definition = Invoke-AzRead -Arguments $arguments
        if ($definition.id -ine $Id) { throw "Policy reader returned a different definition from the requested ID: $Id" }
        $definition
    }
    if ($result.Status -eq 'Succeeded') {
        $definition = $result.Items[0]
        $policyDefinitions[$Id] = $definition
        foreach ($member in $definition.policyDefinitions) {
            Get-PolicyDefinition -Id $member.policyDefinitionId -Subscription $Subscription
        }
    }
}

try {
    $null = Get-Command az -ErrorAction Stop
    $extensions = @(Invoke-AzRead -Arguments @('extension', 'list'))
    if ('resource-graph' -notin @($extensions | ForEach-Object { $_.name })) {
        throw 'Missing resource-graph CLI extension. Install prerequisites explicitly before discovery.'
    }
    $cloud = Invoke-AzRead -Arguments @('cloud', 'show')
    $armEndpoint = $cloud.endpoints.resourceManager.TrimEnd('/') + '/'
    if (-not $armEndpoint.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected Azure cloud does not have an HTTPS Resource Manager endpoint.'
    }

    $types = @(
        'Microsoft.Insights/dataCollectionRules'
        'Microsoft.OperationalInsights/workspaces'
        'Microsoft.OperationsManagement/solutions'
        'Microsoft.Automation/automationAccounts'
        'Microsoft.Insights/metricAlerts'
        'Microsoft.Insights/scheduledQueryRules'
        'Microsoft.Insights/activityLogAlerts'
        'Microsoft.Insights/actionGroups'
    )
    foreach ($subscription in $subscriptions) {
        $account = Invoke-DiscoveryCheck -Name "Subscription access: $subscription" -Operation {
            Invoke-AzRead -Arguments @('account', 'show', '--subscription', $subscription)
        }
        if ($account.Status -ne 'Succeeded') { continue }

        foreach ($type in $types) {
            $listing = Invoke-DiscoveryCheck -Name "Resource list: $subscription/$type" -Operation {
                Invoke-AzRead -Arguments @('resource', 'list', '--resource-type', $type, '--subscription', $subscription)
            }
            foreach ($resource in $listing.Items) { $null = Get-ResourceDetail -Id $resource.id }
        }

        $assignmentCheck = Invoke-DiscoveryCheck -Name "Policy assignments: $subscription" -Operation {
            Invoke-AzRead -Arguments @(
                'policy', 'assignment', 'list', '--scope', "/subscriptions/$subscription",
                '--disable-scope-strict-match', 'true', '--subscription', $subscription
            )
        }
        foreach ($assignment in $assignmentCheck.Items) {
            $policyAssignments[$assignment.id] = $assignment
            Get-PolicyDefinition -Id $assignment.policyDefinitionId -Subscription $subscription
        }

        $graphCheck = Invoke-DiscoveryCheck -Name "Arc Windows inventory: $subscription" -Operation {
            Get-GraphServer -Subscription $subscription
        }
        foreach ($machine in $graphCheck.Items) {
            $machineId = $machine.id
            $extensionCheck = Invoke-DiscoveryCheck -Name "Extensions: $machineId" -Operation {
                foreach ($extension in (Get-ArmList -Url ($armEndpoint.TrimEnd('/') + "$machineId/extensions?api-version=2025-01-13") -Subscription $subscription)) {
                    @{
                        Id = $extension.id
                        Name = $extension.name
                        Publisher = $extension.properties.publisher
                        Type = $extension.properties.type
                        Version = $extension.properties.typeHandlerVersion
                        InstanceVersion = $extension.properties.instanceView.typeHandlerVersion
                        ProvisioningState = $extension.properties.provisioningState
                        Category = Get-ExtensionCategory -Extension $extension
                        # Only CTI public settings are needed; arbitrary extension settings can contain secrets.
                        ChangeTrackingSettings = if ((Get-ExtensionCategory -Extension $extension) -eq 'ChangeTracking') { $extension.properties.settings } else { $null }
                    }
                }
            }
            $associationCheck = Invoke-DiscoveryCheck -Name "DCR associations: $machineId" -Operation {
                Get-ArmList -Url ($armEndpoint.TrimEnd('/') + "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2024-03-11") -Subscription $subscription
            }
            foreach ($association in $associationCheck.Items) {
                if ($association.properties.dataCollectionRuleId) {
                    $null = Get-ResourceDetail -Id $association.properties.dataCollectionRuleId
                }
            }
            $servers.Add(@{
                Id = $machineId; Name = $machine.name; ResourceGroup = $machine.resourceGroup
                Location = $machine.location; SubscriptionId = $machine.subscriptionId
                OSName = $machine.properties.osName; OSSku = $machine.properties.osSku
                OSVersion = $machine.properties.osVersion; ArcAgentVersion = $machine.properties.agentVersion
                ConnectionStatus = $machine.properties.status; LastStatusChange = $machine.properties.lastStatusChange
                Extensions = $extensionCheck; Associations = $associationCheck
                AMA = Get-AgentState -Extensions $extensionCheck -Category 'AMA'
                ChangeTracking = Get-AgentState -Extensions $extensionCheck -Category 'ChangeTracking'
                DependencyAgent = Get-AgentState -Extensions $extensionCheck -Category 'DependencyAgent'
                LegacyMMA = Get-AgentState -Extensions $extensionCheck -Category 'LegacyMMA'
            })
        }
    }

    $dcrs = @($resources.Values | Where-Object { $_.type -ieq 'Microsoft.Insights/dataCollectionRules' })
    foreach ($dcr in $dcrs) {
        foreach ($destination in $dcr.properties.destinations.logAnalytics) {
            if ($destination.workspaceResourceId) { $null = Get-ResourceDetail -Id $destination.workspaceResourceId }
        }
    }

    $workspaces = @($resources.Values | Where-Object { $_.type -ieq 'Microsoft.OperationalInsights/workspaces' })
    $solutions = @($resources.Values | Where-Object { $_.type -ieq 'Microsoft.OperationsManagement/solutions' })
    foreach ($workspace in $workspaces) {
        $workspaceId = $workspace.id
        $workspaceSubscription = ($workspaceId -split '/')[2]
        $linked = Invoke-DiscoveryCheck -Name "Workspace linked services: $workspaceId" -Operation {
            Get-ArmList -Url ($armEndpoint.TrimEnd('/') + "$workspaceId/linkedServices?api-version=2020-08-01") -Subscription $workspaceSubscription
        }
        $workspaceSolutions = @($solutions | Where-Object { $_.properties.workspaceResourceId -ieq $workspaceId })
        $workspaceEvidence.Add(@{
            Id = $workspaceId; Name = $workspace.name; Location = $workspace.location
            RetentionInDays = $workspace.properties.retentionInDays; PricingTier = $workspace.properties.sku.name
            Solutions = @($workspaceSolutions | ForEach-Object { $_.name })
            ChangeTrackingSolutionObserved = @($workspaceSolutions | Where-Object { $_.plan.product -imatch 'ChangeTracking' -or $_.name -imatch '^ChangeTracking\(' }).Count -gt 0
            VMInsightsSolutionObserved = @($workspaceSolutions | Where-Object { $_.plan.product -imatch 'VMInsights' -or $_.name -imatch '^VMInsights\(' }).Count -gt 0
            LinkedServices = $linked
            ReuseRecommendation = 'Candidate only: confirm region, RBAC, network access, retention, capacity, ownership and data residency with the owner.'
        })
    }

    $alerts = @($resources.Values | Where-Object { $_.type -imatch '^Microsoft.Insights/(metricAlerts|scheduledQueryRules|activityLogAlerts)$' })
    foreach ($alert in $alerts) {
        $alertText = ConvertTo-Json -InputObject $alert -Depth 100 -Compress
        $related = @(@($servers.Id) + @($workspaces.id) | Where-Object { $_ -is [string] -and $_ })
        $targetMatches = @($related | Where-Object { $_ -and $alertText.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $ancestorScopes = @($alert.properties.scopes) + @($alert.properties.scope)
        $broadScope = @($ancestorScopes | Where-Object {
            $scope = $_
            $scope -is [string] -and @($related | Where-Object { $_.StartsWith($scope.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        }).Count -gt 0
        $alert['DiscoveryRelationship'] = if ($targetMatches.Count) { 'ResourceIdReference' } elseif ($broadScope) { 'AncestorScopeCandidate' } else { 'UnresolvedReviewRequired' }
        $alert['DiscoveredTargetIds'] = $targetMatches
        $actions = @($alert.properties.actions.actionGroups) + @($alert.properties.actions | ForEach-Object { $_.actionGroupId })
        foreach ($actionId in $actions) {
            if ($actionId -is [string] -and $actionId.StartsWith('/subscriptions/', [System.StringComparison]::OrdinalIgnoreCase)) {
                $null = Get-ResourceDetail -Id $actionId
            }
        }
    }

    foreach ($server in $servers) {
        $associated = @($server.Associations.Items | Where-Object { $_.properties.dataCollectionRuleId } |
            ForEach-Object { $resources[$_.properties.dataCollectionRuleId] } | Where-Object { $_ })
        $server['VMInsightsDcrCandidateIds'] = @($associated | Where-Object {
            (ConvertTo-Json -InputObject $_.properties -Depth 100 -Compress) -imatch 'Microsoft-InsightsMetrics|\\VmInsights\\'
        } | ForEach-Object { $_.id })
        $server['ChangeTrackingDcrCandidateIds'] = @($associated | Where-Object {
            (ConvertTo-Json -InputObject $_.properties -Depth 100 -Compress) -imatch 'Microsoft-ConfigurationChange|Microsoft-ConfigurationData|Microsoft-ChangeTracking|ChangeTracking'
        } | ForEach-Object { $_.id })
    }
}
catch {
    $checks.Add(@{ Name = 'Discovery execution'; Status = 'Failed'; Count = $null; Error = $_.Exception.Message; ScriptStackTrace = $_.ScriptStackTrace })
    Write-Warning 'Discovery could not complete. Partial evidence will be saved.'
}

$failed = @($checks | Where-Object { $_.Status -eq 'Failed' })
$summary = @($servers | ForEach-Object {
    [pscustomobject][ordered]@{
        Name = $_.Name; ResourceGroup = $_.ResourceGroup; Location = $_.Location
        SubscriptionId = $_.SubscriptionId; ResourceId = $_.Id; OSName = $_.OSName; OSSku = $_.OSSku
        OSVersion = $_.OSVersion; ArcAgentVersion = $_.ArcAgentVersion
        ConnectionStatus = $_.ConnectionStatus; LastStatusChange = $_.LastStatusChange
        AMA = $_.AMA; ChangeTracking = $_.ChangeTracking; DependencyAgent = $_.DependencyAgent; LegacyMMA = $_.LegacyMMA
        AssociationStatus = $_.Associations.Status; AssociationCount = if ($_.Associations.Status -eq 'Succeeded') { $_.Associations.Items.Count } else { $null }
        VMInsightsDcrCandidateCount = $_.VMInsightsDcrCandidateIds.Count
        ChangeTrackingDcrCandidateCount = $_.ChangeTrackingDcrCandidateIds.Count
    }
})
$report = [ordered]@{
    SchemaVersion = '1.0'; GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    Status = if ($failed.Count) { 'Incomplete' } else { 'CollectedPendingReview' }
    SubscriptionScope = $subscriptions; Checks = @($checks.ToArray()); Servers = @($servers.ToArray())
    Resources = @($resources.Values); Workspaces = @($workspaceEvidence.ToArray())
    PolicyAssignments = @($policyAssignments.Values); PolicyDefinitions = @($policyDefinitions.Values)
    RelevantPolicyCandidateIds = @($policyDefinitions.Values | Where-Object {
        (ConvertTo-Json -InputObject $_ -Depth 100 -Compress) -imatch 'Azure Monitor|AzureMonitor|dataCollectionRule|ChangeTracking|Change Tracking|VMInsights|VM insights|DependencyAgent|MicrosoftMonitoringAgent'
    } | ForEach-Object { $_.id })
    Limitations = @(
        'Azure control-plane configuration only; provisioning does not prove guest agent health or arriving data.'
        'Resource Graph is eventually consistent and returns only resources visible to the caller. NotObserved is not proof of absence.'
        'Workspace solution presence is evidence, not proof of active AMA or legacy collection; inspect DCRs, extensions and Automation links together.'
        'Policy relevance is a definition-text heuristic. Review initiatives, parameters, exclusions, selectors, exemptions and enforcement; no compliance scan is triggered.'
        'All scoped alert rules and Action Groups are retained, including unresolved query-based relationships. Review before adding any rule.'
        'Cross-subscription references are read where discovered. Supply all relevant subscriptions to enumerate their solutions, alerts and policy assignments.'
        'Guest-installed MMA without an Arc extension cannot be ruled out. No remote commands or guest software inventory are run.'
        'Potential DCR overlap must be reviewed by counter/event selector, interval, stream, transform and destination; multiple associations alone do not prove duplicate ingestion.'
    )
}
$jsonPath = Join-Path $runPath 'report.json'
$csvPath = Join-Path $runPath 'servers.csv'
ConvertTo-Json -InputObject $report -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8
if ($summary.Count) {
    $summary | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
}
else {
    '"Name","ResourceGroup","Location","SubscriptionId","ResourceId","OSName","OSSku","OSVersion","ArcAgentVersion","ConnectionStatus","LastStatusChange","AMA","ChangeTracking","DependencyAgent","LegacyMMA","AssociationStatus","AssociationCount","VMInsightsDcrCandidateCount","ChangeTrackingDcrCandidateCount"' |
        Set-Content -LiteralPath $csvPath -Encoding utf8
}
$findings = @(
    '# Discovery findings (customer evidence - do not commit)'
    ''
    "- Status: $($report.Status). Failed checks: $($failed.Count)."
    "- Observed Windows Arc servers: $($servers.Count). Workspaces: $($workspaceEvidence.Count)."
    "- DCRs: $(@($resources.Values | Where-Object { $_.type -ieq 'Microsoft.Insights/dataCollectionRules' }).Count). Alert rules: $(@($resources.Values | Where-Object { $_.type -imatch '^Microsoft.Insights/(metricAlerts|scheduledQueryRules|activityLogAlerts)$' }).Count)."
    ''
    '## Gaps, conflicts and duplicates'
    "- AMA not observed: $(@($servers | Where-Object { $_.AMA -eq 'NotObserved' }).Count). CTI extension not observed: $(@($servers | Where-Object { $_.ChangeTracking -eq 'NotObserved' }).Count)."
    "- MMA extension observed: $(@($servers | Where-Object { $_.LegacyMMA -in @('Provisioned', 'NeedsReview') }).Count). Review coexistence before changing collection."
    "- Multiple associations: $(@($servers | Where-Object { $_.Associations.Items.Count -gt 1 }).Count). Review DCR selectors, streams, intervals, transformations and destinations; this is not proof of duplication."
    'Failed or invisible reads are unknown, not absent. Inspect Checks in report.json before drawing conclusions.'
    ''
    '## Workspace reuse'
    'Reuse a suitable existing workspace. Review Workspaces and DCR destinations in report.json with the owner; no workspace is automatically selected and none is created.'
    ''
    '## Recommended next steps'
    '1. Resolve failed checks, confirm Reader visibility across the full scope and inspect all retained configuration.'
    '2. Review AMA/CTI extension and DCR coverage, legacy Automation links, VM Insights evidence, unresolved alerts and policy initiatives.'
    '3. Confirm workspace suitability and collection overlap with the owner. Never add duplicate monitoring or alerts.'
    '4. Share a sanitised summary in docs/discovery-findings.md, then stop for user review before Design.'
)
$findings | Set-Content -LiteralPath (Join-Path $runPath 'findings.md') -Encoding utf8
Write-Output "Discovery evidence saved to $runPath"
if ($failed.Count) {
    throw "Discovery incomplete: $($failed.Count) check(s) failed. Review $jsonPath; do not treat missing evidence as absence."
}
