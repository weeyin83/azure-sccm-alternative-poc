Set-StrictMode -Version Latest

function Get-ArcStagePlanReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][pscustomobject] $Scope,
        [Parameter(Mandatory)][System.Collections.IDictionary] $ParameterDocument,
        [Parameter(Mandatory)][string] $ParameterSha256
    )

    $nodes = $ParameterDocument['parameters']
    if ($nodes -isnot [System.Collections.IDictionary]) {
        throw 'The stage parameter file must contain an ARM parameters object.'
    }
    $arrayNames = @(
        'amaExtensions', 'changeTrackingExtensions', 'performanceRules',
        'changeTrackingRules', 'associations', 'actionGroups', 'alerts'
    )
    $allowedNames = @('stage', 'workspaceResourceId', 'tags') + $arrayNames
    $values = @{}
    foreach ($name in $nodes.Keys) {
        if ($name -notin $allowedNames -or $nodes[$name] -isnot [System.Collections.IDictionary] -or
            $nodes[$name].Count -ne 1 -or -not $nodes[$name].Contains('value')) {
            throw 'The stage parameter file contains an unknown or non-literal parameter.'
        }
        $values[$name] = $nodes[$name]['value']
    }
    if ($values['stage'] -isnot [string] -or
        $values['stage'] -notin @('ama', 'collection-rules', 'associations', 'change-tracking-extension', 'alerting')) {
        throw 'The stage parameter file must select a supported stage.'
    }
    if ($values['workspaceResourceId'] -isnot [string] -or
        $values['workspaceResourceId'] -ine $Scope.Workspace['Id']) {
        throw 'The stage plan must reference the explicitly selected existing workspace.'
    }
    if ($values.ContainsKey('tags') -and $values['tags'] -isnot [System.Collections.IDictionary]) {
        throw 'Stage tags must be an object.'
    }
    foreach ($name in $arrayNames) {
        if (-not $values.ContainsKey($name)) { $values[$name] = @() }
        if ($values[$name] -isnot [array]) {
            throw 'Every stage operation parameter must be a literal array.'
        }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-PlanFinding {
        param([string] $Code, [string] $Message, [string] $Subject = '', [string[]] $Related = @())
        $findings.Add([ordered]@{
                Code = $Code
                Message = $Message
                SubjectResourceId = if ($Subject) { $Subject } else { $null }
                RelatedResourceIds = @($Related)
            })
    }
    function Get-RequiredString {
        param([System.Collections.IDictionary] $Item, [string] $Name)
        if ($Item[$Name] -isnot [string] -or [string]::IsNullOrWhiteSpace($Item[$Name])) {
            throw "A planned operation has a missing or invalid $Name field."
        }
        return [string] $Item[$Name]
    }
    function Assert-ObjectField {
        param([System.Collections.IDictionary] $Item, [string[]] $Names)
        if ($Item.Count -ne $Names.Count -or @($Item.Keys | Where-Object { $_ -notin $Names }).Count -gt 0) {
            throw 'A planned operation has missing or unrecognised fields.'
        }
    }
    function Get-RequiredInteger {
        param([System.Collections.IDictionary] $Item, [string] $Name, [long] $Minimum, [long] $Maximum)
        $number = $Item[$Name]
        if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt $Minimum -or $number -gt $Maximum) {
            throw "A planned operation has a missing or invalid $Name field."
        }
        return [long] $number
    }
    function Assert-StringArray {
        param([System.Collections.IDictionary] $Item, [string] $Name)
        $array = $Item[$Name]
        if ($array -isnot [array] -or $array.Count -eq 0 -or @($array | Where-Object {
                    $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
                }).Count -gt 0) {
            throw "A planned operation has a missing or invalid $Name array."
        }
    }
    function Get-ResourcePrefix {
        param([System.Collections.IDictionary] $Item)
        $itemScope = $Item['scope']
        if ($itemScope -isnot [System.Collections.IDictionary]) {
            throw 'A planned operation has a missing or invalid scope.'
        }
        Assert-ObjectField -Item $itemScope -Names @('subscriptionId', 'resourceGroupName')
        $subscription = Get-RequiredString -Item $itemScope -Name 'subscriptionId'
        $resourceGroup = Get-RequiredString -Item $itemScope -Name 'resourceGroupName'
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($subscription, [ref] $parsed) -or
            $subscription -notin $Report['SubscriptionScope'] -or $resourceGroup.Contains('/')) {
            throw 'A planned operation is outside the enumerated subscription scope or has an invalid resource group.'
        }
        return "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers"
    }
    function Get-SimpleName {
        param([System.Collections.IDictionary] $Item, [string] $Name)
        $value = Get-RequiredString -Item $Item -Name $Name
        if ($value.Contains('/')) { throw "A planned operation has an invalid $Name field." }
        return $value
    }
    function Get-SelectedServer {
        param([string] $Id)
        $items = @($Scope.Servers | Where-Object { $_['Id'] -ieq $Id })
        if ($items.Count -ne 1) {
            throw 'A planned operation targets a server outside the explicitly selected scope.'
        }
        return $items[0]
    }
    function Get-RuleKind {
        param([System.Collections.IDictionary] $Rule)
        $kinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $properties = $Rule['properties']
        if ($properties -isnot [System.Collections.IDictionary] -or
            $properties['dataSources'] -isnot [System.Collections.IDictionary]) {
            $null = $kinds.Add('Unknown')
            return @($kinds)
        }
        $sources = $properties['dataSources']
        foreach ($key in $sources.Keys) {
            $items = $sources[$key]
            if ($items -isnot [array]) {
                $null = $kinds.Add('Unknown')
                continue
            }
            if ($items.Count -eq 0) { continue }
            switch -Regex ($key) {
                '^performanceCounters$' { $null = $kinds.Add('Performance') }
                '^windowsEventLogs$' { $null = $kinds.Add('WindowsEvents') }
                '^extensions$' {
                    foreach ($extension in $items) {
                        if ($extension -is [System.Collections.IDictionary] -and
                            [string] $extension['extensionName'] -imatch 'ChangeTracking') {
                            $null = $kinds.Add('ChangeTracking')
                        }
                        else { $null = $kinds.Add('Unknown') }
                    }
                }
                default { $null = $kinds.Add('Unknown') }
            }
        }
        $ruleText = ConvertTo-Json -InputObject $properties -Depth 100 -Compress
        if ($ruleText -imatch 'Microsoft-ConfigurationChange|Microsoft-ConfigurationData|Microsoft-ChangeTracking') {
            $null = $kinds.Add('ChangeTracking')
        }
        if ($kinds.Count -eq 0) { $null = $kinds.Add('Unknown') }
        return @($kinds)
    }
    function Get-LiteralCollectionPath {
        param([System.Collections.IDictionary] $Rule)
        $paths = [System.Collections.Generic.List[object]]::new()
        $complete = $true
        $properties = $Rule['properties']
        if ($properties -isnot [System.Collections.IDictionary] -or
            $properties['dataSources'] -isnot [System.Collections.IDictionary] -or
            $properties['dataFlows'] -isnot [array] -or
            $properties['destinations'] -isnot [System.Collections.IDictionary] -or
            $properties['destinations']['logAnalytics'] -isnot [array]) {
            return [pscustomobject]@{ Paths = @(); Complete = $false }
        }
        $sources = $properties['dataSources']
        $destinations = $properties['destinations']['logAnalytics']
        foreach ($flow in $properties['dataFlows']) {
            if ($flow -isnot [System.Collections.IDictionary] -or $flow['streams'] -isnot [array] -or
                $flow['destinations'] -isnot [array]) {
                $complete = $false
                continue
            }
            if (@($flow['streams'] + $flow['destinations'] | Where-Object {
                        $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
                    }).Count -gt 0) {
                $complete = $false
            }
        }
        foreach ($key in $sources.Keys) {
            if ($key -notin @('performanceCounters', 'windowsEventLogs') -and @($sources[$key]).Count -gt 0) {
                $complete = $false
            }
        }
        foreach ($kind in @(
                @{ Name = 'performanceCounters'; Selectors = 'counterSpecifiers' }
                @{ Name = 'windowsEventLogs'; Selectors = 'xPathQueries' }
            )) {
            if (-not $sources.Contains($kind.Name)) { continue }
            if ($sources[$kind.Name] -isnot [array]) { $complete = $false; continue }
            foreach ($source in $sources[$kind.Name]) {
                if ($source -isnot [System.Collections.IDictionary] -or
                    $source['streams'] -isnot [array] -or $source['streams'].Count -eq 0 -or
                    $source[$kind.Selectors] -isnot [array] -or $source[$kind.Selectors].Count -eq 0) {
                    $complete = $false
                    continue
                }
                $interval = $null
                if ($kind.Name -eq 'performanceCounters') {
                    $seconds = 0
                    if (-not [int]::TryParse([string] $source['samplingFrequencyInSeconds'], [ref] $seconds) -or $seconds -le 0) {
                        $complete = $false
                        continue
                    }
                    $interval = $seconds
                }
                foreach ($stream in $source['streams']) {
                    if ($stream -isnot [string] -or [string]::IsNullOrWhiteSpace($stream)) {
                        $complete = $false
                        continue
                    }
                    $matchingFlows = @($properties['dataFlows'] | Where-Object {
                            $_ -is [System.Collections.IDictionary] -and $_['streams'] -is [array] -and
                            $stream -cin $_['streams']
                        })
                    if ($matchingFlows.Count -eq 0) { $complete = $false }
                    foreach ($flow in $matchingFlows) {
                        if ($flow['destinations'] -isnot [array] -or $flow['destinations'].Count -eq 0) {
                            $complete = $false
                            continue
                        }
                        foreach ($destinationName in $flow['destinations']) {
                            if ($destinationName -isnot [string] -or [string]::IsNullOrWhiteSpace($destinationName)) {
                                $complete = $false
                                continue
                            }
                            $matchingDestinations = @($destinations | Where-Object {
                                    $_ -is [System.Collections.IDictionary] -and $_['name'] -ceq $destinationName
                                })
                            if ($matchingDestinations.Count -ne 1 -or
                                [string]::IsNullOrWhiteSpace([string] $matchingDestinations[0]['workspaceResourceId'])) {
                                $complete = $false
                                continue
                            }
                            $hasNamedTransform = $null -ne $source['transform'] -or
                                $null -ne $flow['transform'] -or $null -ne $properties['transformations']
                            if ($hasNamedTransform -or
                                ($null -ne $flow['transformKql'] -and $flow['transformKql'] -isnot [string]) -or
                                ($null -ne $flow['outputStream'] -and $flow['outputStream'] -isnot [string])) {
                                $complete = $false
                            }
                            foreach ($selector in $source[$kind.Selectors]) {
                                if ($selector -isnot [string] -or [string]::IsNullOrWhiteSpace($selector)) {
                                    $complete = $false
                                    continue
                                }
                                $paths.Add([pscustomobject]@{
                                        Kind = $kind.Name
                                        Selector = $selector
                                        Stream = $stream
                                        Workspace = $matchingDestinations[0]['workspaceResourceId']
                                        Interval = $interval
                                        InlineTransform = $flow['transformKql']
                                        OutputStream = $flow['outputStream']
                                        HasNamedTransform = $hasNamedTransform
                                    })
                            }
                        }
                    }
                }
            }
        }
        return [pscustomobject]@{ Paths = @($paths.ToArray()); Complete = $complete -and $paths.Count -gt 0 }
    }
    function Add-LiteralOverlapFinding {
        param([string] $Subject, [string] $RelatedRuleId, [pscustomobject] $Target, [pscustomobject] $Existing)
        if (-not $Target.Complete -or -not $Existing.Complete) {
            Add-PlanFinding -Code 'LiteralCollectionComparisonIncomplete' -Subject $Subject -Related @($RelatedRuleId) `
                -Message 'Some collection paths could not be compared literally; inspect all sources, flows, transformations and destinations.'
        }
        $matchingPath = $false
        $matchingSettings = $false
        foreach ($targetPath in $Target.Paths) {
            foreach ($existingPath in $Existing.Paths) {
                if ($targetPath.Kind -ceq $existingPath.Kind -and $targetPath.Selector -ceq $existingPath.Selector -and
                    $targetPath.Stream -ceq $existingPath.Stream -and $targetPath.Workspace -ieq $existingPath.Workspace) {
                    $matchingPath = $true
                    if ($Target.Complete -and $Existing.Complete -and
                        -not $targetPath.HasNamedTransform -and -not $existingPath.HasNamedTransform -and
                        $targetPath.Interval -eq $existingPath.Interval -and
                        $targetPath.InlineTransform -ceq $existingPath.InlineTransform -and
                        $targetPath.OutputStream -ceq $existingPath.OutputStream) {
                        $matchingSettings = $true
                    }
                }
            }
        }
        if ($matchingPath) {
            Add-PlanFinding -Code 'MatchingLiteralSelectorDestination' -Subject $Subject -Related @($RelatedRuleId) `
                -Message 'A literal counter or event selector, stream and workspace match an associated rule; inspect possible duplicate collection.'
        }
        if ($matchingSettings) {
            Add-PlanFinding -Code 'MatchingLiteralCollectionSettings' -Subject $Subject -Related @($RelatedRuleId) `
                -Message 'A matching literal path also has the same recorded interval, inline transform and output stream; inspect remaining settings and consumers.'
        }
    }

    $stage = $values['stage']
    $stageArrays = switch ($stage) {
        'ama' { @('amaExtensions') }
        'collection-rules' { @('performanceRules', 'changeTrackingRules') }
        'associations' { @('associations') }
        'change-tracking-extension' { @('changeTrackingExtensions') }
        'alerting' { @('actionGroups', 'alerts') }
    }
    foreach ($name in $arrayNames) {
        if ($name -notin $stageArrays -and $values[$name].Count -gt 0) {
            Add-PlanFinding -Code 'InactiveOperations' -Message 'The parameter file contains operations ignored by the selected stage.'
        }
    }
    $operationCount = 0
    foreach ($name in $stageArrays) { $operationCount += $values[$name].Count }
    if ($operationCount -eq 0) {
        Add-PlanFinding -Code 'EmptyStage' -Message 'The selected stage contains no operations.'
    }

    $resources = @($Report['Resources'])
    $rules = @($resources | Where-Object { $_['type'] -ieq 'Microsoft.Insights/dataCollectionRules' })
    $plannedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($stage -in @('ama', 'change-tracking-extension')) {
        foreach ($entry in @(@(
                @{ Name = 'amaExtensions'; Category = 'AMA' }
                @{ Name = 'changeTrackingExtensions'; Category = 'ChangeTracking' }
            ) | Where-Object { $_.Name -in $stageArrays })) {
            foreach ($item in $values[$entry.Name]) {
                if ($item -isnot [System.Collections.IDictionary]) { throw 'A planned extension has an invalid shape.' }
                Assert-ObjectField -Item $item -Names @('scope', 'machineName', 'extensionName', 'location', 'typeHandlerVersion')
                $prefix = Get-ResourcePrefix -Item $item
                $machine = Get-SimpleName -Item $item -Name 'machineName'
                $extensionName = Get-SimpleName -Item $item -Name 'extensionName'
                $location = Get-RequiredString -Item $item -Name 'location'
                $version = Get-RequiredString -Item $item -Name 'typeHandlerVersion'
                if ($version -notmatch '^\d+(\.\d+){1,3}$') { throw 'A planned extension has an invalid handler version.' }
                $machineId = "$prefix/Microsoft.HybridCompute/machines/$machine"
                $extensionId = "$machineId/extensions/$extensionName"
                $server = Get-SelectedServer -Id $machineId
                if (-not $plannedIds.Add($extensionId)) {
                    Add-PlanFinding -Code 'RepeatedPlannedResource' -Subject $extensionId -Message 'The plan creates the same extension more than once.'
                }
                if ($location -ine $server['Location']) {
                    Add-PlanFinding -Code 'ExtensionLocationMismatch' -Subject $extensionId -Message 'The extension region differs from the discovered machine region.'
                }
                $existing = @($server['Extensions']['Items'] | Where-Object {
                        $_['Category'] -ieq $entry.Category -or $_['Id'] -ieq $extensionId
                    })
                if ($existing.Count -gt 0) {
                    Add-PlanFinding -Code 'ExistingExtensionRequiresReview' -Subject $extensionId `
                        -Related @($existing | ForEach-Object { $_['Id'] }) `
                        -Message 'An extension of this category or name already exists; assess reuse rather than create.'
                }
            }
        }
        Add-PlanFinding -Code 'GuestAndVersionReview' -Message 'Guest-installed agents, handler availability and agent health require separate evidence.'
    }
    elseif ($stage -eq 'collection-rules') {
        foreach ($entry in @(
                @{ Name = 'performanceRules'; Kind = 'Performance' }
                @{ Name = 'changeTrackingRules'; Kind = 'ChangeTracking' }
            )) {
            foreach ($item in $values[$entry.Name]) {
                if ($item -isnot [System.Collections.IDictionary]) { throw 'A planned DCR has an invalid shape.' }
                if ($entry.Kind -eq 'Performance') {
                    Assert-ObjectField -Item $item -Names @(
                        'scope', 'name', 'location', 'counterSpecifiers', 'samplingFrequencyInSeconds', 'eventXPathQueries'
                    )
                }
                else {
                    Assert-ObjectField -Item $item -Names @(
                        'scope', 'name', 'location', 'registryInfo', 'fileInfo', 'fileCollectionFrequency', 'serviceCollectionFrequency'
                    )
                }
                $prefix = Get-ResourcePrefix -Item $item
                $name = Get-SimpleName -Item $item -Name 'name'
                $null = Get-RequiredString -Item $item -Name 'location'
                $id = "$prefix/Microsoft.Insights/dataCollectionRules/$name"
                if (-not $plannedIds.Add($id)) {
                    Add-PlanFinding -Code 'RepeatedPlannedResource' -Subject $id -Message 'The plan creates the same DCR more than once.'
                }
                if (@($rules | Where-Object { $_['id'] -ieq $id }).Count -gt 0) {
                    Add-PlanFinding -Code 'ExistingResourceName' -Subject $id -Message 'The proposed DCR resource ID already exists and must not be overwritten.'
                }
                $candidates = @($rules | Where-Object {
                        $kinds = @(Get-RuleKind -Rule $_)
                        if ($entry.Kind -eq 'Performance') {
                            'Performance' -in $kinds -or 'WindowsEvents' -in $kinds -or 'Unknown' -in $kinds
                        }
                        else { 'ChangeTracking' -in $kinds -or 'Unknown' -in $kinds }
                    })
                if ($candidates.Count -gt 0) {
                    Add-PlanFinding -Code 'ExistingCollectionReview' -Subject $id `
                        -Related @($candidates | ForEach-Object { $_['id'] }) `
                        -Message 'Existing rules may overlap; compare selectors, streams, transformations, destinations and consumers.'
                }
                if ($entry.Kind -eq 'Performance') {
                    foreach ($field in @('counterSpecifiers', 'eventXPathQueries')) {
                        Assert-StringArray -Item $item -Name $field
                    }
                    $null = Get-RequiredInteger -Item $item -Name 'samplingFrequencyInSeconds' -Minimum 1 -Maximum ([int]::MaxValue)
                    if (@($item['eventXPathQueries'] | Where-Object { $_ -is [string] -and $_ -imatch '^\s*Security!' }).Count -gt 0) {
                        Add-PlanFinding -Code 'SecurityCollectionReview' -Subject $id -Message 'Security event collection requires separate privacy, permissions and cost approval.'
                    }
                }
                else {
                    foreach ($field in @(
                            @{ Name = 'registryInfo'; Maximum = 250 }
                            @{ Name = 'fileInfo'; Maximum = 500 }
                        )) {
                        $items = $item[$field.Name]
                        if ($items -isnot [array] -or $items.Count -eq 0 -or $items.Count -gt $field.Maximum -or
                            @($items | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -gt 0) {
                            throw 'A planned Change Tracking DCR has an invalid registry or file item array.'
                        }
                    }
                    $null = Get-RequiredInteger -Item $item -Name 'fileCollectionFrequency' -Minimum 1800 -Maximum 2400
                    $null = Get-RequiredInteger -Item $item -Name 'serviceCollectionFrequency' -Minimum 600 -Maximum 1800
                    Add-PlanFinding -Code 'ChangeTrackingSchemaReview' -Subject $id -Message 'Validate the Windows file schema and collection frequencies before creating this rule.'
                    if ($item['location'] -ine $Scope.Workspace['Location']) {
                        Add-PlanFinding -Code 'ChangeTrackingLocationMismatch' -Subject $id -Message 'The CTI DCR region differs from the selected workspace region.'
                    }
                    if ($Scope.Workspace['Id'] -notmatch '(?i)^/subscriptions/([^/]+)/resourceGroups/([^/]+)/' -or
                        $prefix -ine "/subscriptions/$($Matches[1])/resourceGroups/$($Matches[2])/providers") {
                        Add-PlanFinding -Code 'ChangeTrackingScopeMismatch' -Subject $id -Message 'The CTI DCR must be reviewed against the workspace resource group and subscription.'
                    }
                }
            }
        }
    }
    elseif ($stage -eq 'associations') {
        $plannedByServer = @{}
        foreach ($item in $values['associations']) {
            if ($item -isnot [System.Collections.IDictionary]) { throw 'A planned association has an invalid shape.' }
            Assert-ObjectField -Item $item -Names @('scope', 'machineName', 'associationName', 'dataCollectionRuleId')
            $prefix = Get-ResourcePrefix -Item $item
            $machine = Get-SimpleName -Item $item -Name 'machineName'
            $name = Get-SimpleName -Item $item -Name 'associationName'
            $ruleId = Get-RequiredString -Item $item -Name 'dataCollectionRuleId'
            $machineId = "$prefix/Microsoft.HybridCompute/machines/$machine"
            $id = "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$name"
            $server = Get-SelectedServer -Id $machineId
            if (-not $plannedIds.Add($id)) {
                Add-PlanFinding -Code 'RepeatedPlannedResource' -Subject $id -Message 'The plan creates the same association more than once.'
            }
            $existingAssociations = @($server['Associations']['Items'])
            $matching = @($existingAssociations | Where-Object {
                    $_['id'] -ieq $id -or $_['properties']['dataCollectionRuleId'] -ieq $ruleId
                })
            if ($matching.Count -gt 0) {
                Add-PlanFinding -Code 'ExistingAssociation' -Subject $id -Related @($matching | ForEach-Object { $_['id'] }) `
                    -Message 'An association with this name or DCR already exists; preserve and assess reuse.'
            }
            $target = @($rules | Where-Object { $_['id'] -ieq $ruleId })
            if ($target.Count -ne 1) {
                Add-PlanFinding -Code 'TargetDcrNotDiscovered' -Subject $id -Message 'Refresh discovery after the target DCR exists; do not assume its configuration.'
                continue
            }
            $targetKinds = @(Get-RuleKind -Rule $target[0])
            $targetPaths = Get-LiteralCollectionPath -Rule $target[0]
            if ('Unknown' -in $targetKinds) {
                Add-PlanFinding -Code 'UnknownTargetCollection' -Subject $id -Related @($ruleId) `
                    -Message 'The target rule contains an unclassified data source.'
            }
            $destinations = $target[0]['properties']['destinations']
            if ($destinations -isnot [System.Collections.IDictionary] -or $destinations['logAnalytics'] -isnot [array]) {
                Add-PlanFinding -Code 'WorkspaceDestinationNotVerified' -Subject $id -Related @($ruleId) `
                    -Message 'The target rule has no readable Log Analytics destination list.'
            }
            else {
                $workspaceDestinations = @($destinations['logAnalytics'] | Where-Object {
                        $_ -is [System.Collections.IDictionary] -and $_['workspaceResourceId'] -ieq $Scope.Workspace['Id']
                    })
                if ($workspaceDestinations.Count -eq 0) {
                    Add-PlanFinding -Code 'WorkspaceDestinationMismatch' -Subject $id -Related @($ruleId) `
                        -Message 'The selected workspace is not an observed Log Analytics destination of this rule.'
                }
                $otherDestinations = @($destinations['logAnalytics'] | Where-Object {
                        $_ -isnot [System.Collections.IDictionary] -or $_['workspaceResourceId'] -ine $Scope.Workspace['Id']
                    })
                $otherDestinationTypes = @($destinations.Keys | Where-Object {
                        $_ -ine 'logAnalytics' -and @($destinations[$_]).Count -gt 0
                    })
                if ($otherDestinations.Count -gt 0 -or $otherDestinationTypes.Count -gt 0) {
                    Add-PlanFinding -Code 'AdditionalDestinationsReview' -Subject $id -Related @($ruleId) `
                        -Message 'The target rule has additional or unrecognised destinations.'
                }
            }
            $prior = @($plannedByServer[$machineId])
            foreach ($other in $prior) {
                if ($other -and ($other.RuleId -ieq $ruleId -or 'Unknown' -in $other.Kinds -or
                        'Unknown' -in $targetKinds -or @($targetKinds | Where-Object { $_ -in $other.Kinds }).Count -gt 0)) {
                    Add-PlanFinding -Code 'PlannedAssociationOverlap' -Subject $id -Related @($other.Id) `
                        -Message 'Planned associations may collect the same data or contain unknown sources.'
                }
                if ($other) {
                    Add-LiteralOverlapFinding -Subject $id -RelatedRuleId $other.RuleId -Target $targetPaths -Existing $other.Paths
                }
            }
            $plannedByServer[$machineId] = @($prior | Where-Object { $_ }) + @([pscustomobject]@{
                    Id = $id; RuleId = $ruleId; Kinds = $targetKinds; Paths = $targetPaths
                })
            foreach ($association in $existingAssociations) {
                $existingRuleId = $association['properties']['dataCollectionRuleId']
                if (-not $existingRuleId -or $existingRuleId -ieq $ruleId) { continue }
                $existingRule = @($rules | Where-Object { $_['id'] -ieq $existingRuleId })
                if ($existingRule.Count -ne 1) { throw 'An existing association has no unique DCR evidence.' }
                $existingKinds = @(Get-RuleKind -Rule $existingRule[0])
                if ('Unknown' -in $targetKinds -or 'Unknown' -in $existingKinds -or
                    @($targetKinds | Where-Object { $_ -in $existingKinds }).Count -gt 0) {
                    Add-PlanFinding -Code 'ExistingAssociationOverlap' -Subject $id -Related @($association['id'], $existingRuleId) `
                        -Message 'An existing association may overlap or has unknown sources. Review selectors and cutover before adding another.'
                }
                $existingPaths = Get-LiteralCollectionPath -Rule $existingRule[0]
                Add-LiteralOverlapFinding -Subject $id -RelatedRuleId $existingRuleId -Target $targetPaths -Existing $existingPaths
            }
            Add-PlanFinding -Code 'DestinationAndTransformReview' -Subject $id -Related @($ruleId) `
                -Message 'Verify the target DCR destinations, streams, transformations, ownership and all consumers.'
        }
    }
    elseif ($stage -eq 'alerting') {
        $existingAlerts = @($resources | Where-Object {
                $_['type'] -imatch '^Microsoft\.Insights/(metricAlerts|scheduledQueryRules|activityLogAlerts)$'
            })
        $existingGroups = @($resources | Where-Object { $_['type'] -ieq 'Microsoft.Insights/actionGroups' })
        $newGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $values['actionGroups']) {
            if ($item -isnot [System.Collections.IDictionary]) { throw 'A planned Action Group has an invalid shape.' }
            Assert-ObjectField -Item $item -Names @('scope', 'name', 'groupShortName', 'emailReceivers')
            $prefix = Get-ResourcePrefix -Item $item
            $name = Get-SimpleName -Item $item -Name 'name'
            $shortName = Get-RequiredString -Item $item -Name 'groupShortName'
            if ($shortName.Length -gt 12 -or $item['emailReceivers'] -isnot [array] -or
                $item['emailReceivers'].Count -eq 0) {
                throw 'A planned Action Group has an invalid short name or empty receiver list.'
            }
            foreach ($receiver in $item['emailReceivers']) {
                if ($receiver -isnot [System.Collections.IDictionary]) {
                    throw 'A planned Action Group has an invalid receiver.'
                }
                Assert-ObjectField -Item $receiver -Names @('emailAddress')
                $null = Get-RequiredString -Item $receiver -Name 'emailAddress'
            }
            $id = "$prefix/Microsoft.Insights/actionGroups/$name"
            if (-not $newGroupIds.Add($id)) {
                Add-PlanFinding -Code 'RepeatedPlannedResource' -Subject $id -Message 'The plan creates the same Action Group more than once.'
            }
            if (@($existingGroups | Where-Object { $_['id'] -ieq $id }).Count -gt 0) {
                Add-PlanFinding -Code 'ExistingResourceName' -Subject $id -Message 'The proposed Action Group resource ID already exists and must not be overwritten.'
            }
            if ($existingGroups.Count -gt 0) {
                Add-PlanFinding -Code 'ExistingActionGroupReview' -Subject $id -Related @($existingGroups | ForEach-Object { $_['id'] }) `
                    -Message 'Review existing Action Group recipients, ownership and suitability before creating another group.'
            }
        }
        foreach ($item in $values['alerts']) {
            if ($item -isnot [System.Collections.IDictionary]) { throw 'A planned alert has an invalid shape.' }
            Assert-ObjectField -Item $item -Names @(
                'scope', 'name', 'displayName', 'location', 'description', 'actionGroupResourceId', 'query',
                'evaluationFrequency', 'windowSize', 'queryTimeRange', 'autoMitigate', 'splitByResourceId', 'severity'
            )
            $prefix = Get-ResourcePrefix -Item $item
            $name = Get-SimpleName -Item $item -Name 'name'
            $null = Get-RequiredString -Item $item -Name 'location'
            $null = Get-RequiredString -Item $item -Name 'displayName'
            $null = Get-RequiredString -Item $item -Name 'description'
            $null = Get-RequiredInteger -Item $item -Name 'severity' -Minimum 0 -Maximum 4
            $actionGroupId = Get-RequiredString -Item $item -Name 'actionGroupResourceId'
            $query = Get-RequiredString -Item $item -Name 'query'
            $frequency = Get-RequiredString -Item $item -Name 'evaluationFrequency'
            $window = Get-RequiredString -Item $item -Name 'windowSize'
            $history = Get-RequiredString -Item $item -Name 'queryTimeRange'
            if ($frequency -cnotin @('PT5M', 'PT10M', 'PT15M') -or
                $window -cnotin @('PT10M', 'PT15M', 'PT30M', 'PT1H', 'PT2H') -or
                $history -cnotin @('PT10M', 'PT15M', 'PT30M', 'PT1H', 'PT2H', 'P1D', 'P2D') -or
                $item['autoMitigate'] -isnot [bool] -or $item['splitByResourceId'] -isnot [bool]) {
                throw 'A planned alert has invalid timing or recovery settings.'
            }
            $id = "$prefix/Microsoft.Insights/scheduledQueryRules/$name"
            if (-not $plannedIds.Add($id)) {
                Add-PlanFinding -Code 'RepeatedPlannedResource' -Subject $id -Message 'The plan creates the same alert more than once.'
            }
            if ([System.Xml.XmlConvert]::ToTimeSpan($history) -lt [System.Xml.XmlConvert]::ToTimeSpan($window)) {
                Add-PlanFinding -Code 'AlertHistoryTooShort' -Subject $id `
                    -Message 'The configured query history is shorter than the evaluation window.'
            }
            if ([regex]::IsMatch($query, '(?is)\b(?:datatable\s*\([^)]*\)\s*\[\s*\]|dynamic\s*\(\s*\[\s*\]\s*\))')) {
                Add-PlanFinding -Code 'EmptyAlertDataList' -Subject $id `
                    -Message 'An empty literal list may suppress coverage or produce excessive alerts; review every expected scope and baseline.'
            }
            $historySeconds = [decimal] ([System.Xml.XmlConvert]::ToTimeSpan($history).TotalSeconds)
            $lookbacks = [regex]::Matches($query, '(?i)\bago\s*\(\s*(?<amount>\d+(?:\.\d+)?)\s*(?<unit>ms|s|m|h|d)\s*\)')
            $lookbackTooLong = $false
            $lookbackUninterpretable = $false
            foreach ($lookback in $lookbacks) {
                $amount = [decimal] 0
                if (-not [decimal]::TryParse(
                        $lookback.Groups['amount'].Value,
                        [System.Globalization.NumberStyles]::AllowDecimalPoint,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref] $amount
                    )) {
                    $lookbackUninterpretable = $true
                    continue
                }
                $secondsPerUnit = switch ($lookback.Groups['unit'].Value.ToLowerInvariant()) {
                    'ms' { [decimal] 0.001 }
                    's' { [decimal] 1 }
                    'm' { [decimal] 60 }
                    'h' { [decimal] 3600 }
                    'd' { [decimal] 86400 }
                }
                if ($amount -gt ($historySeconds / $secondsPerUnit)) { $lookbackTooLong = $true }
            }
            if ($lookbackTooLong) {
                Add-PlanFinding -Code 'AlertHistoryTooShortForLookback' -Subject $id `
                    -Message 'A literal ago() lookback exceeds the configured query history.'
            }
            if ($lookbackUninterpretable) {
                Add-PlanFinding -Code 'AlertLookbackUninterpretable' -Subject $id `
                    -Message 'A literal ago() lookback could not be interpreted; validate the query history manually.'
            }
            if ($item['autoMitigate']) {
                Add-PlanFinding -Code 'AlertAutomaticRecoveryReview' -Subject $id `
                    -Message 'Prove that missing or stale data cannot make an unresolved condition appear recovered.'
            }
            else {
                Add-PlanFinding -Code 'AlertStatelessNotificationReview' -Subject $id `
                    -Message 'Stateless alerts can notify repeatedly; review notification frequency and ownership.'
            }
            if ($item['splitByResourceId']) {
                Add-PlanFinding -Code 'AlertDimensionReview' -Subject $id `
                    -Message 'Verify that the query returns only approved ResourceId values and review per-series charges.'
            }
            if (@($existingAlerts | Where-Object { $_['id'] -ieq $id }).Count -gt 0) {
                Add-PlanFinding -Code 'ExistingResourceName' -Subject $id -Message 'The proposed alert resource ID already exists and must not be overwritten.'
            }
            if ($actionGroupId -notin @($existingGroups | ForEach-Object { $_['id'] }) -and
                -not $newGroupIds.Contains($actionGroupId)) {
                Add-PlanFinding -Code 'ActionGroupNotDiscovered' -Subject $id -Message 'The referenced Action Group is neither discovered nor included in this stage.'
            }
            if ($actionGroupId -in @($existingGroups | ForEach-Object { $_['id'] })) {
                Add-PlanFinding -Code 'ReferencedActionGroupReview' -Subject $id -Related @($actionGroupId) `
                    -Message 'Confirm the existing Action Group owner, receivers, enabled state and other consumers.'
            }
            if ($existingAlerts.Count -gt 0) {
                Add-PlanFinding -Code 'ExistingAlertIntentReview' -Subject $id -Related @($existingAlerts | ForEach-Object { $_['id'] }) `
                    -Message 'Review all existing alert scopes, criteria and intent before creating another rule.'
            }
            Add-PlanFinding -Code 'AlertScopeAndQueryReview' -Subject $id `
                -Message 'Validate the query, approved server scope, longest history, evaluation window, recovery and notification behaviour.'
        }
    }

    Add-PlanFinding -Code 'CompletePreflightRequired' -Message 'This partial comparison does not certify reuse, current state, safe cutover or equivalence.'
    [pscustomobject]@{
        ParameterSha256 = $ParameterSha256
        Stage = $stage
        OperationCount = $operationCount
        Status = 'ReviewRequired'
        ReadyForWhatIf = $false
        ReadyForDeployment = $false
        Findings = @($findings.ToArray())
    }
}

Export-ModuleMember -Function Get-ArcStagePlanReview
