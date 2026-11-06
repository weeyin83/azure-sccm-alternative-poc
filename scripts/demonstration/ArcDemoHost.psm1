#Requires -Version 7.4
Set-StrictMode -Version Latest

$script:DiscoveryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../discovery'))
$script:RepositoryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:DiscoveryDirectory 'ArcPrivateEvidence.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ArcDemoEngine.psm1') -ErrorAction Stop

function Assert-ArcDemoWindowsHost {
    param([string] $ComputerName)

    if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
        throw 'The demo requires 64-bit PowerShell 7.4 or later on the local Windows test server.'
    }
    if ($env:COMPUTERNAME -ine $ComputerName) {
        throw 'The supplied test computer does not match the local computer.'
    }
    $principal = [System.Security.Principal.WindowsPrincipal]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent()
    )
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'An elevated local administrator session is required.'
    }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -ne 3) {
        throw 'The demo supports a standalone or member Windows Server, not a client or domain controller.'
    }
}

function Assert-ArcDemoFilePath {
    param([string] $Path)

    $normalised = [System.IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($Path, $normalised, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The test file path must already be a normalised absolute path.'
    }
    $repositoryPrefix = $script:RepositoryDirectory.TrimEnd('\') + '\'
    if ($normalised.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The synthetic test file must be outside the repository.'
    }
    foreach ($specialFolder in @(
            [Environment+SpecialFolder]::Windows,
            [Environment+SpecialFolder]::ProgramFiles,
            [Environment+SpecialFolder]::ProgramFilesX86
        )) {
        $protectedDirectory = [Environment]::GetFolderPath($specialFolder)
        if ($protectedDirectory -and $normalised.StartsWith(
                $protectedDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The synthetic test file must not be in Windows or a Program Files directory.'
        }
    }
    $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($normalised))
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or $drive.DriveFormat -ine 'NTFS') {
        throw 'The synthetic test file must be on a fixed local NTFS drive.'
    }
    $directory = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetDirectoryName($normalised))
    while ($null -ne $directory) {
        $item = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'The test file parent and its ancestors must be real directories, not links.'
        }
        $directory = $directory.Parent
    }
}

function Get-ArcDemoService {
    param([string] $Name)

    $controllers = @(Get-Service -Name $Name -ErrorAction Stop)
    if ($controllers.Count -ne 1 -or $controllers[0].Name -ine $Name) {
        throw 'The designated service could not be uniquely inspected.'
    }
    $controller = $controllers[0]
    try {
        $instances = @(Get-CimInstance -ClassName Win32_Service -Filter "Name = '$Name'" -ErrorAction Stop)
        if ($instances.Count -ne 1 -or $instances[0].Name -ine $Name) {
            throw 'The designated service configuration could not be uniquely inspected.'
        }
        $dependencies = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($controller.ServicesDependedOn)) {
            try {
                $entry.Refresh()
                $dependencies.Add(@{ Name = $entry.ServiceName; State = $entry.Status.ToString() })
            }
            finally { $entry.Dispose() }
        }
        $dependents = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($controller.DependentServices)) {
            try {
                $entry.Refresh()
                $dependents.Add(@{ Name = $entry.ServiceName; State = $entry.Status.ToString() })
            }
            finally { $entry.Dispose() }
        }
        return @{
            Name = $controller.ServiceName
            State = $controller.Status.ToString()
            CanStop = [bool] $controller.CanStop
            PathName = $instances[0].PathName
            StartName = $instances[0].StartName
            StartMode = $instances[0].StartMode
            Dependencies = $dependencies.ToArray()
            Dependents = $dependents.ToArray()
        }
    }
    finally { $controller.Dispose() }
}

function Invoke-ArcDemoServiceControl {
    param([string] $Name, [System.Collections.IDictionary] $Identity, [ValidateSet('Stop', 'Start')][string] $Action)

    $observation = Get-ArcDemoService -Name $Name
    if ($Action -eq 'Stop') {
        $null = Assert-ArcDemoService -Service $observation -Name $Name -ExpectedIdentity $Identity `
            -RequireRunning -RequireSafeStop -RequireRunningDependencies
    }
    else {
        $null = Assert-ArcDemoService -Service $observation -Name $Name -ExpectedIdentity $Identity `
            -RequireRunningDependencies
        if ($observation['State'] -cne 'Stopped') {
            throw 'The disposable service is not stopped; automatic restart is refused.'
        }
    }
    $controller = Get-Service -Name $Name -ErrorAction Stop
    try {
        if ($controller.ServiceName -ine $Name) { throw 'The service control target changed.' }
        if ($Action -eq 'Stop') {
            $controller.Stop()
            $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
        else {
            $controller.Start()
            $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
        }
    }
    finally { $controller.Dispose() }
}

function Open-ArcDemoFileStream {
    param([string] $Path, [ValidateSet('Read', 'Write', 'Delete')][string] $Mode, [switch] $AllowMissing)

    Initialize-ArcDemoNative
    $handle = [ArcSccmPoc.Native]::OpenFile($Path, ($Mode -eq 'Write'), ($Mode -eq 'Delete'), $AllowMissing)
    if ($null -eq $handle) { return $null }
    try {
        $access = if ($Mode -eq 'Write') { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
        return [System.IO.FileStream]::new($handle, $access)
    }
    catch {
        $handle.Dispose()
        throw
    }
}

function Get-ArcDemoOpenFileSnapshot {
    param([System.IO.FileStream] $Stream)

    $identity = [ArcSccmPoc.Native]::InspectFile($Stream.SafeFileHandle)
    if ($Stream.Length -gt 4096) { throw 'The synthetic test file has unexpected contents.' }
    $Stream.Position = 0
    $bytes = [byte[]]::new([int] $Stream.Length)
    $Stream.ReadExactly($bytes, 0, $bytes.Length)
    $Stream.Position = 0
    $security = [System.IO.FileSystemAclExtensions]::GetAccessControl($Stream)
    return @{
        Hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
        Length = [string] $bytes.LongLength
        FileId = $identity.Id
        CreationTicks = [string] $identity.CreationTicks
        WriteTicks = [string] $identity.WriteTicks
        Attributes = [string] $identity.Attributes
        Acl = $security.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access -bor
            [System.Security.AccessControl.AccessControlSections]::Owner -bor
            [System.Security.AccessControl.AccessControlSections]::Group
        )
    }
}

function Get-ArcDemoFile {
    param([string] $Path)

    Assert-ArcDemoFilePath -Path $Path
    $stream = Open-ArcDemoFileStream -Path $Path -Mode 'Read' -AllowMissing
    if ($null -eq $stream) { return $null }
    try { return (Get-ArcDemoOpenFileSnapshot -Stream $stream) }
    finally { $stream.Dispose() }
}

function Invoke-ArcDemoFileCreation {
    param([string] $Path, [string] $Text)

    Assert-ArcDemoFilePath -Path $Path
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Invoke-ArcDemoFileChange {
    param([string] $Path, [System.Collections.IDictionary] $Expected, [string] $Text)

    Assert-ArcDemoFilePath -Path $Path
    $stream = Open-ArcDemoFileStream -Path $Path -Mode 'Write'
    try {
        Assert-ArcDemoSnapshot -Actual (Get-ArcDemoOpenFileSnapshot -Stream $stream) -Expected $Expected -Kind 'file'
        $newBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $stream.Position = 0
        $stream.SetLength(0)
        $stream.Write($newBytes, 0, $newBytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Invoke-ArcDemoFileRemoval {
    param([string] $Path, [System.Collections.IDictionary] $Expected)

    Assert-ArcDemoFilePath -Path $Path
    $stream = Open-ArcDemoFileStream -Path $Path -Mode 'Delete'
    try {
        Assert-ArcDemoSnapshot -Actual (Get-ArcDemoOpenFileSnapshot -Stream $stream) -Expected $Expected -Kind 'file'
        [ArcSccmPoc.Native]::MarkForDeletion($stream.SafeFileHandle)
    }
    finally { $stream.Dispose() }
}

function Initialize-ArcDemoNative {
    if ('ArcSccmPoc.Native' -as [type]) { return }
    $source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ArcSccmPoc {
    public sealed class FileIdentity {
        public string Id { get; set; }
        public long CreationTicks { get; set; }
        public long WriteTicks { get; set; }
        public uint Attributes { get; set; }
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
            public uint Attributes;
            public uint CreationLow;
            public uint CreationHigh;
            public uint AccessLow;
            public uint AccessHigh;
            public uint WriteLow;
            public uint WriteHigh;
            public uint VolumeSerial;
            public uint SizeHigh;
            public uint SizeLow;
            public uint Links;
            public uint IndexHigh;
            public uint IndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDisposition {
            public byte DeleteFile;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
            uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation info);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass,
            ref FileDisposition disposition, uint size);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        private static extern int RegCreateKeyExW(SafeRegistryHandle parent, string name, int reserved,
            string keyClass, int options, int access, IntPtr security, out SafeRegistryHandle key, out int disposition);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr RegisterEventSourceW(string server, string source);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReportEventW(IntPtr handle, ushort type, ushort category, uint eventId,
            IntPtr userSid, ushort stringCount, uint dataSize,
            [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] strings, IntPtr rawData);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeregisterEventSource(IntPtr handle);

        public static SafeFileHandle OpenFile(string path, bool write, bool delete, bool allowMissing) {
            uint access = 0x80000000u;
            if (write) access |= 0x40000000u;
            if (delete) access |= 0x00010000u;
            SafeFileHandle handle = CreateFileW(path, access, 0, IntPtr.Zero, 3, 0x00200000u, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                if (allowMissing && error == 2) return null;
                throw new Win32Exception(error);
            }
            return handle;
        }

        public static FileIdentity InspectFile(SafeFileHandle handle) {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & (0x10u | 0x400u)) != 0 || info.Links != 1)
                throw new InvalidOperationException("The test file is a directory, link or multiply linked file.");
            long creation = ((long)info.CreationHigh << 32) | info.CreationLow;
            long write = ((long)info.WriteHigh << 32) | info.WriteLow;
            return new FileIdentity {
                Id = String.Format("{0:X8}-{1:X8}-{2:X8}", info.VolumeSerial, info.IndexHigh, info.IndexLow),
                CreationTicks = DateTime.FromFileTimeUtc(creation).Ticks,
                WriteTicks = DateTime.FromFileTimeUtc(write).Ticks,
                Attributes = info.Attributes
            };
        }

        public static void MarkForDeletion(SafeFileHandle handle) {
            FileDisposition disposition = new FileDisposition { DeleteFile = 1 };
            if (!SetFileInformationByHandle(handle, 4, ref disposition, (uint)Marshal.SizeOf(disposition)))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public static SafeRegistryHandle CreateExclusive(SafeRegistryHandle parent, string name) {
            SafeRegistryHandle key;
            int disposition;
            int status = RegCreateKeyExW(parent, name, 0, null, 0, 0x2001F, IntPtr.Zero, out key, out disposition);
            if (status != 0) throw new Win32Exception(status);
            if (disposition != 1) {
                key.Dispose();
                throw new InvalidOperationException("The designated test registry key already exists.");
            }
            return key;
        }

        public static void WriteWarning(string source, int eventId, string message) {
            IntPtr handle = RegisterEventSourceW(null, source);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                if (!ReportEventW(handle, 2, 0, (uint)eventId, IntPtr.Zero, 1, 0,
                    new string[] { message }, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally {
                if (!DeregisterEventSource(handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Get-ArcDemoRegistryKeyName {
    param([string] $Path)
    return $Path.Substring('HKLM:\SOFTWARE\'.Length)
}

function Get-ArcDemoRegistrySnapshot {
    param([Microsoft.Win32.RegistryKey] $Key)

    $names = @($Key.GetValueNames())
    $hasValue = @($names | Where-Object { $_ -ieq 'DemoState' }).Count -eq 1
    $kind = if ($hasValue) { $Key.GetValueKind('DemoState').ToString() } else { 'Missing' }
    $value = if ($hasValue) {
        [string] $Key.GetValue('DemoState', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    else { '' }
    $security = [Microsoft.Win32.RegistryAclExtensions]::GetAccessControl($Key)
    return @{
        ValueCount = [string] $names.Count
        SubKeyCount = [string] $Key.SubKeyCount
        ValueKind = $kind
        Value = $value
        Acl = $security.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access -bor
            [System.Security.AccessControl.AccessControlSections]::Owner -bor
            [System.Security.AccessControl.AccessControlSections]::Group
        )
    }
}

function Get-ArcDemoRegistry {
    param([string] $Path)

    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $parent = $root.OpenSubKey('SOFTWARE', $false)
        if ($null -eq $parent) { throw 'The HKLM SOFTWARE registry parent could not be opened.' }
        try {
            $key = $parent.OpenSubKey((Get-ArcDemoRegistryKeyName -Path $Path), $false)
            if ($null -eq $key) { return $null }
            try { return (Get-ArcDemoRegistrySnapshot -Key $key) }
            finally { $key.Dispose() }
        }
        finally { $parent.Dispose() }
    }
    finally { $root.Dispose() }
}

function Invoke-ArcDemoRegistryCreation {
    param([string] $Path, [string] $Value)

    Initialize-ArcDemoNative
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $parent = $root.OpenSubKey('SOFTWARE', $true)
        if ($null -eq $parent) { throw 'The HKLM SOFTWARE registry parent could not be opened.' }
        try {
            $handle = [ArcSccmPoc.Native]::CreateExclusive($parent.Handle, (Get-ArcDemoRegistryKeyName -Path $Path))
            try {
                $key = [Microsoft.Win32.RegistryKey]::FromHandle($handle, [Microsoft.Win32.RegistryView]::Registry64)
                try { $key.SetValue('DemoState', $Value, [Microsoft.Win32.RegistryValueKind]::String) }
                finally { $key.Dispose() }
            }
            finally { $handle.Dispose() }
        }
        finally { $parent.Dispose() }
    }
    finally { $root.Dispose() }
}

function Invoke-ArcDemoRegistryChange {
    param([string] $Path, [System.Collections.IDictionary] $Expected, [string] $Value)

    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $key = $root.OpenSubKey(('SOFTWARE\' + (Get-ArcDemoRegistryKeyName -Path $Path)), $true)
        if ($null -eq $key) { throw 'The synthetic registry key no longer exists.' }
        try {
            Assert-ArcDemoSnapshot -Actual (Get-ArcDemoRegistrySnapshot -Key $key) -Expected $Expected -Kind 'registry'
            $key.SetValue('DemoState', $Value, [Microsoft.Win32.RegistryValueKind]::String)
        }
        finally { $key.Dispose() }
    }
    finally { $root.Dispose() }
}

function Invoke-ArcDemoRegistryRemoval {
    param([string] $Path, [System.Collections.IDictionary] $Expected)

    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $parent = $root.OpenSubKey('SOFTWARE', $true)
        if ($null -eq $parent) { throw 'The HKLM SOFTWARE registry parent could not be opened.' }
        try {
            $name = Get-ArcDemoRegistryKeyName -Path $Path
            $key = $parent.OpenSubKey($name, $false)
            if ($null -eq $key) { throw 'The synthetic registry key no longer exists.' }
            try { Assert-ArcDemoSnapshot -Actual (Get-ArcDemoRegistrySnapshot -Key $key) -Expected $Expected -Kind 'registry' }
            finally { $key.Dispose() }
            $parent.DeleteSubKey($name, $true)
        }
        finally { $parent.Dispose() }
    }
    finally { $root.Dispose() }
}

function Assert-ArcDemoEventSource {
    param([string] $Source)

    if ($Source -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,255}$') {
        throw 'The Application event source must be one literal source name.'
    }
    if (-not [System.Diagnostics.EventLog]::SourceExists($Source, '.')) {
        throw 'The selected Application event source is not registered; it will not be created.'
    }
    if ([System.Diagnostics.EventLog]::LogNameFromSourceName($Source, '.') -ine 'Application') {
        throw 'The selected event source is not registered to the Application log.'
    }
}

function Invoke-ArcDemoEvent {
    param([string] $Source, [int] $EventId, [string] $RunId)
    Assert-ArcDemoEventSource -Source $Source
    Initialize-ArcDemoNative
    [ArcSccmPoc.Native]::WriteWarning($Source, $EventId, "Synthetic Azure Arc PoC test; run $RunId.")
}

function Invoke-ArcDemoCpu {
    param([ValidateRange(1, 15)][int] $Seconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed -lt [TimeSpan]::FromSeconds($Seconds)) {
        [System.Threading.Thread]::SpinWait(10000)
    }
}

function Save-ArcDemoJournal {
    param([System.Collections.IDictionary] $Context, [System.Collections.IDictionary] $State)

    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $script:DiscoveryDirectory -LiteralPath $Context['StatePath']
    $directory = [System.IO.Path]::GetDirectoryName($Context['StatePath'])
    $temporary = New-ArcPrivateEvidenceFile -Directory $directory -FileName ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 30
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [System.IO.File]::Move($temporary, $Context['StatePath'], $true)
        Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $script:DiscoveryDirectory -LiteralPath $Context['StatePath']
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Invoke-ArcDemoJournalCreation {
    param([System.Collections.IDictionary] $Context, [System.Collections.IDictionary] $State)

    $directory = New-ArcPrivateEvidenceDirectory -DiscoveryDirectory $script:DiscoveryDirectory `
        -DirectoryName ('demo-' + $State['RunId'])
    $Context['StatePath'] = New-ArcPrivateEvidenceFile -Directory $directory -FileName 'state.json'
    $lockPath = New-ArcPrivateEvidenceFile -Directory $directory -FileName 'state.lock'
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $script:DiscoveryDirectory -LiteralPath $lockPath
    $Context['Lock'] = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    Save-ArcDemoJournal -Context $Context -State $State
}

function Open-ArcDemoJournal {
    param([System.Collections.IDictionary] $Context, [string] $Path)

    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $script:DiscoveryDirectory -LiteralPath $Path
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetFileName($fullPath) -cne 'state.json') {
        throw 'The private demo recovery file must be named state.json.'
    }
    $lockPath = Join-Path ([System.IO.Path]::GetDirectoryName($fullPath)) 'state.lock'
    Assert-ArcPrivateEvidenceInput -DiscoveryDirectory $script:DiscoveryDirectory -LiteralPath $lockPath
    $Context['StatePath'] = $fullPath
    $Context['Lock'] = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if ($item.Length -lt 2 -or $item.Length -gt 64KB) {
        throw 'The private demo recovery state has an invalid size.'
    }
    try { $json = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8) }
    catch { throw 'The private demo recovery state could not be read.' }
    return (ConvertFrom-ArcPrivateJson -Json $json -Label 'demo recovery state')
}

function Close-ArcDemoJournal {
    param([System.Collections.IDictionary] $Context)
    if ($null -ne $Context['Lock']) {
        $Context['Lock'].Dispose()
        $Context['Lock'] = $null
    }
}

function Get-ArcDemoWindowsAdapter {
    return @{
        AssertHost = { param($name) Assert-ArcDemoWindowsHost -ComputerName $name }
        AssertFilePath = { param($path) Assert-ArcDemoFilePath -Path $path }
        GetService = { param($name) Get-ArcDemoService -Name $name }
        GetFile = { param($path) Get-ArcDemoFile -Path $path }
        GetRegistry = { param($path) Get-ArcDemoRegistry -Path $path }
        NewJournal = { param($context, $state) Invoke-ArcDemoJournalCreation -Context $context -State $state }
        OpenJournal = { param($context, $path) Open-ArcDemoJournal -Context $context -Path $path }
        SaveJournal = { param($context, $state) Save-ArcDemoJournal -Context $context -State $state }
        CloseJournal = { param($context) Close-ArcDemoJournal -Context $context }
        CreateFile = { param($path, $text) Invoke-ArcDemoFileCreation -Path $path -Text $text }
        ChangeFile = { param($path, $snapshot, $text) Invoke-ArcDemoFileChange -Path $path -Expected $snapshot -Text $text }
        RemoveFile = { param($path, $snapshot) Invoke-ArcDemoFileRemoval -Path $path -Expected $snapshot }
        CreateRegistry = { param($path, $value) Invoke-ArcDemoRegistryCreation -Path $path -Value $value }
        ChangeRegistry = { param($path, $snapshot, $value) Invoke-ArcDemoRegistryChange -Path $path -Expected $snapshot -Value $value }
        RemoveRegistry = { param($path, $snapshot) Invoke-ArcDemoRegistryRemoval -Path $path -Expected $snapshot }
        StopService = { param($name, $identity) Invoke-ArcDemoServiceControl -Name $name -Identity $identity -Action 'Stop' }
        StartService = { param($name, $identity) Invoke-ArcDemoServiceControl -Name $name -Identity $identity -Action 'Start' }
        AssertEventSource = { param($source) Assert-ArcDemoEventSource -Source $source }
        WriteEvent = { param($source, $id, $runId) Invoke-ArcDemoEvent -Source $source -EventId $id -RunId $runId }
        RunCpu = { param($seconds) Invoke-ArcDemoCpu -Seconds $seconds }
    }
}

Export-ModuleMember -Function Get-ArcDemoWindowsAdapter
