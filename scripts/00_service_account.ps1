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

    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new("BUILTIN\Administrators", $full, $inh, $none, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new("NT AUTHORITY\SYSTEM",    $full, $inh, $none, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($SvcUsername,             $read, $inh, $none, $allow))
    Set-Acl -Path $Path -AclObject $acl
    Write-DebugLog "INFO" "Secrets ACL applied: inheritance broken, Admins=Full, SYSTEM=Full, $SvcUsername=Read"
}

# -- 4. Grant access to InstallDir (already exists) ---------------------------
Write-Host "  -> Granting '$SvcUser' access to install directory..." -ForegroundColor Gray
$installDir = $Config.General.InstallDir
Write-DebugLog "INFO" "Granting $SvcUser FullControl on InstallDir=$installDir"
Grant-SeedboxDirAccess -Path $installDir -Username $SvcUser

Write-Host "[ServiceAccount] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "00_service_account.ps1 complete"
$global:SeedboxSvcAccountConfigured = $true
