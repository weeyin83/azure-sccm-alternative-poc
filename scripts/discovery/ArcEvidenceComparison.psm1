#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ArcDiscoveryEvidence.psm1') -ErrorAction Stop

function ConvertTo-ArcCanonicalValue {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        [string[]] $keys = @($Value.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $result[$key] = ConvertTo-ArcCanonicalValue -Value $Value[$key]
        }
        return ,$result
    }
    if ($Value -is [array]) {
        $result = [object[]]::new($Value.Count)
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $result[$index] = ConvertTo-ArcCanonicalValue -Value $Value[$index]
        }
        return ,$result
    }
    return $Value
}

function Get-ArcEvidenceIndex {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)][string] $Section,
        [Parameter(Mandatory)][string] $IdProperty
    )

    if ($Report[$Section] -isnot [array]) {
        throw 'A discovery comparison section is missing or invalid.'
    }
    $index = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Report[$Section]) {
        if ($item -isnot [System.Collections.IDictionary] -or
            $item[$IdProperty] -isnot [string] -or [string]::IsNullOrWhiteSpace($item[$IdProperty])) {
            throw 'A discovery comparison item has a missing or invalid ID.'
        }
        $canonical = ConvertTo-ArcCanonicalValue -Value $item
        if ($Section -eq 'Servers') {
            foreach ($key in @('Extensions', 'Associations')) {
                $canonical[$key]['Items'] = @($canonical[$key]['Items'] | Sort-Object -Property { $_['Id'] })
            }
        }
        try {
            $json = ConvertTo-Json -InputObject $canonical -Depth 100 -Compress -WarningAction Stop
        }
        catch {
            throw 'Discovery evidence could not be compared without truncation.'
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
        if (-not $index.TryAdd([string] $item[$IdProperty], $hash)) {
            throw 'A discovery comparison section contains duplicate IDs.'
        }
    }
    return ,$index
}

function Get-ArcEvidenceComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Baseline,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Current,
        [Parameter(Mandatory)][pscustomobject] $BaselineScope,
        [Parameter(Mandatory)][pscustomobject] $CurrentScope,
        [Parameter(Mandatory)][string] $BaselineSha256
    )

    Assert-ArcDiscoveryCoverage -Report $Baseline -Scope $BaselineScope -AllServers
    Assert-ArcDiscoveryCoverage -Report $Current -Scope $CurrentScope -AllServers
    $baselineSubscriptions = @($Baseline['SubscriptionScope'] | Sort-Object)
    $currentSubscriptions = @($Current['SubscriptionScope'] | Sort-Object)
    if (@(Compare-Object -ReferenceObject $baselineSubscriptions -DifferenceObject $currentSubscriptions).Count -gt 0) {
        throw 'The discovery snapshots must enumerate the same subscription scope.'
    }

    try {
        $baselineGenerated = [datetimeoffset] $Baseline['GeneratedAtUtc']
        $currentGenerated = [datetimeoffset] $Current['GeneratedAtUtc']
        if ([string]::IsNullOrWhiteSpace([string] $Current['CollectionStartedAtUtc'])) {
            throw 'Missing collection start.'
        }
        $currentStarted = [datetimeoffset] $Current['CollectionStartedAtUtc']
    }
    catch {
        throw 'The current discovery snapshot must record a valid collection start time.'
    }
    $now = [datetimeoffset]::UtcNow
    if ($currentStarted -lt $now.AddMinutes(-15) -or $currentStarted -gt $now.AddMinutes(5) -or
        $currentStarted -gt $currentGenerated -or $currentGenerated -le $baselineGenerated) {
        throw 'The current discovery collection must start within 15 minutes and finish after the baseline.'
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($section in @(
            @{ Name = 'Servers'; Id = 'Id' }
            @{ Name = 'Resources'; Id = 'id' }
            @{ Name = 'Workspaces'; Id = 'Id' }
            @{ Name = 'PolicyAssignments'; Id = 'id' }
            @{ Name = 'PolicyDefinitions'; Id = 'id' }
        )) {
        $before = Get-ArcEvidenceIndex -Report $Baseline -Section $section.Name -IdProperty $section.Id
        $after = Get-ArcEvidenceIndex -Report $Current -Section $section.Name -IdProperty $section.Id
        $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $before.Keys) { $null = $ids.Add($id) }
        foreach ($id in $after.Keys) { $null = $ids.Add($id) }
        foreach ($id in @($ids | Sort-Object)) {
            $change = if (-not $before.ContainsKey($id)) { 'Added' }
            elseif (-not $after.ContainsKey($id)) { 'Removed' }
            elseif ($before[$id] -cne $after[$id]) { 'Modified' }
            else { $null }
            if ($change) {
                $changes.Add([ordered]@{ Section = $section.Name; ResourceId = $id; Change = $change })
            }
        }
    }

    [ordered]@{
        Status = if ($changes.Count -gt 0) { 'DriftDetected' } else { 'NoDriftObserved' }
        BaselineReportGeneratedAtUtc = $Baseline['GeneratedAtUtc']
        BaselineReportSha256 = $BaselineSha256
        CurrentCollectionStartedAtUtc = $Current['CollectionStartedAtUtc']
        Changes = @($changes.ToArray())
        Limitations = @(
            'Only captured discovery evidence is compared; resource visibility and Resource Graph freshness are not guaranteed.'
            'AMA public settings, guest-installed agents, effective policy exemptions and remediation are not fully captured.'
            'Object keys and server extension/association item order are normalised; other array reordering may be reported as drift.'
            'No drift observed is not evidence of equivalent collection, safe alerts or approval for what-if or deployment.'
        )
    }
}

Export-ModuleMember -Function Get-ArcEvidenceComparison
