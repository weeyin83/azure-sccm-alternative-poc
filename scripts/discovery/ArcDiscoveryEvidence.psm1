Set-StrictMode -Version Latest

function Read-ArcDiscoveryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportPath,
        [ValidateRange(1, 1440)][int] $MaxAgeMinutes = 1440,
        [switch] $AllowStale
    )

    try { $json = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop }
    catch { throw 'The discovery report could not be read. Check the path and file permissions.' }
    try { $report = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100 -ErrorAction Stop }
    catch { throw 'The discovery report is not valid JSON.' }
    if ($report -isnot [System.Collections.IDictionary] -or
        $report['SchemaVersion'] -ne '1.0' -or
        $report['Status'] -ne 'CollectedPendingReview') {
        throw 'A complete discovery report with schema version 1.0 is required.'
    }

    $checks = @($report['Checks'])
    if ($checks.Count -eq 0 -or @($checks | Where-Object {
                $_ -isnot [System.Collections.IDictionary] -or $_['Status'] -ne 'Succeeded'
            }).Count -gt 0) {
        throw 'Discovery checks are missing or incomplete. Refresh discovery before querying.'
    }

    try { $generatedAt = [datetimeoffset] $report['GeneratedAtUtc'] }
    catch { throw 'The discovery report has no valid generation time.' }
    $now = [datetimeoffset]::UtcNow
    if ((-not $AllowStale -and $generatedAt -lt $now.AddMinutes(-$MaxAgeMinutes)) -or
        $generatedAt -gt $now.AddMinutes(5)) {
        throw 'The discovery report is stale or future-dated. Refresh discovery before querying.'
    }
    return $report
}

function Resolve-ArcDiscoveryScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][string] $WorkspaceResourceId,
        [Parameter(Mandatory)][ValidateCount(1, 10)][string[]] $ServerResourceId
    )

    $workspaces = @($Report['Workspaces'] | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_['Id'] -ieq $WorkspaceResourceId
        })
    $resources = @($Report['Resources'] | Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_['type'] -ieq 'Microsoft.OperationalInsights/workspaces' -and
            $_['id'] -ieq $WorkspaceResourceId
        })
    if ($workspaces.Count -ne 1 -or $resources.Count -ne 1) {
        throw 'The selected workspace must occur exactly once in the discovery report.'
    }
    $workspaceProperties = $resources[0]['properties']
    $workspaceGuid = [guid]::Empty
    if ($workspaceProperties -isnot [System.Collections.IDictionary] -or
        -not [guid]::TryParse([string] $workspaceProperties['customerId'], [ref] $workspaceGuid) -or
        $workspaceGuid -eq [guid]::Empty) {
        throw 'The selected workspace has no valid Log Analytics workspace ID in discovery.'
    }
    if ($WorkspaceResourceId -notmatch '(?i)^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
        throw 'The selected workspace resource ID has an invalid shape.'
    }
    $workspaceSubscription = $Matches[1]
    $subscriptionGuid = [guid]::Empty
    if (-not [guid]::TryParse($workspaceSubscription, [ref] $subscriptionGuid)) {
        throw 'The selected workspace subscription ID has an invalid shape.'
    }

    $selectedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $selectedServers = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ServerResourceId) {
        if ([string]::IsNullOrWhiteSpace($id) -or
            $id -notmatch '(?i)^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/[^/]+$') {
            throw 'A selected Arc machine resource ID has an invalid shape.'
        }
        $machineSubscription = [guid]::Empty
        if (-not [guid]::TryParse($Matches[1], [ref] $machineSubscription)) {
            throw 'A selected Arc machine subscription ID has an invalid shape.'
        }
        if (-not $selectedIds.Add($id)) {
            throw 'The selected Arc machine list contains duplicate IDs.'
        }
        $machineMatches = @($Report['Servers'] | Where-Object {
                $_ -is [System.Collections.IDictionary] -and $_['Id'] -ieq $id
            })
        if ($machineMatches.Count -ne 1) {
            throw 'Every selected Arc machine must occur exactly once in the discovery report.'
        }
        $selectedServers.Add($machineMatches[0])
    }

    [pscustomobject]@{
        Workspace = $workspaces[0]
        WorkspaceResource = $resources[0]
        WorkspaceGuid = $workspaceGuid
        WorkspaceSubscription = $workspaceSubscription
        ServerResourceIds = @($selectedIds)
        Servers = @($selectedServers.ToArray())
    }
}

function Assert-ArcDiscoveryCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][pscustomobject] $Scope,
        [switch] $AllServers
    )

    $subscriptions = @($Report['SubscriptionScope'])
    if ($subscriptions.Count -eq 0 -or @($subscriptions | Where-Object {
                $parsed = [guid]::Empty
                $_ -isnot [string] -or -not [guid]::TryParse($_, [ref] $parsed)
            }).Count -gt 0 -or @($subscriptions | Sort-Object -Unique).Count -ne $subscriptions.Count) {
        throw 'The discovery report has an invalid subscription scope.'
    }

    function Assert-RecordedCheck {
        param([string] $Name)
        $matchingChecks = @($Report['Checks'] | Where-Object { $_['Name'] -ieq $Name })
        if ($matchingChecks.Count -ne 1) {
            throw 'A required discovery check is missing or duplicated. Refresh the full discovery scope.'
        }
    }

    $resourceTypes = @(
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
        Assert-RecordedCheck -Name "Subscription access: $subscription"
        Assert-RecordedCheck -Name "Arc Windows inventory: $subscription"
        Assert-RecordedCheck -Name "Policy assignments: $subscription"
        foreach ($type in $resourceTypes) {
            Assert-RecordedCheck -Name "Resource list: $subscription/$type"
        }
    }
    if ($Scope.WorkspaceSubscription -notin $subscriptions) {
        throw 'The workspace subscription was not fully enumerated in discovery.'
    }
    Assert-RecordedCheck -Name "Workspace linked services: $($Scope.Workspace['Id'])"

    if ($Report['Resources'] -isnot [array] -or @($Report['Resources'] | Where-Object {
                $_ -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $_['id']) -or
                [string]::IsNullOrWhiteSpace([string] $_['type'])
            }).Count -gt 0) {
        throw 'A resource in the discovery report has an invalid shape.'
    }
    $resourceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in $Report['Resources']) {
        if (-not $resourceIds.Add([string] $resource['id'])) {
            throw 'The discovery report contains duplicate resource IDs.'
        }
        if ($AllServers) { Assert-RecordedCheck -Name "Resource detail: $($resource['id'])" }
    }

    if ($AllServers) {
        if ($Report['Workspaces'] -isnot [array] -or $Report['PolicyAssignments'] -isnot [array] -or
            $Report['PolicyDefinitions'] -isnot [array]) {
            throw 'The discovery report is missing workspace or policy evidence.'
        }
        foreach ($workspace in $Report['Workspaces']) {
            if ($workspace -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $workspace['Id']) -or
                $workspace['LinkedServices'] -isnot [System.Collections.IDictionary] -or
                $workspace['LinkedServices']['Status'] -ne 'Succeeded' -or
                $workspace['LinkedServices']['Items'] -isnot [array]) {
                throw 'A workspace has missing or incomplete linked-service evidence.'
            }
            Assert-RecordedCheck -Name "Workspace linked services: $($workspace['Id'])"
        }
        $definitions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($definition in $Report['PolicyDefinitions']) {
            if ($definition -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $definition['id']) -or
                -not $definitions.TryAdd([string] $definition['id'], $definition)) {
                throw 'The policy definition evidence has missing or duplicate IDs.'
            }
            Assert-RecordedCheck -Name "Policy definition: $($definition['id'])"
        }
        foreach ($assignment in $Report['PolicyAssignments']) {
            if ($assignment -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $assignment['id']) -or
                [string]::IsNullOrWhiteSpace([string] $assignment['policyDefinitionId']) -or
                -not $definitions.ContainsKey([string] $assignment['policyDefinitionId'])) {
                throw 'A policy assignment has missing definition evidence.'
            }
        }
        foreach ($definition in $Report['PolicyDefinitions']) {
            $members = $definition['policyDefinitions']
            if ([string] $definition['id'] -imatch '/policySetDefinitions/' -and $members -isnot [array]) {
                throw 'A policy initiative has missing member evidence.'
            }
            foreach ($member in @($members)) {
                if ($null -ne $member -and ($member -isnot [System.Collections.IDictionary] -or
                        [string]::IsNullOrWhiteSpace([string] $member['policyDefinitionId']) -or
                        -not $definitions.ContainsKey([string] $member['policyDefinitionId']))) {
                    throw 'A policy initiative has missing member definition evidence.'
                }
            }
        }
    }

    if ($AllServers -and $Report['Servers'] -isnot [array]) {
        throw 'The discovery report has invalid server evidence.'
    }
    $servers = if ($AllServers) { @($Report['Servers']) } else { @($Scope.Servers) }
    $serverIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($server in $servers) {
        if ($server -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string] $server['Id']) -or
            -not $serverIds.Add([string] $server['Id']) -or
            $server['Id'] -notmatch '(?i)^/subscriptions/([^/]+)/' -or
            $Matches[1] -notin $subscriptions) {
            throw 'A discovered server has an invalid or duplicate ID or lies outside the enumerated subscriptions.'
        }
        $id = [string] $server['Id']
        Assert-RecordedCheck -Name "Extensions: $id"
        Assert-RecordedCheck -Name "DCR associations: $id"
        foreach ($key in @('Extensions', 'Associations')) {
            $check = $server[$key]
            if ($check -isnot [System.Collections.IDictionary] -or $check['Status'] -ne 'Succeeded' -or
                $check['Items'] -isnot [array]) {
                throw 'A selected server has missing or incomplete extension or association evidence.'
            }
        }
        $extensionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($extension in $server['Extensions']['Items']) {
            if ($extension -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $extension['Id']) -or
                [string]::IsNullOrWhiteSpace([string] $extension['Category']) -or
                -not $extensionIds.Add([string] $extension['Id']) -or
                -not ([string] $extension['Id']).StartsWith("$id/extensions/", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'A selected server has malformed extension evidence.'
            }
            if ($AllServers -and ([string]::IsNullOrWhiteSpace([string] $extension['Publisher']) -or
                    [string]::IsNullOrWhiteSpace([string] $extension['Type']))) {
                throw 'A discovered extension has missing publisher or type evidence.'
            }
        }
        $associationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($association in $server['Associations']['Items']) {
            if ($association -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string] $association['id']) -or
                $association['properties'] -isnot [System.Collections.IDictionary] -or
                -not $associationIds.Add([string] $association['id']) -or
                -not ([string] $association['id']).StartsWith(
                    "$id/providers/Microsoft.Insights/dataCollectionRuleAssociations/", [System.StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'A selected server has malformed association evidence.'
            }
            $ruleId = [string] $association['properties']['dataCollectionRuleId']
            if ($AllServers -and -not $ruleId -and -not $association['properties']['dataCollectionEndpointId']) {
                throw 'A discovered association has no readable rule or endpoint reference.'
            }
            if ($ruleId -and @($Report['Resources'] | Where-Object {
                        $_['type'] -ieq 'Microsoft.Insights/dataCollectionRules' -and $_['id'] -ieq $ruleId
                    }).Count -ne 1) {
                throw 'An associated DCR is missing or duplicated in the discovery report.'
            }
        }
    }
}

Export-ModuleMember -Function Read-ArcDiscoveryReport, Resolve-ArcDiscoveryScope, Assert-ArcDiscoveryCoverage
