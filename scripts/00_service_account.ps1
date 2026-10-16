param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Guard: when dot-sourced by other scripts for helper functions, skip the
#    full account setup (user creation, secedit, etc.) which is already done.
if ($global:SeedboxSvcAccountConfigured) {
    return
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "00_service_account.ps1 started"

$SvcUser = "seedbox-svc"
$SvcPass = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR SvcUser=$SvcUser"
Write-DebugLog "VAR SvcPass=[REDACTED]"
Write-DebugLog "VAR InstallDir=$($Config.General.InstallDir)"

if ([string]::IsNullOrWhiteSpace($SvcPass) -or $SvcPass -eq "Svc@Seedbox2024!") {
    Write-Warning "[ServiceAccount] ServiceAccountPassword is using the default value. Set a unique password in config.json before deploying."
    Write-DebugLog "WARN" "ServiceAccountPassword is default or blank"
}

Write-Host "[ServiceAccount] Configuring service account '$SvcUser'..." -ForegroundColor Cyan

# -- 1. Create local user if not present --------------------------------------
$existingUser = Get-LocalUser -Name $SvcUser -ErrorAction SilentlyContinue
Write-DebugLog "VAR user '$SvcUser' already exists=$(($null -ne $existingUser))"
if (-not $existingUser) {
    Write-DebugLog "INFO" "Creating local user '$SvcUser'..."
    $securePass = ConvertTo-SecureString $SvcPass -AsPlainText -Force
    New-LocalUser -Name $SvcUser `
                  -Password $securePass `
                  -PasswordNeverExpires `
                  -UserMayNotChangePassword `
                  -Description "Seedbox service account - no interactive logon" | Out-Null
    Write-Host "  -> User '$SvcUser' created." -ForegroundColor Green
    Write-DebugLog "INFO" "Local user '$SvcUser' created successfully"
} else {
    # Update password in case it changed
    try {
        $securePass = ConvertTo-SecureString $SvcPass -AsPlainText -Force
        Set-LocalUser -Name $SvcUser -Password $securePass -ErrorAction Stop
        Write-Host "  -> User '$SvcUser' already exists; password updated." -ForegroundColor Green
        Write-DebugLog "INFO" "Local user '$SvcUser' exists; password updated"
    } catch {
        Write-Warning "  -> Could not update password for '$SvcUser': $_"
        Write-Warning "     The existing account will be used with its current password."
        Write-Warning "     If the password in config.json differs, services may fail to start."
        Write-DebugLog "ERROR" "Set-LocalUser failed for '$SvcUser': $_"
    }
}

# Ensure NOT a member of Administrators or Users groups.
# Use well-known SIDs instead of localized names:
#   S-1-5-32-544 = Administrators
#   S-1-5-32-545 = Users
# On non-English Windows editions the built-in group names are translated, so
# Remove-LocalGroupMember -Group "Users" would fail with "group not found" on a
# French/German/etc. system. The SIDs are identical on every language.
$groupSids = @(
    @{ Sid = "S-1-5-32-544"; Name = "Administrators" }
    @{ Sid = "S-1-5-32-545"; Name = "Users" }
)
foreach ($grp in $groupSids) {
    $grpName = $grp.Name
    Write-DebugLog "VAR removing '$SvcUser' from group '$grpName'..."
    try {
        $grpObj = Get-LocalGroup | Where-Object { $_.SID.Value -eq $grp.Sid } | Select-Object -First 1
        if (-not $grpObj) {
            Write-DebugLog "VAR local group with SID $($grp.Sid) not found on this system; skipping"
            continue
        }
        Remove-LocalGroupMember -Group $grpObj.Name -Member $SvcUser -ErrorAction Stop | Out-Null
        Write-Host "  -> Removed '$SvcUser' from '$($grpObj.Name)'." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Removed '$SvcUser' from '$($grpObj.Name)'"
    } catch {
        Write-DebugLog "VAR '$SvcUser' was not in group '$grpName' (skip)"
        <# not a member, fine #>
    }
}

# -- 2. Grant SeServiceLogonRight + SeBatchLogonRight via secedit --------------
Write-Host "  -> Granting service logon rights..." -ForegroundColor Gray
Write-DebugLog "INFO" "Resolving SID for '$SvcUser'..."

$sid     = (New-Object System.Security.Principal.NTAccount($SvcUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$tmpInf  = [System.IO.Path]::Combine($env:TEMP, "seedbox_secedit.inf")
$tmpDb   = [System.IO.Path]::Combine($env:TEMP, "seedbox_secedit.sdb")

Write-DebugLog "VAR SID=$sid"
Write-DebugLog "VAR tmpInf=$tmpInf"
Write-DebugLog "VAR tmpDb=$tmpDb"

Write-DebugLog "INFO" "Exporting local security policy via secedit..."
secedit /export /cfg $tmpInf /quiet 2>$null

$lines      = [System.IO.File]::ReadAllLines($tmpInf)
Write-DebugLog "VAR secedit export line count=$($lines.Count)"
$foundRights = @{}

# Build patched INF  --  avoid Write-DebugLog inside the pipeline-capture block
# (function calls with side-effects inside foreach-assignment can confuse the parser)
$rightsLog = [System.Collections.Generic.List[string]]::new()
$newLines = foreach ($line in $lines) {
    if ($line -match "^(SeServiceLogonRight|SeBatchLogonRight)\s*=\s*(.*)") {
        $right    = $Matches[1]
        $existing = $Matches[2].Trim()
        $foundRights[$right] = $true
        if ($existing -like "*$sid*") {
            $rightsLog.Add("INFO: '$right' already contains SID $sid")
            $line
        } else {
            $entry   = "*$sid"
            $newLine = if ($existing) { "$right = $existing,$entry" } else { "$right = $entry" }
            $rightsLog.Add("INFO: '$right' updated to include SID $sid")
            $newLine
        }
    } else {
        $line
    }
}
foreach ($logEntry in $rightsLog) { Write-DebugLog $logEntry }

# On fresh installs the rights may be absent from the export entirely  --  inject them
$missing = @("SeServiceLogonRight", "SeBatchLogonRight") | Where-Object { -not $foundRights[$_] }
Write-DebugLog "VAR missing privilege rights in export=$($missing -join ', ')"
if ($missing) {
    $result   = [System.Collections.Generic.List[string]]::new()
    $injected = $false
    foreach ($line in $newLines) {
        $result.Add($line)
        if ($line -match '^\[Privilege Rights\]' -and -not $injected) {
            foreach ($right in $missing) {
                $result.Add("$right = *$sid")
                Write-DebugLog "VAR injecting '$right = *$sid' under [Privilege Rights]"
            }
            $injected = $true
        }
    }
    if (-not $injected) {
        $result.Add(""); $result.Add("[Privilege Rights]")
        foreach ($right in $missing) {
            $result.Add("$right = *$sid")
            Write-DebugLog "VAR injecting '$right = *$sid' (new [Privilege Rights] section)"
        }
    }
    $newLines = $result.ToArray()
}

Write-DebugLog "INFO" "Writing patched secedit INF and applying..."
[System.IO.File]::WriteAllLines($tmpInf, $newLines, [System.Text.Encoding]::Unicode)
secedit /configure /db $tmpDb /cfg $tmpInf /quiet 2>$null
Write-DebugLog "INFO" "secedit /configure exit code=$LASTEXITCODE"
Remove-Item $tmpInf, $tmpDb -Force -ErrorAction SilentlyContinue
Write-DebugLog "INFO" "Temp secedit files removed"

Write-Host "  -> SeServiceLogonRight and SeBatchLogonRight granted." -ForegroundColor Green
Write-DebugLog "INFO" "SeServiceLogonRight + SeBatchLogonRight granted to $SvcUser (SID=$sid)"

# -- 3. ACL helper (exported for use by other scripts) ------------------------
# Each app installer calls Grant-SeedboxDirAccess after creating its data dir.
function global:Grant-SeedboxDirAccess {
    param(
        [string]$Path,
        [string]$Username = "seedbox-svc",
        [string]$Rights   = "FullControl"
    )
    Write-DebugLog "INFO" "Grant-SeedboxDirAccess: path=$Path user=$Username rights=$Rights"
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-DebugLog "INFO" "Created directory for ACL: $Path"
    }
    $acl  = Get-Acl -Path $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Username, $Rights,
                "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
    Write-DebugLog "INFO" "ACL applied: $Username -> $Rights on $Path"
}

# Install-tree lockdown helper.
#
# Everything under InstallDir is ours: binaries that run as seedbox-svc or
# LocalSystem (Alloy/Loki/Grafana), plus credential files (secrets\, Zurg's
# config.yml). A drive root (D:\ or C:\) hands every child created without an
# explicit DACL "Authenticated Users: Modify" + "Everyone: ReadAndExecute", so
# by default any local user could rewrite those binaries (local privilege
# escalation to seedbox-svc/LocalSystem) or rename InstallDir and recreate it
# with their own ACL, after which the next install writes secrets into a
# directory they control.
#
# This applies the C:\Program Files model instead: Administrators + SYSTEM +
# seedbox-svc FullControl, Authenticated Users read-only (which keeps
# non-elevated reads such as `box check` working). Media directories that live
# under InstallDir are re-opened for shared write so file management over
# Explorer/SMB keeps working exactly as before.
function global:Set-SeedboxInstallTreeAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SvcUsername = "seedbox-svc",
        [string[]]$SharedWritePaths = @()
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-DebugLog "INFO" "Created install directory for ACL: $Path"
    }

    # Well-known SIDs: the localized names of these groups do not resolve on
    # every Windows language, SIDs always do.
    $sidAdmins   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $sidSystem   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $sidAuthUser = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
    $sidSvc      = $null
    try {
        $sidSvc = (New-Object System.Security.Principal.NTAccount($SvcUsername)).Translate([System.Security.Principal.SecurityIdentifier])
        Write-DebugLog "VAR service account SID: $SvcUsername = $($sidSvc.Value)"
    } catch {
        Write-Warning "  -> Could not resolve service account '$SvcUsername' -- its ACE will not be applied to $Path."
        Write-DebugLog "WARN" "Unresolvable service account '$SvcUsername': $_"
    }

    $full   = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $read   = [System.Security.AccessControl.FileSystemRights]"Read,ReadAndExecute,ListDirectory"
    $modify = [System.Security.AccessControl.FileSystemRights]"Modify"
    $inh    = "ContainerInherit,ObjectInherit"
    $none   = "None"
    $allow  = [System.Security.AccessControl.AccessControlType]::Allow

    # Bits that let a principal replace binaries or forge data: write data,
    # append data, write EA, write attributes, create/delete, delete-child,
    # WRITE_DAC, WRITE_OWNER.
    $writeBits = 0xD0156
    # Principals nobody means to give write access to the service tree.
    $broadSids = @("S-1-1-0", "S-1-5-11", "S-1-5-32-545", "S-1-5-32-546", "S-1-5-4", "S-1-5-2", "S-1-5-7")

    function Get-AceSidValue($identity) {
        try { return $identity.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $null }
    }

    try {
        $acl = Get-Acl -LiteralPath $Path

        # Report exactly which write access is about to disappear.
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne $allow) { continue }
            if (([int]$rule.FileSystemRights -band $writeBits) -eq 0) { continue }
            $rid = Get-AceSidValue $rule.IdentityReference
            if ($rid -eq $sidAdmins.Value -or $rid -eq $sidSystem.Value) { continue }
            if ($sidSvc -and $rid -eq $sidSvc.Value) { continue }
            $origin = if ($rule.IsInherited) { ", inherited" } else { ", explicit" }
            Write-Host "  -> Closing write access on $Path : $($rule.IdentityReference) ($($rule.FileSystemRights)$origin)" -ForegroundColor DarkGray
        }

        # Break inheritance (drops the drive-root grants) and drop any explicit
        # writable ACE held by a broad principal.
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne $allow) { continue }
            if (([int]$rule.FileSystemRights -band $writeBits) -eq 0) { continue }
            $rid = Get-AceSidValue $rule.IdentityReference
            if ($rid -eq $sidAdmins.Value -or $rid -eq $sidSystem.Value) { continue }
            if ($sidSvc -and $rid -eq $sidSvc.Value) { continue }
            if ($rid -and ($broadSids -contains $rid)) {
                if ($acl.RemoveAccessRule($rule)) {
                    Write-Host "  -> Removed writable ACE '$($rule.IdentityReference)' ($($rule.FileSystemRights)) on $Path" -ForegroundColor Yellow
                    Write-DebugLog "INFO" "Removed explicit writable ACE $($rule.IdentityReference)=$($rule.FileSystemRights) on $Path"
                }
            } else {
                Write-Warning "  -> $Path : '$($rule.IdentityReference)' keeps write access ($($rule.FileSystemRights)) -- that principal can replace service binaries in this tree."
                Write-DebugLog "WARN" "Explicit write ACE kept on $Path for $($rule.IdentityReference)"
            }
        }

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins,   $full, $inh, $none, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem,   $full, $inh, $none, $allow)))
        if ($sidSvc) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSvc,  $full, $inh, $none, $allow)))
        }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAuthUser, $read, $inh, $none, $allow)))
        Set-Acl -LiteralPath $Path -AclObject $acl

        $svcLabel = if ($sidSvc) { ", $SvcUsername Full" } else { "" }
        Write-Host "  -> $Path locked down (Administrators/SYSTEM$svcLabel, Authenticated Users read-only)." -ForegroundColor Green
        Write-Host "     A non-administrator account that must still write here needs an explicit grant:" -ForegroundColor DarkGray
        Write-Host "     icacls `"$Path`" /grant `"<account>:(OI)(CI)(M)`"" -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Install tree ACL applied on $Path (Administrators/SYSTEM$svcLabel Full, Authenticated Users Read)"
    } catch {
        Write-Warning "  -> Could not lock down '$Path': $_"
        Write-DebugLog "ERROR" "Set-SeedboxInstallTreeAcl failed on $Path : $_"
    }

    # Media libraries that live under InstallDir must stay writable by normal
    # users (Explorer/SMB file management, downloads uploads). Media paths
    # outside InstallDir are left exactly as the operator set them up.
    $rootFull = $null
    try { $rootFull = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\') } catch { $rootFull = $null }
    foreach ($mediaPath in $SharedWritePaths) {
        if ([string]::IsNullOrWhiteSpace($mediaPath)) { continue }
        if (-not (Test-Path -LiteralPath $mediaPath)) {
            Write-DebugLog "VAR media path not present yet, ACL unchanged: $mediaPath"
            continue
        }
        $mediaFull = (Get-Item -LiteralPath $mediaPath).FullName.TrimEnd('\')
        if (-not $rootFull -or $mediaFull -ieq $rootFull) {
            Write-Warning "  -> Media path '$mediaFull' is the install directory itself -- leaving it locked down."
            continue
        }
        if (-not $mediaFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "  -> Media path outside the install directory, left untouched: $mediaFull" -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Media path outside InstallDir, untouched: $mediaFull"
            continue
        }
        try {
            $mediaAcl = Get-Acl -LiteralPath $mediaFull
            $mediaAcl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($mediaAcl.Access)) { $mediaAcl.RemoveAccessRule($rule) | Out-Null }
            $mediaAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmins,   $full,   $inh, $none, $allow)))
            $mediaAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSystem,   $full,   $inh, $none, $allow)))
            if ($sidSvc) {
                $mediaAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidSvc,  $full,   $inh, $none, $allow)))
            }
            $mediaAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sidAuthUser, $modify, $inh, $none, $allow)))
            Set-Acl -LiteralPath $mediaFull -AclObject $mediaAcl
            Write-Host "  -> Media path keeps shared write access: $mediaFull" -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Media path re-opened for shared write (Authenticated Users Modify): $mediaFull"
        } catch {
            Write-Warning "  -> Could not set ACL on media path '$mediaFull': $_"
            Write-DebugLog "WARN" "Media path ACL failed on $mediaFull : $_"
        }
    }
}

# ACL helper for the secrets directory: removes inherited permissions,
# grants only Administrators (FullControl) + seedbox-svc (Read) + SYSTEM (FullControl).
function global:Set-SecretsDirAcl {
    param([string]$Path, [string]$SvcUsername = "seedbox-svc")
    Write-DebugLog "INFO" "Set-SecretsDirAcl: path=$Path svcUser=$SvcUsername"
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-DebugLog "INFO" "Created secrets directory: $Path"
    }
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)       # break inheritance, discard inherited rules
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

    $full = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $read = [System.Security.AccessControl.FileSystemRights]"Read,ReadAndExecute,ListDirectory"
    $inh  = "ContainerInherit,ObjectInherit"
    $none = "None"
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    # Well-known SIDs: the localized names of these groups do not resolve on
    # every Windows language, SIDs always do.
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")

    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sidAdmins, $full, $inh, $none, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sidSystem, $full, $inh, $none, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($SvcUsername, $read, $inh, $none, $allow))
    Set-Acl -Path $Path -AclObject $acl
    Write-DebugLog "INFO" "Secrets ACL applied: inheritance broken, Admins=Full, SYSTEM=Full, $SvcUsername=Read"
}

# -- 4. Lock down the install tree --------------------------------------------
# Replaces a plain "give seedbox-svc FullControl" grant: the tree is created
# under a drive root, so it would otherwise inherit Everyone:ReadAndExecute and
# Authenticated Users:Modify -- write access to service binaries and credentials
# for every local user.
Write-Host "  -> Locking down install directory..." -ForegroundColor Gray
$installDir = $Config.General.InstallDir

$sharedWritePaths = @()
if ($Config.PSObject.Properties['Paths'] -and $Config.Paths) {
    foreach ($pathKey in @("Downloads", "Movies", "TV")) {
        if ($Config.Paths.PSObject.Properties[$pathKey] -and $Config.Paths.$pathKey) {
            $sharedWritePaths += [string]$Config.Paths.$pathKey
        }
    }
}
Write-DebugLog "VAR InstallDir ACL target=$installDir sharedWritePaths=$($sharedWritePaths -join ', ')"

$projectRoot = Split-Path -Parent $PSScriptRoot
if ($projectRoot -and $installDir -and
    $projectRoot.TrimEnd('\').StartsWith($installDir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "  -> The project directory lives inside InstallDir ($projectRoot); config.json and the scripts will also become administrator-only."
}

Set-SeedboxInstallTreeAcl -Path $installDir -SvcUsername $SvcUser -SharedWritePaths $sharedWritePaths

Write-Host "[ServiceAccount] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "00_service_account.ps1 complete"
$global:SeedboxSvcAccountConfigured = $true
