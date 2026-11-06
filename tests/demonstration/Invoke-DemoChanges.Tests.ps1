#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$demoDirectory = Join-Path $repository 'scripts/demonstration'
$discoveryDirectory = Join-Path $repository 'scripts/discovery'
Import-Module (Join-Path $demoDirectory 'ArcDemoEngine.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $demoDirectory 'ArcDemoHost.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $discoveryDirectory 'ArcPrivateEvidence.psm1') -ErrorAction Stop

function Assert-DemoTest {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Copy-DemoTestValue {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30) -AsHashtable -Depth 30)
}

function Initialize-DemoTestHost {
    $script:HostState = @{
        ComputerName = 'LABHOST'
        Service = @{
            Name = 'SyntheticService'; State = 'Running'; CanStop = $true
            PathName = 'C:\SyntheticService\service.exe'; StartName = 'LocalSystem'; StartMode = 'Manual'
            Dependencies = @(@{ Name = 'Dependency'; State = 'Running' })
            Dependents = @(@{ Name = 'Dependent'; State = 'Stopped' })
        }
        File = $null
        Registry = $null
        Journal = $null
        Events = 0
        CpuRuns = 0
        Generation = 0
        FailPoint = ''
        Actions = [System.Collections.Generic.List[string]]::new()
    }
}

function Invoke-DemoTestFailPoint {
    param([string] $Name)
    if ($script:HostState.FailPoint -ceq $Name) {
        $script:HostState.FailPoint = ''
        throw "Injected failure at $Name."
    }
}

function Get-DemoTestFile {
    param([string] $Text)
    $script:HostState.Generation++
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return @{
        Hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
        Length = [string] $bytes.Length
        FileId = '12345678-9ABCDEF0-12345678'
        CreationTicks = '100'
        WriteTicks = [string] $script:HostState.Generation
        Attributes = '0'
        Acl = 'synthetic-file-acl'
    }
}

function Get-DemoTestRegistry {
    param([string] $Value)
    return @{
        ValueCount = '1'; SubKeyCount = '0'; ValueKind = 'String'
        Value = $Value; Acl = 'synthetic-registry-acl'
    }
}

function Get-DemoTestAdapter {
    return @{
        AssertHost = {
            param($name)
            if ($name -ine $script:HostState.ComputerName) { throw 'Wrong test host.' }
        }
        AssertFilePath = { param($path) if ($path -notmatch '^C:\\') { throw 'Not a local test path.' } }
        GetService = {
            param($name)
            Assert-DemoTest ($name -ceq 'SyntheticService') 'Only the designated service is inspected'
            return (Copy-DemoTestValue $script:HostState.Service)
        }
        GetFile = {
            param($path)
            Assert-DemoTest ($path -ceq 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt') 'Only the designated file is inspected'
            return (Copy-DemoTestValue $script:HostState.File)
        }
        GetRegistry = {
            param($path)
            Assert-DemoTest ($path -ceq 'HKLM:\SOFTWARE\ArcSccmPoc-Test') 'Only the designated registry key is inspected'
            return (Copy-DemoTestValue $script:HostState.Registry)
        }
        NewJournal = {
            param($context, $state)
            $context['StatePath'] = 'private-test-state.json'
            $context['Lock'] = 'mock'
            $script:HostState.Actions.Add('journal:new')
            $script:HostState.Journal = Copy-DemoTestValue $state
        }
        OpenJournal = {
            param($context, $path)
            if ($path -cne 'private-test-state.json' -or $null -eq $script:HostState.Journal) {
                throw 'Private test state is missing.'
            }
            $context['StatePath'] = $path
            $context['Lock'] = 'mock'
            return (Copy-DemoTestValue $script:HostState.Journal)
        }
        SaveJournal = {
            param($context, $state)
            Assert-DemoTest ($context['StatePath'] -ceq 'private-test-state.json' -and $context['Lock'] -ceq 'mock') 'Journal writes require the private lock'
            Invoke-DemoTestFailPoint 'SaveJournal'
            $script:HostState.Actions.Add('journal:save')
            $script:HostState.Journal = Copy-DemoTestValue $state
        }
        CloseJournal = { param($context) $context['Lock'] = $null }
        CreateFile = {
            param($path, $text)
            Assert-DemoTest ($path -ceq 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt') 'Only the designated file is created'
            Invoke-DemoTestFailPoint 'CreateFile:before'
            if ($null -ne $script:HostState.File) { throw 'Test file already exists.' }
            $script:HostState.Actions.Add('file:create')
            $script:HostState.File = Get-DemoTestFile $text
            Invoke-DemoTestFailPoint 'CreateFile:after'
        }
        ChangeFile = {
            param($path, $expected, $text)
            Assert-DemoTest ($path -ceq 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt') 'Only the designated file is changed'
            Assert-ArcDemoSnapshot -Actual $script:HostState.File -Expected $expected -Kind 'file'
            Invoke-DemoTestFailPoint 'ChangeFile:before'
            $script:HostState.Actions.Add('file:change')
            $script:HostState.File = Get-DemoTestFile $text
            Invoke-DemoTestFailPoint 'ChangeFile:after'
        }
        RemoveFile = {
            param($path, $expected)
            Assert-DemoTest ($path -ceq 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt') 'Only the designated file is removed'
            Assert-ArcDemoSnapshot -Actual $script:HostState.File -Expected $expected -Kind 'file'
            Invoke-DemoTestFailPoint 'RemoveFile:before'
            $script:HostState.Actions.Add('file:remove')
            $script:HostState.File = $null
            Invoke-DemoTestFailPoint 'RemoveFile:after'
        }
        CreateRegistry = {
            param($path, $value)
            Assert-DemoTest ($path -ceq 'HKLM:\SOFTWARE\ArcSccmPoc-Test') 'Only the designated key is created'
            Invoke-DemoTestFailPoint 'CreateRegistry:before'
            if ($null -ne $script:HostState.Registry) { throw 'Test key already exists.' }
            $script:HostState.Actions.Add('registry:create')
            $script:HostState.Registry = Get-DemoTestRegistry $value
            Invoke-DemoTestFailPoint 'CreateRegistry:after'
        }
        ChangeRegistry = {
            param($path, $expected, $value)
            Assert-DemoTest ($path -ceq 'HKLM:\SOFTWARE\ArcSccmPoc-Test') 'Only the designated key is changed'
            Assert-ArcDemoSnapshot -Actual $script:HostState.Registry -Expected $expected -Kind 'registry'
            Invoke-DemoTestFailPoint 'ChangeRegistry:before'
            $script:HostState.Actions.Add('registry:change')
            $script:HostState.Registry = Get-DemoTestRegistry $value
            Invoke-DemoTestFailPoint 'ChangeRegistry:after'
        }
        RemoveRegistry = {
            param($path, $expected)
            Assert-DemoTest ($path -ceq 'HKLM:\SOFTWARE\ArcSccmPoc-Test') 'Only the designated key is removed'
            Assert-ArcDemoSnapshot -Actual $script:HostState.Registry -Expected $expected -Kind 'registry'
            Invoke-DemoTestFailPoint 'RemoveRegistry:before'
            $script:HostState.Actions.Add('registry:remove')
            $script:HostState.Registry = $null
            Invoke-DemoTestFailPoint 'RemoveRegistry:after'
        }
        StopService = {
            param($name, $identity)
            $null = Assert-ArcDemoService -Service $script:HostState.Service -Name $name `
                -ExpectedIdentity $identity -RequireRunning -RequireSafeStop -RequireRunningDependencies
            Invoke-DemoTestFailPoint 'StopService:before'
            $script:HostState.Actions.Add('service:stop')
            $script:HostState.Service.State = 'Stopped'
            Invoke-DemoTestFailPoint 'StopService:after'
        }
        StartService = {
            param($name, $identity)
            $null = Assert-ArcDemoService -Service $script:HostState.Service -Name $name `
                -ExpectedIdentity $identity -RequireRunningDependencies
            Invoke-DemoTestFailPoint 'StartService:before'
            $script:HostState.Actions.Add('service:start')
            $script:HostState.Service.State = 'Running'
            Invoke-DemoTestFailPoint 'StartService:after'
        }
        AssertEventSource = { param($source) if ($source -cne 'KnownSource') { throw 'Unregistered event source.' } }
        WriteEvent = {
            param($source, $id, $runId)
            Assert-DemoTest ($source -ceq 'KnownSource' -and $id -gt 0 -and $id -le 65535 -and
                $runId -match '^[0-9a-f]{32}$') 'Only the selected event and synthetic run ID are written'
            Invoke-DemoTestFailPoint 'WriteEvent:before'
            $script:HostState.Actions.Add('event:write')
            $script:HostState.Events++
            Invoke-DemoTestFailPoint 'WriteEvent:after'
        }
        RunCpu = {
            param($seconds)
            Assert-DemoTest ($seconds -ge 1 -and $seconds -le 15) 'CPU duration is bounded'
            $script:HostState.Actions.Add('cpu:run')
            $script:HostState.CpuRuns++
        }
    }
}

function Get-DemoTestParameter {
    param([ValidateSet('Prepare', 'Change', 'Revert')][string] $Mode)
    $parameters = @{
        Adapter = Get-DemoTestAdapter; Mode = $Mode; ComputerName = 'LABHOST'
        AcknowledgeTestOnly = $true; Confirm = $false
    }
    if ($Mode -eq 'Prepare') {
        $parameters.ServiceName = 'SyntheticService'
        $parameters.FilePath = 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt'
        $parameters.RegistryKey = 'HKLM:\SOFTWARE\ArcSccmPoc-Test'
    }
    else {
        $parameters.StatePath = 'private-test-state.json'
    }
    if ($Mode -eq 'Change') { $parameters.BaselineObserved = $true }
    return $parameters
}

function Assert-DemoTestFailure {
    param([scriptblock] $Operation, [string] $Message)
    $failed = $false
    try { $null = & $Operation }
    catch {
        $failed = $true
        Assert-DemoTest ($_.Exception.Message.Contains($Message)) "Failure reports '$Message': $($_.Exception.Message)"
    }
    Assert-DemoTest $failed "Expected failure: $Message"
}

function Invoke-DemoTestPrepare {
    $parameters = Get-DemoTestParameter 'Prepare'
    return (Invoke-ArcDemoEngine @parameters)
}

function Invoke-DemoTestChange {
    $parameters = Get-DemoTestParameter 'Change'
    return (Invoke-ArcDemoEngine @parameters)
}

function Invoke-DemoTestRevert {
    $parameters = Get-DemoTestParameter 'Revert'
    return (Invoke-ArcDemoEngine @parameters)
}

Initialize-DemoTestHost
$parameters = Get-DemoTestParameter 'Prepare'
$parameters.WhatIf = $true
$null = Invoke-ArcDemoEngine @parameters
Assert-DemoTest ($script:HostState.Actions.Count -eq 0) 'Prepare WhatIf does not create a journal or mutate the host'
Assert-DemoTest ($null -eq $script:HostState.File -and $null -eq $script:HostState.Registry) 'Prepare WhatIf leaves items absent'
Write-Output 'PASS: Prepare WhatIf is read-only'

Initialize-DemoTestHost
$prepared = Invoke-DemoTestPrepare
Assert-DemoTest ($prepared.Stage -ceq 'Prepared' -and $prepared.StatePath -ceq 'private-test-state.json') 'Preparation returns private recovery state'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Running') 'Preparation does not stop the service'
$beforeWhatIf = ConvertTo-Json -InputObject $script:HostState.Journal -Depth 30 -Compress
$countBeforeWhatIf = $script:HostState.Actions.Count
$parameters = Get-DemoTestParameter 'Change'
$parameters.WhatIf = $true
$null = Invoke-ArcDemoEngine @parameters
$parameters = Get-DemoTestParameter 'Revert'
$parameters.WhatIf = $true
$null = Invoke-ArcDemoEngine @parameters
Assert-DemoTest ($script:HostState.Actions.Count -eq $countBeforeWhatIf) 'Change and revert WhatIf do not save or mutate'
Assert-DemoTest ((ConvertTo-Json -InputObject $script:HostState.Journal -Depth 30 -Compress) -ceq $beforeWhatIf) 'WhatIf leaves recovery state unchanged'
$parameters = Get-DemoTestParameter 'Change'
$parameters.WriteTestEvent = $true
$parameters.EventSource = 'KnownSource'
$parameters.EventId = 42
$parameters.CpuSeconds = 5
$changed = Invoke-ArcDemoEngine @parameters
Assert-DemoTest ($changed.Stage -ceq 'Changed' -and $script:HostState.Service.State -ceq 'Stopped') 'Change holds the disposable service stopped'
Assert-DemoTest ($script:HostState.Events -eq 1 -and $script:HostState.CpuRuns -eq 1) 'Requested event and bounded CPU are each run once'
$restored = Invoke-DemoTestRevert
Assert-DemoTest ($restored.Stage -ceq 'Reverted' -and $script:HostState.Service.State -ceq 'Running') 'Revert restarts the originally running service'
Assert-DemoTest ($null -eq $script:HostState.File -and $null -eq $script:HostState.Registry) 'Revert removes only the synthetic items'
Assert-DemoTest ($script:HostState.Events -eq 1) 'The written event is not removed or repeated'
$countBeforeRepeat = $script:HostState.Actions.Count
$again = Invoke-DemoTestRevert
Assert-DemoTest ($again.AlreadyRestored -and $script:HostState.Actions.Count -eq $countBeforeRepeat) 'A repeated revert is a no-op'
Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$null = Invoke-DemoTestRevert
Assert-DemoTest ($script:HostState.Service.State -ceq 'Running' -and
    @($script:HostState.Actions | Where-Object { $_ -like 'service:*' }).Count -eq 0) 'Reverting a baseline does not touch the service'
Write-Output 'PASS: Staged prepare, change, restore and idempotent revert'

foreach ($case in @(
        @{ Name = 'wrong-host'; Setup = { $script:HostState.ComputerName = 'OTHER' }; Message = 'Wrong test host' }
        @{ Name = 'existing-file'; Setup = { $script:HostState.File = @{ Hash = 'external' } }; Message = 'test file already exists' }
        @{ Name = 'existing-key'; Setup = { $script:HostState.Registry = @{ Value = 'external' } }; Message = 'registry key already exists' }
        @{ Name = 'stopped-service'; Setup = { $script:HostState.Service.State = 'Stopped' }; Message = 'must already be running' }
        @{ Name = 'disabled-service'; Setup = { $script:HostState.Service.StartMode = 'Disabled' }; Message = 'disabled or has an unsupported start mode' }
        @{ Name = 'unstoppable-service'; Setup = { $script:HostState.Service.CanStop = $false }; Message = 'does not currently accept a stop' }
        @{ Name = 'active-dependent'; Setup = { $script:HostState.Service.Dependents[0].State = 'Running' }; Message = 'active or indeterminate dependent' }
        @{ Name = 'stopped-dependency'; Setup = { $script:HostState.Service.Dependencies[0].State = 'Stopped' }; Message = 'dependency is not running' }
    )) {
    Initialize-DemoTestHost
    & $case.Setup
    Assert-DemoTestFailure { Invoke-DemoTestPrepare } $case.Message
    Assert-DemoTest ($script:HostState.Actions.Count -eq 0) "$($case.Name) fails before journal or guest changes"
}
Initialize-DemoTestHost
$parameters = Get-DemoTestParameter 'Prepare'
$parameters.AcknowledgeTestOnly = $false
Assert-DemoTestFailure { Invoke-ArcDemoEngine @parameters } 'acknowledgement'
foreach ($invalid in @(
        @{ Field = 'FilePath'; Value = '\\server\share\ArcSccmPoc-Test.txt'; Message = 'absolute local path' }
        @{ Field = 'FilePath'; Value = 'C:\..\ArcSccmPoc-Test.txt'; Message = 'unsafe path component' }
        @{ Field = 'FilePath'; Value = 'C:\Synthetic\production.txt'; Message = 'ArcSccmPoc-<name>.txt' }
        @{ Field = 'FilePath'; Value = 'C:\Synthetic\ArcSccmPoc-Test.txt'; Message = 'dedicated ArcSccmPoc-<name> directory' }
        @{ Field = 'RegistryKey'; Value = 'HKLM:\SOFTWARE\Production'; Message = 'direct HKLM' }
        @{ Field = 'RegistryKey'; Value = 'HKLM:\SOFTWARE\ArcSccmPoc-Test\Child'; Message = 'direct HKLM' }
        @{ Field = 'ServiceName'; Value = '*'; Message = 'literal service name' }
        @{ Field = 'ComputerName'; Value = 'LABHOST*'; Message = 'Wrong test host' }
    )) {
    $parameters = Get-DemoTestParameter 'Prepare'
    $parameters[$invalid.Field] = $invalid.Value
    Assert-DemoTestFailure { Invoke-ArcDemoEngine @parameters } $invalid.Message
    Assert-DemoTest ($script:HostState.Actions.Count -eq 0) 'Invalid inputs do not mutate the host'
}
Write-Output 'PASS: Host, input, existing-state and dependency safeguards'

foreach ($case in @(
        @{ Name = 'baseline'; Setup = { $parameters.BaselineObserved = $false }; Message = 'baseline was observed' }
        @{ Name = 'file'; Setup = { $script:HostState.File.Acl = 'changed' }; Message = 'file has changed' }
        @{ Name = 'replaced-file'; Setup = { $script:HostState.File.FileId = 'different-file-id' }; Message = 'file has changed' }
        @{ Name = 'registry'; Setup = { $script:HostState.Registry.SubKeyCount = '1' }; Message = 'registry has changed' }
        @{ Name = 'service-identity'; Setup = { $script:HostState.Service.PathName = 'different' }; Message = 'service identity or configuration' }
        @{ Name = 'service-dependencies'; Setup = { $script:HostState.Service.Dependencies[0].State = 'Stopped' }; Message = 'dependency is not running' }
        @{ Name = 'event-source'; Setup = { $parameters.WriteTestEvent = $true; $parameters.EventSource = 'Unknown'; $parameters.EventId = 1 }; Message = 'Unregistered event source' }
        @{ Name = 'event-id'; Setup = { $parameters.WriteTestEvent = $true; $parameters.EventSource = 'KnownSource'; $parameters.EventId = 65536 }; Message = 'event ID' }
        @{ Name = 'zero-event-id'; Setup = { $parameters.WriteTestEvent = $true; $parameters.EventSource = 'KnownSource'; $parameters.EventId = 0 }; Message = 'event ID' }
        @{ Name = 'unrequested-event'; Setup = { $parameters.EventSource = 'KnownSource'; $parameters.EventId = 1 }; Message = 'only with the explicit test-event switch' }
    )) {
    Initialize-DemoTestHost
    $null = Invoke-DemoTestPrepare
    $parameters = Get-DemoTestParameter 'Change'
    & $case.Setup
    $countBefore = $script:HostState.Actions.Count
    Assert-DemoTestFailure { Invoke-ArcDemoEngine @parameters } $case.Message
    Assert-DemoTest ($script:HostState.Actions.Count -eq $countBefore) "$($case.Name) fails before changing guest or journal"
}
Write-Output 'PASS: Baseline, drift and event preflight safeguards'

foreach ($case in @(
        @{ Setup = { $script:HostState.Journal.Steps.FileCreate = 'NotRequested' }; Message = 'invalid FileCreate status' }
        @{ Setup = { $script:HostState.Journal.ServiceIdentity.Name = 'OtherService' }; Message = 'does not describe the designated' }
        @{ Setup = { $script:HostState.Journal.ServiceIdentity.Dependencies = @('Dependency', 'dependency') }; Message = 'invalid or duplicated' }
        @{ Setup = { $script:HostState.Journal.FileSnapshot.Hash = 'tampered' }; Message = 'expected synthetic contents' }
        @{ Setup = { $script:HostState.Journal.FileSnapshot.Remove('Acl') }; Message = 'invalid or missing Acl metadata' }
        @{ Setup = { $script:HostState.Journal.Steps.ServiceStop = 'Complete' }; Message = 'inconsistent operation ordering' }
        @{ Setup = { $script:HostState.Journal.Stage = 'Reverted' }; Message = 'reverted state is incomplete' }
        @{ Setup = { $script:HostState.Journal.Unexpected = 'value' }; Message = 'unexpected fields' }
    )) {
    Initialize-DemoTestHost
    $null = Invoke-DemoTestPrepare
    & $case.Setup
    $countBefore = $script:HostState.Actions.Count
    Assert-DemoTestFailure { Invoke-DemoTestChange } $case.Message
    Assert-DemoTest ($script:HostState.Actions.Count -eq $countBefore) 'Malformed recovery state cannot trigger changes'
}
Initialize-DemoTestHost
$parameters = Get-DemoTestParameter 'Change'
$parameters.CpuSeconds = 16
Assert-DemoTestFailure { Invoke-ArcDemoEngine @parameters } 'maximum allowed range of 15'
Assert-DemoTest ($script:HostState.Actions.Count -eq 0) 'Out-of-range CPU load is rejected before changes'
Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$parameters = Get-DemoTestParameter 'Change'
$parameters.WriteTestEvent = $true
$parameters.EventSource = 'KnownSource'
$parameters.EventId = 65535
$parameters.CpuSeconds = 15
$null = Invoke-ArcDemoEngine @parameters
Assert-DemoTest ($script:HostState.Events -eq 1 -and $script:HostState.CpuRuns -eq 1) 'Maximum supported event ID and CPU duration are accepted'
$null = Invoke-DemoTestRevert
Write-Output 'PASS: Journal integrity and CPU-duration bounds'

Initialize-DemoTestHost
$script:HostState.FailPoint = 'CreateRegistry:before'
Assert-DemoTestFailure { Invoke-DemoTestPrepare } 'Injected failure'
Assert-DemoTest ($null -ne $script:HostState.File -and $null -eq $script:HostState.Registry) 'Failed preparation leaves a recorded file'
$result = Invoke-DemoTestRevert
Assert-DemoTest ($result.Stage -ceq 'Reverted' -and $null -eq $script:HostState.File) 'Recorded partial preparation is recoverable'

Initialize-DemoTestHost
$script:HostState.FailPoint = 'CreateFile:after'
Assert-DemoTestFailure { Invoke-DemoTestPrepare } 'Injected failure'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'creation has an uncertain outcome'
Assert-DemoTest ($null -ne $script:HostState.File -and $script:HostState.Journal.Stage -ceq 'RevertIncomplete') 'Uncertain file ownership is not removed'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$script:HostState.FailPoint = 'ChangeFile:after'
Assert-DemoTestFailure { Invoke-DemoTestChange } 'Injected failure'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'file has changed'
Assert-DemoTest ($null -ne $script:HostState.File -and $null -eq $script:HostState.Registry) 'Ambiguous changed file is retained while safe registry cleanup proceeds'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Running') 'A service not stopped by the script remains untouched'

Initialize-DemoTestHost
$script:HostState.FailPoint = 'CreateRegistry:after'
Assert-DemoTestFailure { Invoke-DemoTestPrepare } 'Injected failure'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'registry creation has an uncertain outcome'
Assert-DemoTest ($null -eq $script:HostState.File -and $null -ne $script:HostState.Registry) 'An uncertain registry key is retained'
Write-Output 'PASS: Partial file and registry changes fail closed'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$script:HostState.FailPoint = 'StopService:after'
Assert-DemoTestFailure { Invoke-DemoTestChange } 'Injected failure'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'uncertain outcome'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Stopped') 'An uncertain service stop is not automatically restarted'
Assert-DemoTest ($null -eq $script:HostState.File -and $null -eq $script:HostState.Registry) 'Safe synthetic items are still removed'
$script:HostState.Service.State = 'Running'
$result = Invoke-DemoTestRevert
Assert-DemoTest ($result.Stage -ceq 'Reverted') 'Manual service restoration permits a later completed revert'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$null = Invoke-DemoTestChange
$script:HostState.FailPoint = 'StartService:before'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'Injected failure'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'uncertain outcome'
Assert-DemoTest (@($script:HostState.Actions | Where-Object { $_ -ceq 'service:start' }).Count -eq 0) 'An uncertain restart is not blindly repeated'
$script:HostState.Service.State = 'Running'
$null = Invoke-DemoTestRevert

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$null = Invoke-DemoTestChange
$script:HostState.Service.Dependencies[0].State = 'Stopped'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'dependency is not running'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Stopped') 'A stopped dependency is not implicitly restarted'
Assert-DemoTest ($null -eq $script:HostState.File -and $null -eq $script:HostState.Registry) 'Independent cleanup still proceeds'
$script:HostState.Service.Dependencies[0].State = 'Running'
$result = Invoke-DemoTestRevert
Assert-DemoTest ($result.Stage -ceq 'Reverted' -and $script:HostState.Service.State -ceq 'Running') 'Service restart can be retried after dependency recovery'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$null = Invoke-DemoTestChange
$script:HostState.FailPoint = 'StartService:after'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'Injected failure'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Running') 'The service can be running after an ambiguous restart'
$result = Invoke-DemoTestRevert
Assert-DemoTest ($result.Stage -ceq 'Reverted') 'A later revert recognises the already-running service'
Write-Output 'PASS: Uncertain service stop and restart require manual review'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$parameters = Get-DemoTestParameter 'Change'
$parameters.WriteTestEvent = $true
$parameters.EventSource = 'KnownSource'
$parameters.EventId = 100
$script:HostState.FailPoint = 'WriteEvent:after'
Assert-DemoTestFailure { Invoke-ArcDemoEngine @parameters } 'Injected failure'
$null = Invoke-DemoTestRevert
Assert-DemoTest ($script:HostState.Events -eq 1 -and $script:HostState.Service.State -ceq 'Running') 'An ambiguous event is not repeated and service restoration still occurs'
Write-Output 'PASS: Irreversible event failure is surfaced without retry'

Initialize-DemoTestHost
$null = Invoke-DemoTestPrepare
$null = Invoke-DemoTestChange
$script:HostState.Service.StartMode = 'Disabled'
$script:HostState.File.Acl = 'external-file-acl'
$script:HostState.Registry.ValueCount = '2'
Assert-DemoTestFailure { Invoke-DemoTestRevert } 'Restore is incomplete'
Assert-DemoTest ($script:HostState.Service.State -ceq 'Stopped') 'Changed service configuration is not controlled'
Assert-DemoTest ($null -ne $script:HostState.File -and $null -ne $script:HostState.Registry) 'Externally changed file and registry key are preserved'
Write-Output 'PASS: External changes are preserved during revert'

if (-not $IsWindows) {
    $scriptPath = Join-Path $demoDirectory 'Invoke-DemoChanges.ps1'
    Assert-DemoTestFailure {
        & $scriptPath -TestComputerName 'LABHOST' -AcknowledgeTestOnly -TestServiceName 'SyntheticService' `
            -TestFilePath 'C:\ArcSccmPoc-Test\ArcSccmPoc-Test.txt' -TestRegistryKey 'HKLM:\SOFTWARE\ArcSccmPoc-Test' `
            -WhatIf -Confirm:$false
    } 'Windows test server'
    Write-Output 'PASS: Real entry point refuses a non-Windows host'
}

& (Get-Module ArcDemoHost) { Initialize-ArcDemoNative }
$nativeType = 'ArcSccmPoc.Native' -as [type]
$fileInfoType = $nativeType.GetNestedType('ByHandleFileInformation', [System.Reflection.BindingFlags]::NonPublic)
$dispositionType = $nativeType.GetNestedType('FileDisposition', [System.Reflection.BindingFlags]::NonPublic)
$sizeOfType = [System.Runtime.InteropServices.Marshal].GetMethod('SizeOf', [type[]] @([type]))
Assert-DemoTest ($sizeOfType.Invoke($null, @($fileInfoType)) -eq 52) 'Win32 file information layout has the documented size'
Assert-DemoTest ($sizeOfType.Invoke($null, @($dispositionType)) -eq 1) 'Win32 deletion disposition uses a single BOOLEAN byte'
Write-Output 'PASS: Native definitions compile and have expected structure sizes; no native calls made'

$privateAdapter = Get-ArcDemoWindowsAdapter
$privateContext = @{ StatePath = $null; Lock = $null }
$privateDirectory = $null
try {
    $privateState = @{ RunId = [guid]::NewGuid().ToString('N'); Stage = 'synthetic'; Nested = @{ Value = 1 } }
    & $privateAdapter['NewJournal'] $privateContext $privateState
    $privateDirectory = [System.IO.Path]::GetDirectoryName($privateContext.StatePath)
    $privateStatePath = $privateContext.StatePath
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $discoveryDirectory -LiteralPath $privateStatePath
    $privateState.Nested.Value = 2
    & $privateAdapter['SaveJournal'] $privateContext $privateState
    $contendingContext = @{ StatePath = $null; Lock = $null }
    Assert-DemoTestFailure { & $privateAdapter['OpenJournal'] $contendingContext $privateStatePath } 'being used by another process'
    & $privateAdapter['CloseJournal'] $contendingContext
    & $privateAdapter['CloseJournal'] $privateContext
    $readContext = @{ StatePath = $null; Lock = $null }
    $readState = & $privateAdapter['OpenJournal'] $readContext $privateStatePath
    Assert-DemoTest ($readState.Nested.Value -eq 2) 'Private journal update is persisted'
    & $privateAdapter['CloseJournal'] $readContext
    [System.IO.File]::WriteAllText($privateStatePath, '{"Stage":"one","STAGE":"two"}')
    Assert-DemoTestFailure { & $privateAdapter['OpenJournal'] $readContext $privateStatePath } 'duplicate JSON fields'
    & $privateAdapter['CloseJournal'] $readContext
    Assert-DemoTest (@(Get-ChildItem -LiteralPath $privateDirectory -Force).Count -eq 2) 'No temporary journal files remain'
    Write-Output 'PASS: Private journal persistence, locking and duplicate-field rejection'
}
finally {
    & $privateAdapter['CloseJournal'] $privateContext
    if ($null -ne $privateDirectory) {
        foreach ($name in @('state.json', 'state.lock')) {
            $path = Join-Path $privateDirectory $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
        }
        Remove-Item -LiteralPath $privateDirectory -ErrorAction Stop
    }
}
