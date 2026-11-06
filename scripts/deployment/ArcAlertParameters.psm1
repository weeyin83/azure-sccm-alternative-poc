#Requires -Version 7.4
Set-StrictMode -Version Latest

function Get-ArcAlertParameterDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][pscustomobject] $Scope
    )

    function Assert-ObjectShape {
        param([object] $Value, [string[]] $Fields, [string] $Label)
        if ($Value -isnot [System.Collections.IDictionary] -or $Value.Count -ne $Fields.Count -or
            @($Fields | Where-Object { -not $Value.Contains($_) }).Count -gt 0) {
            throw "The $Label has missing or unrecognised fields."
        }
    }

    function Get-Text {
        param(
            [System.Collections.IDictionary] $Value,
            [string] $Field,
            [int] $MaxLength = 1024,
            [switch] $AllowEmpty
        )
        $text = $Value[$Field]
        if ($text -isnot [string] -or $text.Length -gt $MaxLength -or
            (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($text)) -or
            $text -match '[\x00-\x1f\x7f]') {
            throw "The $Field field is missing or invalid."
        }
        try { $null = [System.Text.UTF8Encoding]::new($false, $true).GetByteCount($text) }
        catch { throw "The $Field field contains invalid text." }
        return $text
    }

    function Get-Integer {
        param([System.Collections.IDictionary] $Value, [string] $Field, [long] $Min, [long] $Max)
        $number = $Value[$Field]
        if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt $Min -or $number -gt $Max) {
            throw "The $Field field is missing or invalid."
        }
        return [long] $number
    }

    function Get-Number {
        param([System.Collections.IDictionary] $Value, [string] $Field, [double] $Min, [double] $Max)
        $number = $Value[$Field]
        if ($number -isnot [int] -and $number -isnot [long] -and $number -isnot [double] -and
            $number -isnot [decimal]) {
            throw "The $Field threshold is missing or invalid."
        }
        $number = [double] $number
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Min -or $number -gt $Max) {
            throw "The $Field threshold is missing or invalid."
        }
        $literal = $number.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($literal -notmatch '[.eE]') { $literal += '.0' }
        return $literal
    }

    function ConvertTo-KqlText {
        param([string] $Value)
        return '@"' + $Value.Replace('"', '""') + '"'
    }

    function Get-SubstitutedTemplate {
        param([string] $Text, [string] $Marker, [string] $Replacement)
        $first = $Text.IndexOf($Marker, [StringComparison]::Ordinal)
        if ($first -lt 0 -or $Text.IndexOf($Marker, $first + $Marker.Length, [StringComparison]::Ordinal) -ge 0) {
            throw 'An alert template has an unexpected shape. Refresh and review the templates.'
        }
        return $Text.Substring(0, $first) + $Replacement + $Text.Substring($first + $Marker.Length)
    }

    function Get-ApprovedServer {
        param([string] $Id)
        $matchingServers = @($Scope.ServerResourceIds | Where-Object { $_ -ieq $Id })
        if ($matchingServers.Count -ne 1) {
            throw 'An alert dataset refers to a server outside the explicitly selected scope.'
        }
        return [string] $matchingServers[0]
    }

    function Get-RenderedTable {
        param(
            [string] $Name,
            [System.Collections.IDictionary] $Columns,
            [object] $Rows,
            [int] $MaximumRows
        )
        if ($Rows -isnot [array] -or $Rows.Count -eq 0 -or $Rows.Count -gt $MaximumRows) {
            throw "The $Name dataset must contain between 1 and $MaximumRows rows."
        }
        $fields = @($Columns.Keys)
        $signatures = @($fields | ForEach-Object {
                $type = switch ($Columns[$_]) {
                    'EventId' { 'int' }
                    'OnlineSince' { 'datetime' }
                    default { 'string' }
                }
                "${_}:$type"
            })
        $literals = [System.Collections.Generic.List[string]]::new()
        $rowKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $serverIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $Rows) {
            Assert-ObjectShape -Value $row -Fields $fields -Label "$Name dataset row"
            $values = [System.Collections.Generic.List[string]]::new()
            $identity = [System.Collections.Generic.List[string]]::new()
            foreach ($field in $fields) {
                switch ($Columns[$field]) {
                    'Server' {
                        $server = Get-ApprovedServer -Id (Get-Text -Value $row -Field $field -MaxLength 2048)
                        $values.Add((ConvertTo-KqlText -Value $server))
                        $identity.Add($server)
                        $null = $serverIds.Add($server)
                    }
                    'EventLog' {
                        $text = Get-Text -Value $row -Field $field
                        if ($text -notin @('System', 'Application')) {
                            throw 'Critical event datasets must use the System or Application log.'
                        }
                        $values.Add((ConvertTo-KqlText -Value $text))
                        $identity.Add($text)
                    }
                    'Hive' {
                        $text = Get-Text -Value $row -Field $field
                        if ($text -notin @('HKLM', 'HKEY_LOCAL_MACHINE')) {
                            throw 'Registry datasets must use the HKLM hive.'
                        }
                        $values.Add((ConvertTo-KqlText -Value $text))
                        $identity.Add($text)
                    }
                    'EventId' {
                        $number = Get-Integer -Value $row -Field $field -Min 0 -Max 65535
                        $values.Add($number.ToString([System.Globalization.CultureInfo]::InvariantCulture))
                        $identity.Add($number.ToString([System.Globalization.CultureInfo]::InvariantCulture))
                    }
                    'OnlineSince' {
                        $text = Get-Text -Value $row -Field $field -MaxLength 64
                        $onlineSince = [datetimeoffset]::MinValue
                        if ($text -notmatch '(?i)(Z|[+-]\d{2}:\d{2})$' -or
                            -not [datetimeoffset]::TryParse(
                                $text, [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::None, [ref] $onlineSince
                            ) -or $onlineSince -gt [datetimeoffset]::UtcNow) {
                            throw 'The expected-online start must be a non-future date and time with a UTC offset.'
                        }
                        $utc = $onlineSince.UtcDateTime.ToString(
                            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [System.Globalization.CultureInfo]::InvariantCulture
                        )
                        $values.Add("datetime($utc)")
                        $identity.Add($utc)
                    }
                    'OptionalText' {
                        $text = Get-Text -Value $row -Field $field -AllowEmpty
                        $values.Add((ConvertTo-KqlText -Value $text))
                        $identity.Add($text)
                    }
                    default {
                        $text = Get-Text -Value $row -Field $field
                        $values.Add((ConvertTo-KqlText -Value $text))
                        $identity.Add($text)
                    }
                }
            }
            $key = if ('OnlineSince' -in $Columns.Values) { $identity[0] } else { $identity -join [char] 31 }
            if (-not $rowKeys.Add($key)) { throw "The $Name dataset contains duplicate rows." }
            $literals.Add(($values -join ', '))
        }
        return [pscustomobject]@{
            Marker = 'let {0} = datatable({1})[];' -f $Name, ($signatures -join ', ')
            Statement = 'let {0} = datatable({1})[{2}];' -f $Name, ($signatures -join ', '), ($literals -join ', ')
            ServerIds = @($serverIds)
        }
    }

    $definitions = @{
        cpu = @{
            Path = 'alerts/high-cpu.kql'; History = 'PT15M'
            Tables = [ordered]@{ ExpectedServers = [ordered]@{ ResourceId = 'Server' } }
            Thresholds = @(@{ Name = 'ThresholdPercent'; Default = '90.0'; Min = 0; Max = 100 })
        }
        memory = @{
            Path = 'alerts/low-memory.kql'; History = 'PT15M'
            Tables = [ordered]@{ ExpectedServers = [ordered]@{ ResourceId = 'Server' } }
            Thresholds = @(@{ Name = 'ThresholdMBytes'; Default = '500.0'; Min = 0; Max = 1000000000 })
        }
        disk = @{
            Path = 'alerts/low-disk-space.kql'; History = 'PT15M'
            Tables = [ordered]@{ ExpectedVolumes = [ordered]@{ ResourceId = 'Server'; Volume = 'Text' } }
            Thresholds = @(
                @{ Name = 'ThresholdPercent'; Default = '10.0'; Min = 0; Max = 100 }
                @{ Name = 'ThresholdMBytes'; Default = '5120.0'; Min = 0; Max = 1000000000 }
            )
        }
        events = @{
            Path = 'alerts/critical-windows-events.kql'; History = 'PT10M'
            Tables = [ordered]@{
                ExpectedEvents = [ordered]@{ ResourceId = 'Server'; EventLog = 'EventLog'; Source = 'Text'; EventID = 'EventId' }
            }
            Thresholds = @()
        }
        service = @{
            Path = 'services-expected-running.kql'; History = 'P2D'
            Tables = [ordered]@{ ExpectedServices = [ordered]@{ ResourceId = 'Server'; SvcName = 'Text' } }
            Thresholds = @()
        }
        software = @{
            Path = 'alerts/unexpected-software.kql'; History = 'PT1H'
            Tables = [ordered]@{
                ExpectedServers = [ordered]@{ ResourceId = 'Server' }
                AllowedSoftware = [ordered]@{ ResourceId = 'Server'; SoftwareName = 'Text'; Publisher = 'Text' }
            }
            Thresholds = @()
        }
        configuration = @{
            Path = 'alerts/configuration-changes.kql'; History = 'PT2H'
            Tables = [ordered]@{
                RegistryItems = [ordered]@{
                    ResourceId = 'Server'; Hive = 'Hive'; RegistryKey = 'Text'; ValueName = 'OptionalText'
                }
                FileItems = [ordered]@{ ResourceId = 'Server'; FileSystemPath = 'Text' }
            }
            Thresholds = @()
        }
        heartbeat = @{
            Path = 'heartbeat-missing.kql'; History = 'P1D'
            Tables = [ordered]@{
                ExpectedServers = [ordered]@{ ResourceId = 'Server'; ExpectedOnlineSince = 'OnlineSince' }
            }
            Thresholds = @()
        }
    }

    Assert-ObjectShape -Value $Configuration -Fields @('schemaVersion', 'scope', 'location', 'tags', 'actionGroup', 'alerts') `
        -Label 'alert configuration'
    if ($Configuration['schemaVersion'] -cne '1.0') { throw 'Alert configuration schema version 1.0 is required.' }
    $planScope = $Configuration['scope']
    Assert-ObjectShape -Value $planScope -Fields @('subscriptionId', 'resourceGroupName') -Label 'alert resource scope'
    $subscription = Get-Text -Value $planScope -Field 'subscriptionId' -MaxLength 36
    $resourceGroup = Get-Text -Value $planScope -Field 'resourceGroupName' -MaxLength 90
    $subscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($subscription, [ref] $subscriptionId) -or
        $subscription -notin $Report['SubscriptionScope'] -or $resourceGroup.Contains('/')) {
        throw 'The alert resource scope is invalid or was not enumerated in discovery.'
    }
    $location = Get-Text -Value $Configuration -Field 'location' -MaxLength 64
    if ($location -notmatch '^[a-zA-Z0-9]+$') { throw 'The alert location must be an Azure region name.' }
    $tags = $Configuration['tags']
    if ($tags -isnot [System.Collections.IDictionary] -or $tags.Count -gt 50 -or @($tags.Keys | Where-Object {
                $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_.Length -gt 512 -or
                $tags[$_] -isnot [string] -or $tags[$_].Length -gt 256
            }).Count -gt 0) {
        throw 'Alert tags must be an object with at most 50 string values.'
    }
    $group = $Configuration['actionGroup']
    if ($group -isnot [System.Collections.IDictionary]) { throw 'The actionGroup configuration is required.' }
    $mode = Get-Text -Value $group -Field 'mode' -MaxLength 16
    $newGroups = @()
    if ($mode -ceq 'existing') {
        Assert-ObjectShape -Value $group -Fields @('mode', 'resourceId') -Label 'existing Action Group'
        $groupId = Get-Text -Value $group -Field 'resourceId' -MaxLength 2048
        $groupSubscription = [guid]::Empty
        if ($groupId -notmatch '(?i)^/subscriptions/([0-9a-f-]{36})/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/]+$' -or
            -not [guid]::TryParse($Matches[1], [ref] $groupSubscription) -or
            $Matches[1] -notin $Report['SubscriptionScope']) {
            throw 'The selected Action Group must have a valid resource ID in an enumerated subscription.'
        }
        $matchingGroup = @($Report['Resources'] | Where-Object {
                $_['type'] -ieq 'Microsoft.Insights/actionGroups' -and $_['id'] -ieq $groupId
            })
        if ($matchingGroup.Count -ne 1) { throw 'The selected Action Group must be uniquely present in discovery.' }
    }
    elseif ($mode -ceq 'new') {
        Assert-ObjectShape -Value $group -Fields @('mode', 'name', 'groupShortName', 'emailReceivers') `
            -Label 'new Action Group'
        $groupName = Get-Text -Value $group -Field 'name' -MaxLength 64
        $shortName = Get-Text -Value $group -Field 'groupShortName' -MaxLength 12
        if ($groupName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'The new Action Group name is invalid.' }
        $receivers = $group['emailReceivers']
        if ($receivers -isnot [array] -or $receivers.Count -eq 0 -or $receivers.Count -gt 10) {
            throw 'A new Action Group requires 1 to 10 approved email receivers.'
        }
        $uniqueReceivers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($receiver in $receivers) {
            Assert-ObjectShape -Value $receiver -Fields @('emailAddress') -Label 'email receiver'
            $address = Get-Text -Value $receiver -Field 'emailAddress' -MaxLength 254
            try { $parsedAddress = [System.Net.Mail.MailAddress]::new($address) }
            catch { throw 'An Action Group email address is invalid.' }
            if ($parsedAddress.Address -cne $address -or -not $uniqueReceivers.Add($address)) {
                throw 'An Action Group email address is invalid or duplicated.'
            }
        }
        $groupId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Insights/actionGroups/$groupName"
        $newGroups = @(@{
                scope = $planScope; name = $groupName; groupShortName = $shortName; emailReceivers = $receivers
            })
    }
    else { throw 'Action Group mode must be existing or new.' }

    $requested = $Configuration['alerts']
    if ($requested -isnot [array] -or $requested.Count -eq 0 -or $requested.Count -gt 8) {
        throw 'The alert configuration must contain 1 to 8 alerts.'
    }
    $kinds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $alerts = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $requested) {
        Assert-ObjectShape -Value $item -Fields @(
            'kind', 'name', 'displayName', 'description', 'evaluationFrequency', 'windowSize', 'queryTimeRange',
            'autoMitigate', 'splitByResourceId', 'severity', 'datasets', 'thresholds'
        ) -Label 'alert'
        $kind = Get-Text -Value $item -Field 'kind' -MaxLength 32
        if (-not $definitions.ContainsKey($kind) -or -not $kinds.Add($kind)) {
            throw 'Alert kinds must be supported and unique.'
        }
        $definition = $definitions[$kind]
        $name = Get-Text -Value $item -Field 'name' -MaxLength 64
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or -not $names.Add($name)) {
            throw 'Alert names must be valid and unique.'
        }
        $displayName = Get-Text -Value $item -Field 'displayName' -MaxLength 256
        $description = Get-Text -Value $item -Field 'description' -MaxLength 1024
        $frequency = Get-Text -Value $item -Field 'evaluationFrequency' -MaxLength 8
        $window = Get-Text -Value $item -Field 'windowSize' -MaxLength 8
        $history = Get-Text -Value $item -Field 'queryTimeRange' -MaxLength 8
        if ($frequency -cnotin @('PT5M', 'PT10M', 'PT15M') -or
            $window -cnotin @('PT10M', 'PT15M', 'PT30M', 'PT1H', 'PT2H') -or
            $history -cnotin @('PT10M', 'PT15M', 'PT30M', 'PT1H', 'PT2H', 'P1D', 'P2D') -or
            $item['autoMitigate'] -isnot [bool] -or $item['splitByResourceId'] -isnot [bool]) {
            throw 'An alert has invalid timing or recovery settings.'
        }
        $frequencySpan = [System.Xml.XmlConvert]::ToTimeSpan($frequency)
        $windowSpan = [System.Xml.XmlConvert]::ToTimeSpan($window)
        $historySpan = [System.Xml.XmlConvert]::ToTimeSpan($history)
        if ($frequencySpan -gt $windowSpan -or $historySpan -lt $windowSpan -or
            $historySpan -lt [System.Xml.XmlConvert]::ToTimeSpan($definition.History) -or
            ($kind -notin @('service', 'heartbeat') -and
                $windowSpan -lt [System.Xml.XmlConvert]::ToTimeSpan($definition.History))) {
            throw 'An alert query history or evaluation window is too short.'
        }
        $severity = Get-Integer -Value $item -Field 'severity' -Min 0 -Max 4
        $datasets = $item['datasets']
        Assert-ObjectShape -Value $datasets -Fields @($definition.Tables.Keys) -Label 'alert datasets'
        $thresholds = $item['thresholds']
        Assert-ObjectShape -Value $thresholds -Fields @($definition.Thresholds | ForEach-Object { $_.Name }) `
            -Label 'alert thresholds'
        $queryPath = Join-Path (Join-Path $PSScriptRoot '../../queries') $definition.Path
        try { $query = Get-Content -LiteralPath $queryPath -Raw -ErrorAction Stop }
        catch { throw 'A required alert query template could not be read.' }
        $renderedTables = @{}
        foreach ($tableName in $definition.Tables.Keys) {
            $table = Get-RenderedTable -Name $tableName -Columns $definition.Tables[$tableName] `
                -Rows $datasets[$tableName] -MaximumRows 100
            $query = Get-SubstitutedTemplate -Text $query -Marker $table.Marker -Replacement $table.Statement
            $renderedTables[$tableName] = $table
        }
        if ($kind -eq 'software') {
            $expected = $renderedTables['ExpectedServers'].ServerIds
            $allowed = $renderedTables['AllowedSoftware'].ServerIds
            if (@($expected | Where-Object { $_ -notin $allowed }).Count -gt 0 -or
                @($allowed | Where-Object { $_ -notin $expected }).Count -gt 0) {
                throw 'Each expected software server needs an explicit allowlist, and allowlists cannot target other servers.'
            }
        }
        foreach ($threshold in $definition.Thresholds) {
            $number = Get-Number -Value $thresholds -Field $threshold.Name -Min $threshold.Min -Max $threshold.Max
            $query = Get-SubstitutedTemplate -Text $query -Marker ("let {0} = {1};" -f $threshold.Name, $threshold.Default) `
                -Replacement ("let {0} = {1};" -f $threshold.Name, $number)
        }
        if ([System.Text.Encoding]::UTF8.GetByteCount($query) -gt 32768) {
            throw 'An alert query exceeds the conservative 32 KiB review limit.'
        }
        $alerts.Add(@{
                scope = $planScope; name = $name; displayName = $displayName; location = $location
                description = $description; actionGroupResourceId = $groupId; query = $query
                evaluationFrequency = $frequency; windowSize = $window; queryTimeRange = $history
                autoMitigate = $item['autoMitigate']; splitByResourceId = $item['splitByResourceId']
                severity = $severity
            })
    }

    return [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            stage = @{ value = 'alerting' }
            workspaceResourceId = @{ value = $Scope.Workspace['Id'] }
            tags = @{ value = $tags }
            actionGroups = @{ value = $newGroups }
            alerts = @{ value = @($alerts.ToArray()) }
        }
    }
}

Export-ModuleMember -Function Get-ArcAlertParameterDocument
