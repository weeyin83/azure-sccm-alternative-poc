#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$collectorPath = Join-Path $PSScriptRoot '../../scripts/discovery/Invoke-ArcDiscovery.ps1'
$privateEvidenceModule = Join-Path $PSScriptRoot '../../scripts/discovery/ArcPrivateEvidence.psm1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('arc-discovery-tests-' + [guid]::NewGuid().ToString('N'))
$discoveryDirectory = Join-Path $testRoot 'scripts/discovery'
$null = New-Item -ItemType Directory -Path $discoveryDirectory -Force
& git init --quiet $testRoot
if ($LASTEXITCODE -ne 0) { throw 'Unable to create the isolated test repository.' }
'/scripts/discovery/output/' | Set-Content -LiteralPath (Join-Path $testRoot '.gitignore')
Copy-Item -LiteralPath $collectorPath -Destination (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1')
Copy-Item -LiteralPath $privateEvidenceModule -Destination (Join-Path $discoveryDirectory 'ArcPrivateEvidence.psm1')
$script:subscription = [guid]::NewGuid().ToString()
$script:prefix = "/subscriptions/$script:subscription/resourceGroups/test/providers/"
$script:machineId = $script:prefix + 'Microsoft.HybridCompute/machines/server-one'
$script:dcrId = $script:prefix + 'Microsoft.Insights/dataCollectionRules/monitoring'
$script:workspaceId = $script:prefix + 'Microsoft.OperationalInsights/workspaces/shared'
$script:actionId = $script:prefix + 'Microsoft.Insights/actionGroups/notify'
$script:definitionId = '/providers/Microsoft.Authorization/policySetDefinitions/test-monitoring'
$script:scenario = 'Complete'
$script:calls = [System.Collections.Generic.List[object]]::new()

function Assert-Discovery {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-TestArgument {
    param([string[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0) { return $null }
    $Arguments[$index + 1]
}

function Get-TestResponse {
    param([string[]] $Arguments)

    $command = ($Arguments | Select-Object -First 2) -join ' '
    switch ($command) {
        'extension list' {
            if ($script:scenario -eq 'MissingDependency') { return ,@() }
            return ,@(@{ name = 'resource-graph' })
        }
        'cloud show' { return @{ endpoints = @{ resourceManager = 'https://management.azure.com/' } } }
        'account show' { return @{ id = $script:subscription } }
        'policy assignment' {
            return ,@(@{ id = 'test-assignment'; policyDefinitionId = $script:definitionId })
        }
        'policy set-definition' {
            Assert-Discovery ($Arguments[2] -eq 'show') 'Only policy reads are permitted'
            Assert-Discovery ((Get-TestArgument -Arguments $Arguments -Name '--subscription') -eq $script:subscription) 'Global initiatives retain subscription context'
            return @{ id = $script:definitionId; policyDefinitions = @(@{ policyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/test-member' }) }
        }
        'policy definition' {
            Assert-Discovery ($Arguments[2] -eq 'show') 'Only policy reads are permitted'
            return @{ id = '/providers/Microsoft.Authorization/policyDefinitions/test-member'; displayName = 'Deploy Azure Monitor Agent' }
        }
        'graph query' {
            if ($script:scenario -eq 'Empty') { return @{ data = @(); count = 0; total_records = 0 } }
            $machine = @{
                id = $script:machineId; name = 'server-one'; resourceGroup = 'test'
                location = 'uksouth'; subscriptionId = $script:subscription
                properties = @{
                    osName = 'Windows'; osVersion = 'test'; agentVersion = 'test'
                    status = 'Connected'; lastStatusChange = '2026-01-01T00:00:00Z'
                }
            }
            if (Get-TestArgument -Arguments $Arguments -Name '--skip-token') {
                if ($script:scenario -eq 'RepeatedGraphToken') {
                    return @{ data = @($machine); count = 1; total_records = 2; skip_token = 'page-two' }
                }
                $machine.id += '-two'
                $machine.name = 'server-two'
                return @{ data = @($machine); count = 1; total_records = 2 }
            }
            if ($script:scenario -eq 'Truncated') {
                return @{ data = @($machine); count = 1; total_records = 2 }
            }
            return @{ data = @($machine); count = 1; total_records = 2; skip_token = 'page-two' }
        }
        'resource list' {
            $type = Get-TestArgument -Arguments $Arguments -Name '--resource-type'
            if ($type -eq 'Microsoft.Insights/dataCollectionRules' -and $script:scenario -eq 'DeniedList') {
                throw 'Mock access denied'
            }
            switch ($type) {
                'Microsoft.Insights/dataCollectionRules' { return ,@(@{ id = $script:dcrId }) }
                'Microsoft.OperationalInsights/workspaces' { return ,@(@{ id = $script:workspaceId }) }
                'Microsoft.Insights/scheduledQueryRules' { return ,@(@{ id = $script:prefix + 'Microsoft.Insights/scheduledQueryRules/cpu' }) }
                default { return ,@() }
            }
        }
        'resource show' {
            $id = Get-TestArgument -Arguments $Arguments -Name '--ids'
            Assert-Discovery ((Get-TestArgument -Arguments $Arguments -Name '--subscription') -eq $script:subscription) 'All resource reads use a real subscription context, including global policy definitions'
            switch ($id) {
                $script:definitionId {
                    return @{ id = $id; properties = @{ displayName = 'Deploy Azure Monitor Agent' } }
                }
                $script:dcrId {
                    return @{
                        id = $id; type = 'Microsoft.Insights/dataCollectionRules'
                        properties = @{
                            dataSources = @{ extensions = @(@{ extensionName = 'ChangeTracking' }) }
                            destinations = @{ logAnalytics = @(@{ workspaceResourceId = $script:workspaceId }) }
                        }
                    }
                }
                $script:workspaceId {
                    return @{
                        id = $id; name = 'shared'; type = 'Microsoft.OperationalInsights/workspaces'; location = 'uksouth'
                        properties = @{ retentionInDays = 30; sku = @{ name = 'PerGB2018' } }
                    }
                }
                $script:actionId { return @{ id = $id; type = 'Microsoft.Insights/actionGroups' } }
                default {
                    return @{
                        id = $id; type = 'Microsoft.Insights/scheduledQueryRules'
                        properties = @{ scopes = @($script:workspaceId); actions = @{ actionGroups = @($script:actionId) } }
                    }
                }
            }
        }
        'rest --method' {
            Assert-Discovery ($Arguments[2] -eq 'get') 'Only ARM GET is permitted'
            $url = Get-TestArgument -Arguments $Arguments -Name '--url'
            if ($url -match '/extensions\?') {
                if ($script:scenario -eq 'DeniedExtensions') { throw 'Mock extensions access denied' }
                return @{
                    value = @(@{
                        id = $script:machineId + '/extensions/renamed'; name = 'renamed'
                        properties = @{
                            publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorWindowsAgent'
                            typeHandlerVersion = 'test'; provisioningState = 'Succeeded'
                        }
                    })
                }
            }
            if ($url -match '/dataCollectionRuleAssociations\?') {
                if ($script:scenario -eq 'ExternalNextLink') { return @{ value = @(); nextLink = 'https://untrusted.invalid/page' } }
                return @{
                    value = @(
                        @{ properties = @{ dataCollectionEndpointId = $script:prefix + 'Microsoft.Insights/dataCollectionEndpoints/private' } }
                        @{ properties = @{ dataCollectionRuleId = $script:dcrId } }
                    )
                }
            }
            if ($url -match '/linkedServices\?') { return @{ value = @() } }
            throw "Unexpected ARM request: $url"
        }
        default { throw "Unexpected CLI command: $command" }
    }
}

function az {
    $arguments = @($args)
    $script:calls.Add($arguments)
    try {
        $response = Get-TestResponse -Arguments $arguments
        $global:LASTEXITCODE = 0
        ConvertTo-Json -InputObject $response -Depth 30 -Compress
    }
    catch {
        $global:LASTEXITCODE = 1
        [Console]::Error.WriteLine($_.Exception.Message)
    }
}

try {
    foreach ($case in @('Complete', 'Empty', 'DeniedExtensions', 'DeniedList', 'Truncated', 'RepeatedGraphToken', 'ExternalNextLink', 'MissingDependency')) {
        $script:scenario = $case
        $failed = $false
        $failureMessage = ''
        try {
            & { . (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1') -SubscriptionId $script:subscription } | Out-Null
        }
        catch { $failed = $true; $failureMessage = $_.Exception.Message }
        $run = Get-ChildItem -LiteralPath (Join-Path $discoveryDirectory 'output') -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
        Assert-Discovery ($null -ne $run) "$case creates a private evidence directory: $failureMessage"
        $report = Get-Content -LiteralPath (Join-Path $run.FullName 'report.json') -Raw | ConvertFrom-Json
        $csv = @(Import-Csv -LiteralPath (Join-Path $run.FullName 'servers.csv'))
        Assert-Discovery (Test-Path -LiteralPath (Join-Path $run.FullName 'findings.md')) "$case writes findings"
        if (-not $IsWindows) {
            $directoryMode = [System.IO.UnixFileMode]::UserRead -bor
                [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
            $fileMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            Assert-Discovery ([System.IO.File]::GetUnixFileMode((Join-Path $discoveryDirectory 'output')) -eq $directoryMode) 'Evidence root is owner-only'
            Assert-Discovery ([System.IO.File]::GetUnixFileMode($run.FullName) -eq $directoryMode) 'Run directory is owner-only'
            foreach ($name in @('report.json', 'servers.csv', 'findings.md')) {
                Assert-Discovery ([System.IO.File]::GetUnixFileMode((Join-Path $run.FullName $name)) -eq $fileMode) "$name is owner-only"
            }
        }
        if ($case -in @('Complete', 'Empty')) {
            Assert-Discovery (-not $failed) "$case completes without error: $($report.Checks.Error -join '; '); $($report.Checks.ScriptStackTrace -join '; ')"
            Assert-Discovery ($report.Status -eq 'CollectedPendingReview') "$case status"
        }
        else {
            Assert-Discovery $failed "$case raises a terminating error"
            Assert-Discovery ($report.Status -eq 'Incomplete') "$case is not success-shaped"
            Assert-Discovery (@($report.Checks | Where-Object Status -EQ 'Failed').Count -gt 0) "$case records failure"
        }
        if ($case -eq 'Complete') {
            $started = [datetimeoffset] $report.CollectionStartedAtUtc
            $finished = [datetimeoffset] $report.GeneratedAtUtc
            Assert-Discovery ($started -le $finished) 'Collection start is recorded before report generation'
            Assert-Discovery ($report.Servers.Count -eq 2 -and $csv.Count -eq 2) 'All graph pages are retained in JSON and CSV'
            Assert-Discovery ($report.Servers[0].AMA -eq 'Provisioned') 'Agent matched by publisher and type, not name'
            Assert-Discovery ($report.Servers[0].LegacyMMA -eq 'NotObserved') 'Missing agent is distinct from failed read'
            Assert-Discovery ($report.Servers[0].ChangeTrackingDcrCandidateIds.Count -eq 1) 'Endpoint-only associations do not break DCR evaluation'
            Assert-Discovery ($report.PolicyDefinitions.Count -eq 2) 'Inherited initiative and member definitions read'
            Assert-Discovery ($report.Workspaces[0].RetentionInDays -eq 30) 'Workspace configuration retained'
            Assert-Discovery (@($report.Resources | Where-Object type -EQ 'Microsoft.Insights/actionGroups').Count -eq 1) 'Referenced Action Group read'
            Assert-Discovery (@($report.Resources | Where-Object type -EQ 'Microsoft.Insights/scheduledQueryRules')[0].DiscoveryRelationship -eq 'ResourceIdReference') 'Alert target relationship retained'
        }
        if ($case -eq 'Empty') { Assert-Discovery ($csv.Count -eq 0) 'Empty CSV retains a valid header' }
        if ($case -eq 'DeniedExtensions') {
            Assert-Discovery ($report.Servers[0].AMA -eq 'Unknown') 'Failed extension read is unknown, not absent'
        }
        Write-Output "PASS: $case"
    }
    Assert-Discovery (@($script:calls | Where-Object { ($_[0..1] -join ' ') -notin @('extension list', 'cloud show', 'account show', 'policy assignment', 'policy definition', 'policy set-definition', 'graph query', 'resource list', 'resource show', 'rest --method') }).Count -eq 0) 'No mutating CLI commands'
    $script:scenario = 'DeniedExtensions'
    $script:privacyFailureObserved = $false
    $records = @(& {
            try {
                . (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1') -SubscriptionId $script:subscription
            }
            catch {
                if ($_.Exception.Message -notmatch '^Discovery incomplete:') { throw }
                $script:privacyFailureObserved = $true
            }
        } 3>&1)
    $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert-Discovery ($script:privacyFailureObserved -and $warnings.Count -gt 0) 'A failed discovery emits explicit warnings'
    Assert-Discovery (@($warnings | Where-Object { $_.Message.Contains($script:subscription) -or $_.Message.Contains($script:machineId) }).Count -eq 0) 'Warnings omit subscription and server IDs'
    Write-Output 'PASS: Discovery warnings omit private identifiers'
    if (-not $IsWindows) {
        $outputRoot = Join-Path $discoveryDirectory 'output'
        $privateMode = [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
        $insecureMode = $privateMode -bor [System.IO.UnixFileMode]::GroupRead
        $callCount = $script:calls.Count
        try {
            [System.IO.File]::SetUnixFileMode($outputRoot, $insecureMode)
            $failed = $false
            try {
                & { . (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1') -SubscriptionId $script:subscription } | Out-Null
            }
            catch { $failed = $_.Exception.Message -match 'owner-only mode 700' }
            Assert-Discovery $failed 'An insecure evidence root is rejected'
            Assert-Discovery ($script:calls.Count -eq $callCount) 'Insecure output is rejected before Azure reads'
        }
        finally {
            [System.IO.File]::SetUnixFileMode($outputRoot, $privateMode)
        }
        Write-Output 'PASS: Insecure evidence root rejected'

        $heldOutput = Join-Path $discoveryDirectory 'test-held-output'
        $linkTarget = Join-Path $testRoot 'test-link-target'
        $null = New-Item -ItemType Directory -Path $linkTarget
        Move-Item -LiteralPath $outputRoot -Destination $heldOutput
        try {
            $null = New-Item -ItemType SymbolicLink -Path $outputRoot -Target $linkTarget
            $callCount = $script:calls.Count
            $failed = $false
            $failureMessage = ''
            try {
                & { . (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1') -SubscriptionId $script:subscription } | Out-Null
            }
            catch { $failureMessage = $_.Exception.Message; $failed = $failureMessage -match 'not a link' }
            Assert-Discovery $failed "A symbolic-link evidence root is rejected: $failureMessage"
            Assert-Discovery ($script:calls.Count -eq $callCount) 'A linked output is rejected before Azure reads'
        }
        finally {
            if (Test-Path -LiteralPath $outputRoot) { Remove-Item -LiteralPath $outputRoot -Force }
            Move-Item -LiteralPath $heldOutput -Destination $outputRoot
        }
        Write-Output 'PASS: Linked evidence root rejected'
    }
    '!/scripts/discovery/output/' | Set-Content -LiteralPath (Join-Path $testRoot '.gitignore')
    $callCount = $script:calls.Count
    $failed = $false
    try {
        & { . (Join-Path $discoveryDirectory 'Invoke-ArcDiscovery.ps1') -SubscriptionId $script:subscription } | Out-Null
    }
    catch { $failed = $_.Exception.Message -match 'not confirmed as Git-ignored' }
    Assert-Discovery $failed 'Unignored evidence is rejected'
    Assert-Discovery ($script:calls.Count -eq $callCount) 'Unignored output is rejected before Azure reads'
    Write-Output 'PASS: Unignored evidence rejected'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
