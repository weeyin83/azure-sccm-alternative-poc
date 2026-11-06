#Requires -Version 7.4
Set-StrictMode -Version Latest

function Assert-ArcDemoInput {
    param(
        [Parameter(Mandatory)][string] $ComputerName,
        [Parameter(Mandatory)][string] $ServiceName,
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $RegistryKey
    )

    if ($ComputerName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$') {
        throw 'The test computer must be one explicit local NetBIOS name.'
    }
    if ($ServiceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._$ -]{0,254}$' -or
        $ServiceName.EndsWith(' ')) {
        throw 'The disposable service must be specified by one literal service name.'
    }
    if ($FilePath.Length -gt 240 -or
        $FilePath -notmatch '^[A-Za-z]:\\(?:[^\\/:*?"<>|\x00-\x1f]+\\)*ArcSccmPoc-[A-Za-z0-9_-]+\.txt$') {
        throw 'The test file must be an absolute local path named ArcSccmPoc-<name>.txt.'
    }
    $parts = @($FilePath.Substring(3) -split '\\')
    foreach ($part in $parts) {
        if ($part -in @('.', '..') -or $part.EndsWith(' ') -or $part.EndsWith('.')) {
            throw 'The test file path contains an unsafe path component.'
        }
    }
    if ($parts.Count -lt 2 -or $parts[-2] -notmatch '^ArcSccmPoc-[A-Za-z0-9_-]+$') {
        throw 'The test file must be inside an existing, dedicated ArcSccmPoc-<name> directory.'
    }
    if ($RegistryKey -notmatch '^HKLM:\\SOFTWARE\\ArcSccmPoc-[A-Za-z0-9_-]{1,80}$') {
        throw 'The test key must be a direct HKLM:\SOFTWARE\ArcSccmPoc-<name> child.'
    }
}

function Get-ArcDemoTextHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-ArcDemoFileText {
    param([string] $RunId, [ValidateSet('baseline', 'changed')][string] $Version)
    return "Arc SCCM PoC ${Version}: $RunId`r`n"
}

function Get-ArcDemoRegistryValue {
    param([string] $RunId, [ValidateSet('baseline', 'changed')][string] $Version)
    return "ArcSccmPoc-${Version}:$RunId"
}

function Assert-ArcDemoSnapshot {
    param(
        [AllowNull()][object] $Actual,
        [AllowNull()][object] $Expected,
        [ValidateSet('file', 'registry')][string] $Kind
    )

    if ($Actual -isnot [System.Collections.IDictionary] -or
        $Expected -isnot [System.Collections.IDictionary]) {
        throw "The $Kind is missing or its recorded snapshot is invalid."
    }
    $fields = if ($Kind -eq 'file') {
        @('Hash', 'Length', 'FileId', 'CreationTicks', 'WriteTicks', 'Attributes', 'Acl')
    }
    else {
        @('ValueCount', 'SubKeyCount', 'ValueKind', 'Value', 'Acl')
    }
    foreach ($field in $fields) {
        if (-not $Actual.Contains($field) -or -not $Expected.Contains($field) -or
            [string] $Actual[$field] -cne [string] $Expected[$field]) {
            throw "The $Kind has changed since the recorded snapshot; automatic modification is refused."
        }
    }
}

function Assert-ArcDemoOwnedSnapshot {
    param(
        [AllowNull()][object] $Snapshot,
        [ValidateSet('file', 'registry')][string] $Kind,
        [string] $RunId,
        [ValidateSet('baseline', 'changed')][string] $Version
    )

    if ($Snapshot -isnot [System.Collections.IDictionary]) {
        throw "The $Kind snapshot is missing."
    }
    $requiredFields = if ($Kind -eq 'file') {
        @('Hash', 'Length', 'FileId', 'CreationTicks', 'WriteTicks', 'Attributes', 'Acl')
    }
    else {
        @('ValueCount', 'SubKeyCount', 'ValueKind', 'Value', 'Acl')
    }
    foreach ($field in $requiredFields) {
        if (-not $Snapshot.Contains($field) -or $Snapshot[$field] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($Snapshot[$field])) {
            throw "The $Kind snapshot has invalid or missing $field metadata."
        }
    }
    if ($Kind -eq 'file') {
        $text = Get-ArcDemoFileText -RunId $RunId -Version $Version
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $creationTicks = [long] 0
        $writeTicks = [long] 0
        $attributes = [int] 0
        if ($Snapshot['FileId'] -cnotmatch '^[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}$' -or
            -not [long]::TryParse($Snapshot['CreationTicks'], [ref] $creationTicks) -or $creationTicks -lt 0 -or
            -not [long]::TryParse($Snapshot['WriteTicks'], [ref] $writeTicks) -or $writeTicks -lt 0 -or
            -not [int]::TryParse($Snapshot['Attributes'], [ref] $attributes) -or $attributes -lt 0) {
            throw 'The file snapshot has invalid filesystem metadata.'
        }
        if ($Snapshot['Hash'] -cne (Get-ArcDemoTextHash -Text $text) -or
            $Snapshot['Length'] -cne [string] $bytes.Length) {
            throw 'The file does not have the expected synthetic contents.'
        }
    }
    else {
        if ($Snapshot['ValueCount'] -cne '1' -or $Snapshot['SubKeyCount'] -cne '0' -or
            $Snapshot['ValueKind'] -cne 'String' -or
            $Snapshot['Value'] -cne (Get-ArcDemoRegistryValue -RunId $RunId -Version $Version)) {
            throw 'The registry key contains unexpected values or subkeys.'
        }
    }
}

function Get-ArcDemoServiceIdentity {
    param([AllowNull()][object] $Service)

    if ($Service -isnot [System.Collections.IDictionary]) {
        throw 'The designated service could not be inspected.'
    }
    foreach ($field in @('Name', 'State', 'CanStop', 'PathName', 'StartName', 'StartMode', 'Dependencies', 'Dependents')) {
        if (-not $Service.Contains($field) -or $null -eq $Service[$field]) {
            throw "The designated service is missing its $field observation."
        }
    }
    foreach ($field in @('Name', 'PathName', 'StartName', 'StartMode')) {
        if ($Service[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($Service[$field])) {
            throw "The designated service has an invalid $field observation."
        }
    }
    $dependencies = [System.Collections.Generic.List[string]]::new()
    $dependents = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Service['Dependencies'])) {
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('Name') -or
            -not $entry.Contains('State') -or [string]::IsNullOrWhiteSpace([string] $entry['Name'])) {
            throw 'A service dependency could not be inspected.'
        }
        $dependencies.Add([string] $entry['Name'])
    }
    foreach ($entry in @($Service['Dependents'])) {
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('Name') -or
            -not $entry.Contains('State') -or [string]::IsNullOrWhiteSpace([string] $entry['Name'])) {
            throw 'A dependent service could not be inspected.'
        }
        $dependents.Add([string] $entry['Name'])
    }
    return @{
        Name = [string] $Service['Name']
        PathName = [string] $Service['PathName']
        StartName = [string] $Service['StartName']
        StartMode = [string] $Service['StartMode']
        Dependencies = @($dependencies | Sort-Object)
        Dependents = @($dependents | Sort-Object)
    }
}

function Assert-ArcDemoService {
    param(
        [object] $Service,
        [string] $Name,
        [AllowNull()][object] $ExpectedIdentity,
        [switch] $RequireRunning,
        [switch] $RequireSafeStop,
        [switch] $RequireRunningDependencies
    )

    $identity = Get-ArcDemoServiceIdentity -Service $Service
    if ($identity.Name -ine $Name) {
        throw 'The service observation does not match the designated service.'
    }
    if ($null -ne $ExpectedIdentity) {
        if ($ExpectedIdentity -isnot [System.Collections.IDictionary]) {
            throw 'The recorded service identity is invalid.'
        }
        foreach ($field in @('Name', 'PathName', 'StartName', 'StartMode', 'Dependencies', 'Dependents')) {
            if (-not $ExpectedIdentity.Contains($field)) {
                throw 'The recorded service identity is incomplete.'
            }
            if ($field -in @('Dependencies', 'Dependents')) {
                $currentList = @($identity[$field] | Sort-Object) -join "`n"
                $expectedList = @($ExpectedIdentity[$field] | Sort-Object) -join "`n"
                if ($currentList -cne $expectedList) {
                    throw 'The service dependencies or dependents have changed; automatic service control is refused.'
                }
            }
            elseif ([string] $identity[$field] -cne [string] $ExpectedIdentity[$field]) {
                throw 'The service identity or configuration has changed; automatic service control is refused.'
            }
        }
    }
    if ($RequireRunning -and $Service['State'] -cne 'Running') {
        throw 'The designated disposable service must already be running.'
    }
    if ($RequireSafeStop) {
        if ($Service['StartMode'] -cnotin @('Auto', 'Manual')) {
            throw 'The designated service is disabled or has an unsupported start mode.'
        }
        if ($Service['CanStop'] -isnot [bool] -or -not $Service['CanStop']) {
            throw 'The designated service does not currently accept a stop.'
        }
        foreach ($entry in @($Service['Dependents'])) {
            if ($entry['State'] -cne 'Stopped') {
                throw 'The designated service has an active or indeterminate dependent.'
            }
        }
    }
    if ($RequireRunningDependencies) {
        foreach ($entry in @($Service['Dependencies'])) {
            if ($entry['State'] -cne 'Running') {
                throw 'A service dependency is not running; automatic service control is refused.'
            }
        }
    }
    return $identity
}

function Assert-ArcDemoJournal {
    param([object] $State, [string] $ComputerName)

    if ($State -isnot [System.Collections.IDictionary]) {
        throw 'The private demo recovery state is not a JSON object.'
    }
    $stateFields = @('SchemaVersion', 'RunId', 'ComputerName', 'ServiceName', 'FilePath', 'RegistryKey',
        'ServiceIdentity', 'FileSnapshot', 'RegistrySnapshot', 'Stage', 'Steps')
    foreach ($field in $stateFields) {
        if (@($State.Keys) -cnotcontains $field) { throw "The private demo recovery state is missing $field." }
    }
    if (@($State.Keys | Where-Object { $_ -cnotin $stateFields }).Count -gt 0) {
        throw 'The private demo recovery state contains unexpected fields.'
    }
    $runId = [guid]::Empty
    if ($State['SchemaVersion'] -cne '1.0' -or
        -not [guid]::TryParseExact([string] $State['RunId'], 'N', [ref] $runId) -or
        $State['ComputerName'] -ine $ComputerName) {
        throw 'The private demo recovery state has an invalid version, run ID or target computer.'
    }
    Assert-ArcDemoInput -ComputerName $State['ComputerName'] -ServiceName $State['ServiceName'] `
        -FilePath $State['FilePath'] -RegistryKey $State['RegistryKey']
    if ($State['ServiceIdentity'] -isnot [System.Collections.IDictionary] -or
        $State['Steps'] -isnot [System.Collections.IDictionary] -or
        $State['Stage'] -cnotin @('Preparing', 'Prepared', 'Changing', 'Changed', 'Reverting', 'RevertIncomplete', 'Reverted')) {
        throw 'The private demo recovery state has an invalid shape or stage.'
    }
    $identityFields = @('Name', 'PathName', 'StartName', 'StartMode', 'Dependencies', 'Dependents')
    $identity = $State['ServiceIdentity']
    if (@($identity.Keys | Where-Object { $_ -cnotin $identityFields }).Count -gt 0) {
        throw 'The private demo recovery state contains unexpected service identity fields.'
    }
    foreach ($field in $identityFields) {
        if (@($identity.Keys) -cnotcontains $field) {
            throw 'The recorded service identity is incomplete.'
        }
    }
    foreach ($field in @('Name', 'PathName', 'StartName', 'StartMode')) {
        if ($identity[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($identity[$field])) {
            throw 'The recorded service identity is invalid.'
        }
    }
    if ($identity['Name'] -ine $State['ServiceName'] -or $identity['StartMode'] -cnotin @('Auto', 'Manual')) {
        throw 'The recorded service identity does not describe the designated restartable service.'
    }
    foreach ($field in @('Dependencies', 'Dependents')) {
        if ($identity[$field] -isnot [array]) { throw 'The recorded service relationship list is invalid.' }
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $identity[$field]) {
            if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or -not $names.Add($name)) {
                throw 'The recorded service relationship list is invalid or duplicated.'
            }
        }
    }
    $steps = $State['Steps']
    $stepNames = @('FileCreate', 'RegistryCreate', 'FileChange', 'RegistryChange', 'ServiceStop',
        'Event', 'Cpu', 'ServiceRestore', 'FileRemove', 'RegistryRemove')
    if (@($steps.Keys | Where-Object { $_ -cnotin $stepNames }).Count -gt 0) {
        throw 'The private demo recovery state contains unexpected operation statuses.'
    }
    foreach ($step in $stepNames) {
        $statuses = if ($step -in @('Event', 'Cpu')) {
            @('NotStarted', 'NotRequested', 'Intent', 'Complete')
        }
        else { @('NotStarted', 'Intent', 'Complete') }
        if (@($steps.Keys) -cnotcontains $step -or $steps[$step] -cnotin $statuses) {
            throw "The private demo recovery state has an invalid $step status."
        }
    }
    if (($steps['RegistryCreate'] -cne 'NotStarted' -and $steps['FileCreate'] -cne 'Complete') -or
        ($steps['FileChange'] -cne 'NotStarted' -and
            ($steps['FileCreate'] -cne 'Complete' -or $steps['RegistryCreate'] -cne 'Complete')) -or
        ($steps['RegistryChange'] -cne 'NotStarted' -and $steps['FileChange'] -cne 'Complete') -or
        ($steps['ServiceStop'] -cne 'NotStarted' -and
            ($steps['FileChange'] -cne 'Complete' -or $steps['RegistryChange'] -cne 'Complete')) -or
        (($steps['Event'] -cne 'NotStarted' -or $steps['Cpu'] -cne 'NotStarted') -and
            $steps['ServiceStop'] -cne 'Complete') -or
        ($steps['Cpu'] -cne 'NotStarted' -and $steps['Event'] -ceq 'NotStarted')) {
        throw 'The private demo recovery state has inconsistent operation ordering.'
    }
    foreach ($item in @(
            @{ Create = 'FileCreate'; Change = 'FileChange'; Snapshot = 'FileSnapshot'; Kind = 'file' }
            @{ Create = 'RegistryCreate'; Change = 'RegistryChange'; Snapshot = 'RegistrySnapshot'; Kind = 'registry' }
        )) {
        if ($steps[$item.Create] -ceq 'Complete') {
            $version = if ($steps[$item.Change] -ceq 'Complete') { 'changed' } else { 'baseline' }
            Assert-ArcDemoOwnedSnapshot -Snapshot $State[$item.Snapshot] -Kind $item.Kind `
                -RunId $State['RunId'] -Version $version
        }
        elseif ($null -ne $State[$item.Snapshot]) {
            throw 'The private demo recovery state contains an unexpected item snapshot.'
        }
    }
    $restoreSteps = @('ServiceRestore', 'FileRemove', 'RegistryRemove')
    if ($State['Stage'] -cin @('Preparing', 'Prepared', 'Changing', 'Changed') -and
        @($restoreSteps | Where-Object { $steps[$_] -cne 'NotStarted' }).Count -gt 0) {
        throw 'The private demo recovery state has unexpected restore operations.'
    }
    if ($State['Stage'] -ceq 'Preparing' -and
        @('FileChange', 'RegistryChange', 'ServiceStop', 'Event', 'Cpu' |
            Where-Object { $steps[$_] -cne 'NotStarted' }).Count -gt 0) {
        throw 'The preparation state contains later operations.'
    }
    if ($State['Stage'] -ceq 'Prepared' -and
        ($steps['FileCreate'] -cne 'Complete' -or $steps['RegistryCreate'] -cne 'Complete' -or
            @('FileChange', 'RegistryChange', 'ServiceStop', 'Event', 'Cpu' |
                Where-Object { $steps[$_] -cne 'NotStarted' }).Count -gt 0)) {
        throw 'The prepared state is incomplete or already changed.'
    }
    if ($State['Stage'] -ceq 'Changed' -and
        ($steps['FileChange'] -cne 'Complete' -or $steps['RegistryChange'] -cne 'Complete' -or
            $steps['ServiceStop'] -cne 'Complete' -or $steps['Event'] -cnotin @('Complete', 'NotRequested') -or
            $steps['Cpu'] -cnotin @('Complete', 'NotRequested'))) {
        throw 'The changed state is incomplete.'
    }
    if ($State['Stage'] -ceq 'Reverted' -and
        @($restoreSteps | Where-Object { $steps[$_] -cne 'Complete' }).Count -gt 0) {
        throw 'The reverted state is incomplete.'
    }
}

function Save-ArcDemoStep {
    param([System.Collections.IDictionary] $Adapter, [System.Collections.IDictionary] $Context,
        [System.Collections.IDictionary] $State, [string] $Step, [string] $Status)
    $State['Steps'][$Step] = $Status
    & $Adapter['SaveJournal'] $Context $State
}

function Restore-ArcDemoService {
    param([System.Collections.IDictionary] $Adapter, [System.Collections.IDictionary] $Context,
        [System.Collections.IDictionary] $State)

    $steps = $State['Steps']
    if ($steps['ServiceRestore'] -ceq 'Complete') { return }
    if ($steps['ServiceStop'] -ceq 'NotStarted') {
        Save-ArcDemoStep $Adapter $Context $State 'ServiceRestore' 'Complete'
        return
    }
    $service = & $Adapter['GetService'] $State['ServiceName']
    $null = Assert-ArcDemoService -Service $service -Name $State['ServiceName'] `
        -ExpectedIdentity $State['ServiceIdentity']
    if ($service['State'] -ceq 'Running') {
        Save-ArcDemoStep $Adapter $Context $State 'ServiceRestore' 'Complete'
        return
    }
    if ($steps['ServiceStop'] -cne 'Complete' -or $steps['ServiceRestore'] -ceq 'Intent') {
        throw 'The service stop or restart has an uncertain outcome. Review and restore it manually.'
    }
    if ($service['State'] -cne 'Stopped') {
        throw 'The service is in a transitional or unknown state; automatic restart is refused.'
    }
    $null = Assert-ArcDemoService -Service $service -Name $State['ServiceName'] `
        -ExpectedIdentity $State['ServiceIdentity'] -RequireRunningDependencies
    Save-ArcDemoStep $Adapter $Context $State 'ServiceRestore' 'Intent'
    & $Adapter['StartService'] $State['ServiceName'] $State['ServiceIdentity']
    $service = & $Adapter['GetService'] $State['ServiceName']
    $null = Assert-ArcDemoService -Service $service -Name $State['ServiceName'] `
        -ExpectedIdentity $State['ServiceIdentity'] -RequireRunning
    Save-ArcDemoStep $Adapter $Context $State 'ServiceRestore' 'Complete'
}

function Restore-ArcDemoItem {
    param([System.Collections.IDictionary] $Adapter, [System.Collections.IDictionary] $Context,
        [System.Collections.IDictionary] $State, [ValidateSet('file', 'registry')][string] $Kind)

    if ($Kind -eq 'file') {
        $create = 'FileCreate'; $change = 'FileChange'; $remove = 'FileRemove'
        $path = $State['FilePath']; $snapshotField = 'FileSnapshot'
        $get = 'GetFile'; $delete = 'RemoveFile'
    }
    else {
        $create = 'RegistryCreate'; $change = 'RegistryChange'; $remove = 'RegistryRemove'
        $path = $State['RegistryKey']; $snapshotField = 'RegistrySnapshot'
        $get = 'GetRegistry'; $delete = 'RemoveRegistry'
    }
    $steps = $State['Steps']
    if ($steps[$remove] -ceq 'Complete') { return }
    if ($steps[$create] -ceq 'NotStarted') {
        Save-ArcDemoStep $Adapter $Context $State $remove 'Complete'
        return
    }
    $actual = & $Adapter[$get] $path
    if ($null -eq $actual) {
        Save-ArcDemoStep $Adapter $Context $State $remove 'Complete'
        return
    }
    if ($steps[$create] -cne 'Complete') {
        throw "The $Kind creation has an uncertain outcome. Review it manually; it was not removed."
    }
    $version = if ($steps[$change] -ceq 'Complete') { 'changed' } else { 'baseline' }
    Assert-ArcDemoOwnedSnapshot -Snapshot $State[$snapshotField] -Kind $Kind -RunId $State['RunId'] -Version $version
    Assert-ArcDemoSnapshot -Actual $actual -Expected $State[$snapshotField] -Kind $Kind
    Save-ArcDemoStep $Adapter $Context $State $remove 'Intent'
    & $Adapter[$delete] $path $State[$snapshotField]
    if ($null -ne (& $Adapter[$get] $path)) {
        throw "The $Kind still exists after the attempted removal."
    }
    Save-ArcDemoStep $Adapter $Context $State $remove 'Complete'
}

function Invoke-ArcDemoEngine {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Adapter,
        [Parameter(Mandatory)][ValidateSet('Prepare', 'Change', 'Revert')][string] $Mode,
        [Parameter(Mandatory)][string] $ComputerName,
        [string] $ServiceName,
        [string] $FilePath,
        [string] $RegistryKey,
        [string] $StatePath,
        [switch] $AcknowledgeTestOnly,
        [switch] $BaselineObserved,
        [switch] $WriteTestEvent,
        [string] $EventSource,
        [int] $EventId,
        [ValidateRange(0, 15)][int] $CpuSeconds = 0
    )

    if (-not $AcknowledgeTestOnly) {
        throw 'Explicit acknowledgement of the disposable test-only scope is required.'
    }
    & $Adapter['AssertHost'] $ComputerName
    $context = @{ StatePath = $null; Lock = $null }
    try {
        if ($Mode -eq 'Prepare') {
            Assert-ArcDemoInput -ComputerName $ComputerName -ServiceName $ServiceName `
                -FilePath $FilePath -RegistryKey $RegistryKey
            & $Adapter['AssertFilePath'] $FilePath
            $service = & $Adapter['GetService'] $ServiceName
            $identity = Assert-ArcDemoService -Service $service -Name $ServiceName `
                -RequireRunning -RequireSafeStop -RequireRunningDependencies
            if ($null -ne (& $Adapter['GetFile'] $FilePath)) {
                throw 'The designated test file already exists; it will not be overwritten.'
            }
            if ($null -ne (& $Adapter['GetRegistry'] $RegistryKey)) {
                throw 'The designated test registry key already exists; it will not be overwritten.'
            }
            if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Prepare synthetic demo items and a private recovery journal')) {
                return
            }
            $state = @{
                SchemaVersion = '1.0'
                RunId = [guid]::NewGuid().ToString('N')
                ComputerName = $ComputerName
                ServiceName = $ServiceName
                FilePath = $FilePath
                RegistryKey = $RegistryKey
                ServiceIdentity = $identity
                FileSnapshot = $null
                RegistrySnapshot = $null
                Stage = 'Preparing'
                Steps = @{
                    FileCreate = 'NotStarted'; RegistryCreate = 'NotStarted'
                    FileChange = 'NotStarted'; RegistryChange = 'NotStarted'
                    ServiceStop = 'NotStarted'; Event = 'NotStarted'; Cpu = 'NotStarted'
                    ServiceRestore = 'NotStarted'; FileRemove = 'NotStarted'; RegistryRemove = 'NotStarted'
                }
            }
            & $Adapter['NewJournal'] $context $state
            Save-ArcDemoStep $Adapter $context $state 'FileCreate' 'Intent'
            & $Adapter['CreateFile'] $FilePath (Get-ArcDemoFileText -RunId $state.RunId -Version 'baseline')
            $state['FileSnapshot'] = & $Adapter['GetFile'] $FilePath
            Assert-ArcDemoOwnedSnapshot -Snapshot $state['FileSnapshot'] -Kind 'file' -RunId $state.RunId -Version 'baseline'
            Save-ArcDemoStep $Adapter $context $state 'FileCreate' 'Complete'
            Save-ArcDemoStep $Adapter $context $state 'RegistryCreate' 'Intent'
            & $Adapter['CreateRegistry'] $RegistryKey (Get-ArcDemoRegistryValue -RunId $state.RunId -Version 'baseline')
            $state['RegistrySnapshot'] = & $Adapter['GetRegistry'] $RegistryKey
            Assert-ArcDemoOwnedSnapshot -Snapshot $state['RegistrySnapshot'] -Kind 'registry' -RunId $state.RunId -Version 'baseline'
            Save-ArcDemoStep $Adapter $context $state 'RegistryCreate' 'Complete'
            $state['Stage'] = 'Prepared'
            & $Adapter['SaveJournal'] $context $state
        }
        else {
            if ([string]::IsNullOrWhiteSpace($StatePath)) {
                throw 'The private recovery state path is required.'
            }
            $state = & $Adapter['OpenJournal'] $context $StatePath
            Assert-ArcDemoJournal -State $state -ComputerName $ComputerName
            & $Adapter['AssertFilePath'] $state['FilePath']
            if ($Mode -eq 'Change') {
                if ($state['Stage'] -cne 'Prepared') {
                    throw 'Only a fully prepared, unchanged demo can enter the change stage.'
                }
                if (-not $BaselineObserved) {
                    throw 'Confirm that the synthetic baseline was observed before requesting changes.'
                }
                if ($WriteTestEvent) {
                    if ([string]::IsNullOrWhiteSpace($EventSource) -or $EventId -lt 1 -or $EventId -gt 65535) {
                        throw 'An existing Application event source and event ID from 1 to 65535 are required.'
                    }
                    & $Adapter['AssertEventSource'] $EventSource
                }
                elseif ($EventSource -or $EventId -ne 0) {
                    throw 'Event source and ID are accepted only with the explicit test-event switch.'
                }
                $service = & $Adapter['GetService'] $state['ServiceName']
                $null = Assert-ArcDemoService -Service $service -Name $state['ServiceName'] `
                    -ExpectedIdentity $state['ServiceIdentity'] -RequireRunning -RequireSafeStop -RequireRunningDependencies
                foreach ($item in @(
                        @{ Kind = 'file'; Get = 'GetFile'; Path = $state['FilePath']; Snapshot = $state['FileSnapshot'] }
                        @{ Kind = 'registry'; Get = 'GetRegistry'; Path = $state['RegistryKey']; Snapshot = $state['RegistrySnapshot'] }
                    )) {
                    Assert-ArcDemoOwnedSnapshot -Snapshot $item.Snapshot -Kind $item.Kind -RunId $state.RunId -Version 'baseline'
                    Assert-ArcDemoSnapshot -Actual (& $Adapter[$item.Get] $item.Path) -Expected $item.Snapshot -Kind $item.Kind
                }
                if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Change synthetic items and stop the disposable test service')) {
                    return
                }
                $state['Stage'] = 'Changing'
                & $Adapter['SaveJournal'] $context $state
                Save-ArcDemoStep $Adapter $context $state 'FileChange' 'Intent'
                & $Adapter['ChangeFile'] $state['FilePath'] $state['FileSnapshot'] `
                    (Get-ArcDemoFileText -RunId $state.RunId -Version 'changed')
                $state['FileSnapshot'] = & $Adapter['GetFile'] $state['FilePath']
                Assert-ArcDemoOwnedSnapshot -Snapshot $state['FileSnapshot'] -Kind 'file' -RunId $state.RunId -Version 'changed'
                Save-ArcDemoStep $Adapter $context $state 'FileChange' 'Complete'
                Save-ArcDemoStep $Adapter $context $state 'RegistryChange' 'Intent'
                & $Adapter['ChangeRegistry'] $state['RegistryKey'] $state['RegistrySnapshot'] `
                    (Get-ArcDemoRegistryValue -RunId $state.RunId -Version 'changed')
                $state['RegistrySnapshot'] = & $Adapter['GetRegistry'] $state['RegistryKey']
                Assert-ArcDemoOwnedSnapshot -Snapshot $state['RegistrySnapshot'] -Kind 'registry' -RunId $state.RunId -Version 'changed'
                Save-ArcDemoStep $Adapter $context $state 'RegistryChange' 'Complete'
                Save-ArcDemoStep $Adapter $context $state 'ServiceStop' 'Intent'
                & $Adapter['StopService'] $state['ServiceName'] $state['ServiceIdentity']
                $service = & $Adapter['GetService'] $state['ServiceName']
                $null = Assert-ArcDemoService -Service $service -Name $state['ServiceName'] `
                    -ExpectedIdentity $state['ServiceIdentity']
                if ($service['State'] -cne 'Stopped') { throw 'The service did not remain stopped.' }
                Save-ArcDemoStep $Adapter $context $state 'ServiceStop' 'Complete'
                if ($WriteTestEvent) {
                    Save-ArcDemoStep $Adapter $context $state 'Event' 'Intent'
                    & $Adapter['WriteEvent'] $EventSource $EventId $state.RunId
                    Save-ArcDemoStep $Adapter $context $state 'Event' 'Complete'
                }
                else { Save-ArcDemoStep $Adapter $context $state 'Event' 'NotRequested' }
                if ($CpuSeconds -gt 0) {
                    Save-ArcDemoStep $Adapter $context $state 'Cpu' 'Intent'
                    & $Adapter['RunCpu'] $CpuSeconds
                    Save-ArcDemoStep $Adapter $context $state 'Cpu' 'Complete'
                }
                else { Save-ArcDemoStep $Adapter $context $state 'Cpu' 'NotRequested' }
                $state['Stage'] = 'Changed'
                & $Adapter['SaveJournal'] $context $state
            }
            else {
                if ($state['Stage'] -ceq 'Reverted') {
                    return [pscustomobject]@{ Stage = 'Reverted'; StatePath = $context.StatePath; AlreadyRestored = $true }
                }
                if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Restore the test service and remove unchanged synthetic items')) {
                    return
                }
                $state['Stage'] = 'Reverting'
                & $Adapter['SaveJournal'] $context $state
                $issues = [System.Collections.Generic.List[string]]::new()
                foreach ($item in @('service', 'file', 'registry')) {
                    try {
                        if ($item -eq 'service') { Restore-ArcDemoService $Adapter $context $state }
                        else { Restore-ArcDemoItem $Adapter $context $state $item }
                    }
                    catch {
                        $issues.Add("${item}: $($_.Exception.Message)")
                    }
                }
                if ($issues.Count -gt 0) {
                    $state['Stage'] = 'RevertIncomplete'
                    & $Adapter['SaveJournal'] $context $state
                    throw ('Restore is incomplete. ' + ($issues -join ' '))
                }
                $state['Stage'] = 'Reverted'
                & $Adapter['SaveJournal'] $context $state
            }
        }
        return [pscustomobject]@{
            Stage = $state['Stage']
            StatePath = $context.StatePath
            AlreadyRestored = $false
        }
    }
    catch {
        if ($context.StatePath) {
            throw "The demo operation stopped. Keep the private recovery state at '$($context.StatePath)' and review it before retrying. $($_.Exception.Message)"
        }
        throw
    }
    finally {
        & $Adapter['CloseJournal'] $context
    }
}

Export-ModuleMember -Function Invoke-ArcDemoEngine, Assert-ArcDemoInput, Assert-ArcDemoSnapshot, `
    Assert-ArcDemoService
