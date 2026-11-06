#Requires -Version 7.4
Set-StrictMode -Version Latest

function Assert-ArcUnixOwner {
    param([string] $LiteralPath, [string] $Description)

    $idCommand = Get-Command id -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $statCommand = Get-Command stat -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $currentUser = @(& $idCommand.Source -u 2>$null)
    if ($LASTEXITCODE -ne 0 -or $currentUser.Count -ne 1 -or $currentUser[0] -notmatch '^\d+$') {
        throw 'The current Unix user could not be verified.'
    }
    if ($IsLinux) {
        $owner = @(& $statCommand.Source -c '%u' -- $LiteralPath 2>$null)
    }
    elseif ($IsMacOS) {
        $owner = @(& $statCommand.Source -f '%u' $LiteralPath 2>$null)
    }
    else {
        throw 'Unix ownership verification is unsupported on this operating system.'
    }
    if ($LASTEXITCODE -ne 0 -or $owner.Count -ne 1 -or $owner[0] -ne $currentUser[0]) {
        throw "The $Description must be owned by the current user."
    }
}

function Assert-ArcPrivateDirectory {
    param([Parameter(Mandatory)][string] $LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'The private evidence directory must be a real directory, not a link.'
    }

    if ($IsWindows) {
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $LiteralPath -ErrorAction Stop
        $aclOwner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $ownerRules = @($rules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -eq $owner.Value -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl -and
                ($_.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -and
                ($_.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)
            })
        $otherAllows = @($rules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -ne $owner.Value
            })
        if ($aclOwner.Value -ne $owner.Value -or -not $acl.AreAccessRulesProtected -or
            $ownerRules.Count -eq 0 -or $otherAllows.Count -gt 0) {
            throw 'The private evidence directory must be owned by the current user and grant access only to that user.'
        }
    }
    else {
        $privateMode = [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
        if ([System.IO.File]::GetUnixFileMode($LiteralPath) -ne $privateMode) {
            throw 'The private evidence directory must have owner-only mode 700.'
        }
        Assert-ArcUnixOwner -LiteralPath $LiteralPath -Description 'private evidence directory'
    }
}

function New-ArcRestrictedDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)][string] $LiteralPath)

    if (-not $PSCmdlet.ShouldProcess($LiteralPath, 'Create an owner-only evidence directory')) {
        throw 'Private evidence directory creation was skipped.'
    }
    if ($IsWindows) {
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($owner)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $owner, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'
            ))
        [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($LiteralPath), $security)
    }
    else {
        $privateMode = [System.IO.UnixFileMode]::UserRead -bor
            [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
        $null = [System.IO.Directory]::CreateDirectory($LiteralPath, $privateMode)
    }
    Assert-ArcPrivateDirectory -LiteralPath $LiteralPath
}

function New-ArcPrivateEvidenceDirectory {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string] $DiscoveryDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*$')][string] $DirectoryName
    )

    $outputRoot = Join-Path $DiscoveryDirectory 'output'
    if (Test-Path -LiteralPath $outputRoot) {
        Assert-ArcPrivateDirectory -LiteralPath $outputRoot
    }

    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $DiscoveryDirectory '../..'))
    $relativePath = "scripts/discovery/output/$DirectoryName/evidence.json"
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Git is required to verify that private evidence is ignored.'
    }
    & git -C $repoRoot check-ignore --no-index --quiet -- $relativePath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Private evidence is not confirmed as Git-ignored. No evidence was written.'
    }

    $directory = Join-Path $outputRoot $DirectoryName
    if (-not $PSCmdlet.ShouldProcess($directory, 'Prepare a private evidence directory')) {
        throw 'Private evidence directory creation was skipped.'
    }
    if (Test-Path -LiteralPath $outputRoot) {
        Assert-ArcPrivateDirectory -LiteralPath $outputRoot
    }
    else {
        New-ArcRestrictedDirectory -LiteralPath $outputRoot
    }

    if (Test-Path -LiteralPath $directory) {
        throw 'The private evidence directory already exists. No evidence was written.'
    }
    New-ArcRestrictedDirectory -LiteralPath $directory
    return $directory
}

function New-ArcPrivateEvidenceFile {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')][string] $FileName
    )

    Assert-ArcPrivateDirectory -LiteralPath $Directory
    $path = Join-Path $Directory $FileName
    if (-not $PSCmdlet.ShouldProcess($path, 'Create an owner-only evidence file')) {
        throw 'Private evidence file creation was skipped.'
    }
    $stream = $null
    $created = $false
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $created = $true
        if (-not $IsWindows) {
            $privateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            [System.IO.File]::SetUnixFileMode($path, $privateMode)
            if ([System.IO.File]::GetUnixFileMode($path) -ne $privateMode) {
                throw 'Private file permissions could not be verified.'
            }
        }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
        if ($created) { Remove-Item -LiteralPath $path -ErrorAction Stop }
        throw 'The private evidence file could not be created securely without overwriting an existing file.'
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $path
}

function Assert-ArcPrivateEvidenceInput {
    param(
        [Parameter(Mandatory)][string] $DiscoveryDirectory,
        [Parameter(Mandatory)][string] $LiteralPath
    )

    $outputRoot = [System.IO.Path]::GetFullPath((Join-Path $DiscoveryDirectory 'output'))
    $path = [System.IO.Path]::GetFullPath($LiteralPath)
    $directory = [System.IO.Path]::GetDirectoryName($path)
    $parent = [System.IO.Path]::GetDirectoryName($directory)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($parent, $outputRoot, $comparison)) {
        throw 'Private input must be a file in a dedicated discovery output directory.'
    }

    Assert-ArcPrivateDirectory -LiteralPath $outputRoot
    Assert-ArcPrivateDirectory -LiteralPath $directory
    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch { throw 'The private input file could not be read. Check its path and permissions.' }
    $linkType = $item.PSObject.Properties['LinkType']
    if ($null -eq $linkType) {
        throw 'The private input file link type could not be verified.'
    }
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        $linkType.Value) {
        throw 'The private input must be a real, single-link file, not a link.'
    }

    if ($IsWindows) {
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
        $aclOwner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier])
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $ownerCanRead = @($rules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -eq $owner.Value -and
                ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::ReadData)
            }).Count -gt 0
        $otherAllows = @($rules | Where-Object {
                $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -ne $owner.Value
            })
        if ($aclOwner.Value -ne $owner.Value -or -not $ownerCanRead -or $otherAllows.Count -gt 0) {
            throw 'The private input file must be owned and readable only by the current user.'
        }
    }
    else {
        $privateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        if ([System.IO.File]::GetUnixFileMode($path) -ne $privateMode) {
            throw 'The private input file must have owner-only mode 600.'
        }
        Assert-ArcUnixOwner -LiteralPath $path -Description 'private input file'
    }

    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $DiscoveryDirectory '../..'))
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $path)
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Git is required to verify that private input is ignored and untracked.'
    }
    & git -C $repoRoot check-ignore --no-index --quiet -- $relativePath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Private input is not confirmed as Git-ignored.'
    }
    & git -C $repoRoot ls-files --error-unmatch -- $relativePath *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Private input must not be tracked by Git.' }
    if ($LASTEXITCODE -ne 1) { throw 'Git could not verify that private input is untracked.' }
}

function Get-ArcPrivateFileHash {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)]
        [ValidateSet('discovery report', 'stage parameters', 'baseline report', 'alert configuration')]
        [string] $Label
    )
    try { return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { throw "The $Label could not be read for hashing. Check its path and permissions." }
}

function ConvertFrom-ArcPrivateJsonElement {
    param([System.Text.Json.JsonElement] $Element, [string] $Label)

    switch ($Element.ValueKind) {
        Object {
            $values = [ordered]@{}
            $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) {
                    throw "The $Label contains duplicate JSON fields."
                }
                $values[$property.Name] = ConvertFrom-ArcPrivateJsonElement -Element $property.Value -Label $Label
            }
            return $values
        }
        Array {
            $values = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $values.Add((ConvertFrom-ArcPrivateJsonElement -Element $item -Label $Label))
            }
            return ,$values.ToArray()
        }
        String { return $Element.GetString() }
        Number {
            $integer = [long] 0
            if ($Element.TryGetInt64([ref] $integer)) { return $integer }
            return $Element.GetDouble()
        }
        True { return $true }
        False { return $false }
        Null { return $null }
        default { throw "The $Label contains an unsupported JSON value." }
    }
}

function ConvertFrom-ArcPrivateJson {
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][ValidateSet('alert configuration', 'demo recovery state', 'stage parameters')][string] $Label
    )

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 100
    try { $document = [System.Text.Json.JsonDocument]::Parse($Json, $options) }
    catch { throw "The private $Label could not be read as valid JSON." }
    try { return (ConvertFrom-ArcPrivateJsonElement -Element $document.RootElement -Label $Label) }
    finally { $document.Dispose() }
}

Export-ModuleMember -Function New-ArcPrivateEvidenceDirectory, New-ArcPrivateEvidenceFile, `
    Assert-ArcPrivateEvidenceInput, Get-ArcPrivateFileHash, ConvertFrom-ArcPrivateJson
