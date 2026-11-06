#Requires -Version 7.4
<#
.SYNOPSIS
Creates private, review-only parameters for the draft alerting stage.
.DESCRIPTION
Reads a recent discovery report and an owner-only configuration file. It
performs no Azure calls, creates no Azure resources and never authorises
what-if or deployment.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ReportPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ConfigurationPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $WorkspaceResourceId,
    [Parameter(Mandatory)][ValidateCount(1, 10)][ValidateNotNullOrEmpty()][string[]] $ServerResourceId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$discoveryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../discovery'))
Import-Module (Join-Path $discoveryDirectory 'ArcPrivateEvidence.psm1') -ErrorAction Stop
Import-Module (Join-Path $discoveryDirectory 'ArcDiscoveryEvidence.psm1') -ErrorAction Stop
Import-Module (Join-Path $discoveryDirectory 'ArcStagePlanReview.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ArcAlertParameters.psm1') -ErrorAction Stop

Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $discoveryDirectory -LiteralPath $ReportPath
Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $discoveryDirectory -LiteralPath $ConfigurationPath
$configurationItem = Get-Item -LiteralPath $ConfigurationPath -ErrorAction Stop
if ($configurationItem.Length -gt 2MB) { throw 'The private alert configuration exceeds the 2 MiB limit.' }
$sourceHash = Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report'
$configurationHash = Get-ArcPrivateFileHash -LiteralPath $ConfigurationPath -Label 'alert configuration'
$report = Read-ArcDiscoveryReport -ReportPath $ReportPath -MaxAgeMinutes 60
$scope = Resolve-ArcDiscoveryScope -Report $report -WorkspaceResourceId $WorkspaceResourceId `
    -ServerResourceId $ServerResourceId
Assert-ArcDiscoveryCoverage -Report $report -Scope $scope

try {
    $configurationJson = Get-Content -LiteralPath $ConfigurationPath -Raw -ErrorAction Stop
}
catch { throw 'The private alert configuration could not be read as valid JSON.' }
$configuration = ConvertFrom-ArcPrivateJson -Json $configurationJson -Label 'alert configuration'
if ($configuration -isnot [System.Collections.IDictionary]) {
    throw 'The private alert configuration must be a JSON object.'
}

$parameters = Get-ArcAlertParameterDocument -Configuration $configuration -Report $report -Scope $scope
$parameterJson = ConvertTo-Json -InputObject $parameters -Depth 100
$encoding = [System.Text.UTF8Encoding]::new($false)
$parameterHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        $encoding.GetBytes($parameterJson)
    ))
$assessment = Get-ArcStagePlanReview -Report $report -Scope $scope `
    -ParameterDocument $parameters -ParameterSha256 $parameterHash
$blockingCodes = @(
    'ExistingResourceName', 'RepeatedPlannedResource', 'ActionGroupNotDiscovered',
    'EmptyAlertDataList', 'AlertHistoryTooShort', 'AlertHistoryTooShortForLookback',
    'AlertLookbackUninterpretable'
)
if (@($assessment.Findings | Where-Object { $_.Code -in $blockingCodes }).Count -gt 0) {
    throw 'The generated alert plan conflicts with known resource names or alert constraints. No parameter file was written.'
}

Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $discoveryDirectory -LiteralPath $ReportPath
Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $discoveryDirectory -LiteralPath $ConfigurationPath
if ((Get-ArcPrivateFileHash -LiteralPath $ReportPath -Label 'discovery report') -ne $sourceHash -or
    (Get-ArcPrivateFileHash -LiteralPath $ConfigurationPath -Label 'alert configuration') -ne $configurationHash) {
    throw 'Private input changed while being read. Refresh the evidence and try again.'
}
$review = [ordered]@{
    SchemaVersion = '1.0'
    GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    SourceReportSha256 = $sourceHash
    ConfigurationSha256 = $configurationHash
    ParameterSha256 = $parameterHash
    Status = 'ReviewRequired'
    ReadyForWhatIf = $false
    ReadyForDeployment = $false
    PlanAssessment = $assessment
    RequiredReview = @(
        'Confirm the alert scope, thresholds, sample cadence and expected-online maintenance process.'
        'Review existing alert intent, Action Group owner and receivers, cost and notification behaviour.'
        'Validate KQL, actual query history and stateful or stateless recovery on an approved test server.'
        'Complete fail-closed reuse and cutover preflight, refresh discovery and obtain separate deployment approval.'
    )
}
$reviewJson = ConvertTo-Json -InputObject $review -Depth 100

$directoryName = 'alert-parameters-{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
$directory = New-ArcPrivateEvidenceDirectory -DiscoveryDirectory $discoveryDirectory -DirectoryName $directoryName
$parameterPath = Join-Path $directory 'alerting.parameters.json'
$reviewPath = Join-Path $directory 'alert-parameter-review.json'
$createdFiles = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($entry in @(
            @{ Name = 'alerting.parameters.json'; Path = $parameterPath; Content = $parameterJson }
            @{ Name = 'alert-parameter-review.json'; Path = $reviewPath; Content = $reviewJson }
        )) {
        $null = New-ArcPrivateEvidenceFile -Directory $directory -FileName $entry.Name
        $createdFiles.Add($entry.Path)
        [System.IO.File]::WriteAllText($entry.Path, $entry.Content, $encoding)
    }
}
catch {
    foreach ($file in $createdFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -ErrorAction Stop }
    }
    if (@(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $directory -ErrorAction Stop
    }
    throw 'The private alert parameter files could not be written. No files were retained.'
}

[pscustomobject]@{
    ParameterPath = $parameterPath
    ReviewPath = $reviewPath
    Status = 'ReviewRequired'
    ReadyForWhatIf = $false
    ReadyForDeployment = $false
    AlertCount = @($parameters.parameters.alerts.value).Count
    FindingCount = @($assessment.Findings).Count
}
