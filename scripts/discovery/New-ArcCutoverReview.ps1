#Requires -Version 7.4
<#
.SYNOPSIS
Creates a private, review-only inventory for an Arc monitoring cutover.
.DESCRIPTION
Reads an existing, recent discovery report. It makes no Azure calls or changes.
The output preserves existing resources by default and is not a deployment
preflight, approval, or evidence that equivalent monitoring is absent.
.PARAMETER BaselineReportPath
Optionally compares a reviewed baseline with the current report. The current
collection must have started within 15 minutes. A comparison does not authorise
what-if or deployment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ReportPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $WorkspaceResourceId,
    [Parameter(Mandatory)][ValidateCount(1, 10)][ValidateNotNullOrEmpty()][string[]] $ServerResourceId,
    [ValidateNotNullOrEmpty()][string] $ParametersPath,
    [ValidateNotNullOrEmpty()][string] $BaselineReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ArcDiscoveryEvidence.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ArcPrivateEvidence.psm1') -ErrorAction Stop

Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $ReportPath
if ($PSBoundParameters.ContainsKey('ParametersPath')) {
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $ParametersPath
}
if ($PSBoundParameters.ContainsKey('BaselineReportPath')) {
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $BaselineReportPath
}
$sourceHash = Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report'
$report = Read-ArcDiscoveryReport -ReportPath $ReportPath -MaxAgeMinutes 60
$scope = Resolve-ArcDiscoveryScope -Report $report -WorkspaceResourceId $WorkspaceResourceId -ServerResourceId $ServerResourceId
if ((Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report') -ne $sourceHash) {
    throw 'The discovery report changed while being read. Refresh discovery and try again.'
}

Assert-ArcDiscoveryCoverage -Report $report -Scope $scope
$subscriptions = @($report['SubscriptionScope'])
$resources = @($report['Resources'])
$rules = @($resources | Where-Object { $_['type'] -ieq 'Microsoft.Insights/dataCollectionRules' })

$serverItems = @(foreach ($server in $scope.Servers) {
    $id = [string] $server['Id']
    $extensions = @(foreach ($extension in $server['Extensions']['Items']) {
        if ($extension -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string] $extension['Id']) -or
            [string]::IsNullOrWhiteSpace([string] $extension['Category'])) {
            throw 'A selected server has malformed extension evidence.'
        }
        [ordered]@{
            ResourceId = $extension['Id']
            Name = $extension['Name']
            Category = $extension['Category']
            Publisher = $extension['Publisher']
            Type = $extension['Type']
            Version = $extension['Version']
            InstanceVersion = $extension['InstanceVersion']
            ProvisioningState = $extension['ProvisioningState']
            ProposedAction = 'Preserve'
            Owner = $null
            OtherConsumers = 'Unconfirmed'
        }
    })
    $associations = @(foreach ($association in $server['Associations']['Items']) {
        if ($association -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string] $association['id']) -or
            $association['properties'] -isnot [System.Collections.IDictionary]) {
            throw 'A selected server has malformed association evidence.'
        }
        $ruleId = [string] $association['properties']['dataCollectionRuleId']
        if ($ruleId -and @($rules | Where-Object { $_['id'] -ieq $ruleId }).Count -ne 1) {
            throw 'An associated DCR is missing or duplicated in the discovery report.'
        }
        [ordered]@{
            ResourceId = $association['id']
            DataCollectionRuleId = if ($ruleId) { $ruleId } else { $null }
            ExistingProperties = $association['properties']
            ProposedAction = 'Preserve'
            Owner = $null
            OtherConsumers = 'Unconfirmed'
            ReplacementResourceId = $null
            Rollback = 'If an approved change is made, restore the recorded association and properties.'
        }
    })
    [ordered]@{
        ResourceId = $id
        ConnectionStatus = $server['ConnectionStatus']
        AMA = $server['AMA']
        ChangeTracking = $server['ChangeTracking']
        Extensions = $extensions
        Associations = $associations
        GuestAgentState = 'Unverified'
        ProposedAction = 'Preserve; review any missing or unhealthy extension separately.'
    }
})

$ruleItems = @(foreach ($rule in $rules) {
    if ($rule['properties'] -isnot [System.Collections.IDictionary]) {
        throw 'A discovered DCR has no readable properties.'
    }
    $ruleId = [string] $rule['id']
    $knownAssociations = @(foreach ($server in $serverItems) {
        foreach ($association in $server.Associations) {
            if ($association.DataCollectionRuleId -ieq $ruleId) {
                [ordered]@{ ServerResourceId = $server.ResourceId; AssociationResourceId = $association.ResourceId }
            }
        }
    })
    [ordered]@{
        ResourceId = $ruleId
        Location = $rule['location']
        Kind = $rule['kind']
        ExistingProperties = $rule['properties']
        SelectedServerAssociations = $knownAssociations
        ProposedAction = 'Preserve; assess suitability and overlap before proposing a change.'
        Owner = $null
        OtherConsumers = 'Unconfirmed'
        ReplacementResourceId = $null
        Rollback = 'Do not delete shared rules; record exact associations before any approved cutover.'
    }
})

$alertItems = @(foreach ($alert in @($resources | Where-Object {
            $_['type'] -imatch '^Microsoft\.Insights/(metricAlerts|scheduledQueryRules|activityLogAlerts)$'
        })) {
    if ($alert['properties'] -isnot [System.Collections.IDictionary]) {
        throw 'A discovered alert has no readable properties.'
    }
    [ordered]@{
        ResourceId = $alert['id']
        Type = $alert['type']
        Relationship = $alert['DiscoveryRelationship']
        ExistingProperties = $alert['properties']
        ProposedAction = 'Preserve; inspect scope, criteria, actions and equivalent intent.'
        Owner = $null
        ReplacementResourceId = $null
    }
})
$groupItems = @(foreach ($group in @($resources | Where-Object { $_['type'] -ieq 'Microsoft.Insights/actionGroups' })) {
    if ($group['properties'] -isnot [System.Collections.IDictionary]) {
        throw 'A discovered Action Group has no readable properties.'
    }
    $properties = $group['properties']
    $receivers = @(foreach ($key in @($properties.Keys | Where-Object { $_ -imatch 'receivers$' } | Sort-Object)) {
        $values = $properties[$key]
        if ($values -isnot [array]) { throw 'A discovered Action Group has malformed receiver evidence.' }
        [ordered]@{ Type = $key; Count = $values.Count }
    })
    [ordered]@{
        ResourceId = $group['id']
        Enabled = $properties['enabled']
        ReceiverCounts = $receivers
        ProposedAction = 'Preserve; inspect full receiver settings in the source report before reuse.'
        Owner = $null
        OtherConsumers = 'Unconfirmed'
    }
})
$policyItems = @(foreach ($assignment in @($report['PolicyAssignments'])) {
    if ($assignment -isnot [System.Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace([string] $assignment['id'])) {
        throw 'The discovery report contains malformed policy assignment evidence.'
    }
    [ordered]@{
        ResourceId = $assignment['id']
        Scope = $assignment['scope']
        DefinitionId = $assignment['policyDefinitionId']
        EnforcementMode = $assignment['enforcementMode']
        ProposedAction = 'Preserve; review effective assignments, exemptions and remediation ownership.'
    }
})

$planReview = $null
if ($PSBoundParameters.ContainsKey('ParametersPath')) {
    try { $parameterLength = (Get-Item -LiteralPath $ParametersPath -ErrorAction Stop).Length }
    catch { throw 'The private stage parameter file could not be read.' }
    if ($parameterLength -gt 2MB) {
        throw 'The private stage parameter file exceeds the 2 MiB limit.'
    }
    $parameterHash = Get-ArcPrivateFileHash -LiteralPath $ParametersPath -Label 'stage parameters'
    try {
        $parameterJson = Get-Content -LiteralPath $ParametersPath -Raw -ErrorAction Stop
    }
    catch {
        throw 'The private stage parameter file could not be read.'
    }
    $parameterDocument = ConvertFrom-ArcPrivateJson -Json $parameterJson -Label 'stage parameters'
    if ($parameterDocument -isnot [System.Collections.IDictionary]) {
        throw 'The stage parameter file must be a JSON object.'
    }
    if ((Get-ArcPrivateFileHash -LiteralPath $ParametersPath -Label 'stage parameters') -ne $parameterHash) {
        throw 'The stage parameter file changed while being read.'
    }
    Import-Module (Join-Path $PSScriptRoot 'ArcStagePlanReview.psm1') -ErrorAction Stop
    $planReview = Get-ArcStagePlanReview -Report $report -Scope $scope `
        -ParameterDocument $parameterDocument -ParameterSha256 $parameterHash
}

$evidenceComparison = $null
if ($PSBoundParameters.ContainsKey('BaselineReportPath')) {
    $baselineHash = Get-ArcPrivateFileHash -LiteralPath $BaselineReportPath -Label 'baseline report'
    $baseline = Read-ArcDiscoveryReport -ReportPath $BaselineReportPath -AllowStale
    $baselineScope = Resolve-ArcDiscoveryScope -Report $baseline -WorkspaceResourceId $WorkspaceResourceId `
        -ServerResourceId $ServerResourceId
    if ((Get-ArcPrivateFileHash -LiteralPath $BaselineReportPath -Label 'baseline report') -ne $baselineHash -or
        (Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report') -ne $sourceHash) {
        throw 'Discovery evidence changed while being read. Refresh discovery and try again.'
    }
    Import-Module (Join-Path $PSScriptRoot 'ArcEvidenceComparison.psm1') -ErrorAction Stop
    $evidenceComparison = Get-ArcEvidenceComparison -Baseline $baseline -Current $report `
        -BaselineScope $baselineScope -CurrentScope $scope -BaselineSha256 $baselineHash
}

Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $ReportPath
if ((Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report') -ne $sourceHash) {
    throw 'The discovery report changed while the review was prepared.'
}
if ($PSBoundParameters.ContainsKey('ParametersPath')) {
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $ParametersPath
    if ((Get-ArcPrivateFileHash -LiteralPath $ParametersPath -Label 'stage parameters') -ne $parameterHash) {
        throw 'The stage parameter file changed while the review was prepared.'
    }
}
if ($PSBoundParameters.ContainsKey('BaselineReportPath')) {
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $PSScriptRoot -LiteralPath $BaselineReportPath
    if ((Get-ArcPrivateFileHash -LiteralPath $BaselineReportPath -Label 'baseline report') -ne $baselineHash) {
        throw 'The baseline report changed while the review was prepared.'
    }
}

$manifest = [ordered]@{
    SchemaVersion = '1.0'
    GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    SourceReportGeneratedAtUtc = $report['GeneratedAtUtc']
    SourceReportSha256 = $sourceHash
    Status = 'ReviewRequired'
    ReadyForWhatIf = $false
    ReadyForDeployment = $false
    SubscriptionScope = $subscriptions
    Workspace = [ordered]@{
        ResourceId = $WorkspaceResourceId
        Location = $scope.Workspace['Location']
        RetentionInDays = $scope.Workspace['RetentionInDays']
        PricingTier = $scope.Workspace['PricingTier']
        Solutions = $scope.Workspace['Solutions']
        ProposedAction = 'Reuse unchanged, subject to ownership, access and data-handling review.'
        Owner = $null
        OtherConsumers = 'Unconfirmed'
        Rollback = 'Never delete or change the shared workspace as part of PoC rollback.'
    }
    Servers = $serverItems
    DataCollectionRules = $ruleItems
    Alerts = $alertItems
    ActionGroups = $groupItems
    PolicyAssignments = $policyItems
    PlanAssessment = $planReview
    EvidenceComparison = $evidenceComparison
    RequiredReview = @(
        'Confirm ownership, consumers, access, retention, licensing, data handling and attributable cost.'
        'Compare exact proposed DCR selectors, streams, transformations and destinations with existing associations.'
        'Resolve existing alert and Action Group intent before adding any equivalent configuration.'
        'Review effective policy assignments, exemptions, remediation and guest-installed agent state.'
        'Confirm Change Tracking DCR schema and frequencies against current documentation and validate on an approved test server.'
        'Create reviewed private stage parameters, run a fail-closed plan preflight and refresh discovery immediately before what-if.'
        'Review the exact what-if, itemised cutover and rollback; obtain explicit deployment and guest-change approval.'
    )
}

$directoryName = 'review-{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
$directory = New-ArcPrivateEvidenceDirectory -DiscoveryDirectory $PSScriptRoot -DirectoryName $directoryName
$manifestPath = Join-Path $directory 'cutover-review.json'
$manifestCreated = $false
try {
    $null = New-ArcPrivateEvidenceFile -Directory $directory -FileName 'cutover-review.json'
    $manifestCreated = $true
    $json = ConvertTo-Json -InputObject $manifest -Depth 100
    [System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
}
catch {
    if ($manifestCreated -and (Test-Path -LiteralPath $manifestPath)) {
        Remove-Item -LiteralPath $manifestPath -ErrorAction Stop
    }
    if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $directory -ErrorAction Stop
    }
    throw 'The private review file could not be written. No review file was retained.'
}
[pscustomobject]@{
    ManifestPath = $manifestPath
    Status = 'ReviewRequired'
    ReadyForWhatIf = $false
    ReadyForDeployment = $false
    PlanStage = if ($null -ne $planReview) { $planReview.Stage } else { $null }
    PlanFindingCount = if ($null -ne $planReview) { $planReview.Findings.Count } else { 0 }
    EvidenceComparisonStatus = if ($null -ne $evidenceComparison) { $evidenceComparison.Status } else { $null }
    EvidenceChangeCount = if ($null -ne $evidenceComparison) { $evidenceComparison.Changes.Count } else { 0 }
}
