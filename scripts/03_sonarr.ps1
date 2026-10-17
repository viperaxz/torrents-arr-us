param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")

# Bounded service control: nssm services wedge in Stop/Start Pending and the
# built-in cmdlets wait indefinitely. See service_helpers.ps1.
if (-not (Get-Command Start-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "03_sonarr.ps1 started"

# -- config.xml helpers --------------------------------------------------------
# PowerShell's XML adapter cannot create a missing element by assignment (it
# throws "property cannot be found"), and it hands back an element's text rather
# than the node itself, so RemoveChild($xml.Config.UrlBase) fails. Both the
# restore re-align and the post-first-run alignment below need to add or drop
# nodes, so they go through these helpers.
function Set-ConfigXmlValue {
    param([System.Xml.XmlDocument]$Xml, [string]$Name, [string]$Value)
    $node = $Xml.Config.SelectSingleNode($Name)
    if ($node) { $node.InnerText = $Value }
    else {
        $node = $Xml.CreateElement($Name)
        $node.InnerText = $Value
        $Xml.Config.AppendChild($node) | Out-Null
    }
}

function Remove-ConfigXmlValue {
    param([System.Xml.XmlDocument]$Xml, [string]$Name)
    $node = $Xml.Config.SelectSingleNode($Name)
    if ($node) { $Xml.Config.RemoveChild($node) | Out-Null }
}

function Test-ZipArchive {
    # A download interrupted mid-transfer leaves a truncated file in bin/, and the
    # cache lookup runs before the download on every later run -- so a partial zip
    # would be retried forever instead of being fetched again.
    param([string]$Path)
    try {
        if (-not ("System.IO.Compression.ZipFile" -as [type])) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        }
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { $entryCount = $archive.Entries.Count } finally { $archive.Dispose() }
        return ($entryCount -gt 0)
    } catch {
        Write-DebugLog "WARN" "Zip validation failed for '$Path': $_"
        return $false
    }
}

$AppName     = "Sonarr"
$AppLower    = "sonarr"
$AppPort     = $Config.Ports.Sonarr
$InstallDir  = $Config.General.InstallDir
$AppBinDir   = Join-Path $InstallDir $AppName
$DataDir     = "C:\ProgramData\$AppName"
$LockFile    = Join-Path $InstallDir ".locks\.$AppLower.lock"
$DomainMode  = $Config.General.DomainMode
$SvcUser     = "seedbox-svc"
$SvcPass     = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort"
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR DomainMode=$DomainMode SvcUser=$SvcUser"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Sonarr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Sonarr != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# 1. Download (cached in bin/  --  API only called when nothing is cached)
$BinDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR BinDir=$BinDir (exists=$(Test-Path $BinDir))"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Sonarr) { $Config._Versions.Apps.Sonarr.version } else { $null }
$AssetPattern  = if ($Config._Versions -and $Config._Versions.Apps.Sonarr) { $Config._Versions.Apps.Sonarr.asset } else { "*win-x64.zip" }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetPattern=$AssetPattern"

# Look for a version-specific cached zip; fall back to any cached zip when no version is pinned
$VersionNumeric = if ($PinnedVersion) { $PinnedVersion.TrimStart('v') } else { $null }
$CachedZip = if ($VersionNumeric) {
    Get-ChildItem $BinDir -Filter "$AppName*$VersionNumeric*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
} else {
    Get-ChildItem $BinDir -Filter "$AppName.*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-DebugLog "VAR cached zip found=$($null -ne $CachedZip) name=$($CachedZip.Name)"

# Validate a cached zip before trusting it: an interrupted download leaves a
# truncated file behind and the cache is consulted before GitHub on every run.
if ($CachedZip -and -not (Test-ZipArchive -Path $CachedZip.FullName)) {
    Write-Warning "  -> Cached $($CachedZip.Name) is incomplete. Removing it and downloading again."
    Write-DebugLog "WARN" "Cached zip failed validation, deleting: $($CachedZip.FullName)"
    Remove-Item -Path $CachedZip.FullName -Force -ErrorAction SilentlyContinue
    $CachedZip = $null
}

if ($CachedZip) {
    Write-Host "  -> Using cached $($CachedZip.Name)..." -ForegroundColor Gray
    $ZipPath = $CachedZip.FullName
    Write-DebugLog "INFO" "Using cached zip: $ZipPath"
} else {
    $ApiUri = if ($PinnedVersion) {
        "https://api.github.com/repos/Sonarr/Sonarr/releases/tags/$PinnedVersion"
    } else {
        "https://api.github.com/repos/Sonarr/Sonarr/releases/latest"
    }
    $displayVer = if ($PinnedVersion) { $PinnedVersion } else { "latest" }
    Write-Host "  -> Fetching $AppName release $displayVer..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API: $ApiUri"
    try {
        $Release = Invoke-RestMethod -Uri $ApiUri -UseBasicParsing
        Write-DebugLog "VAR GitHub release tag=$($Release.tag_name) assets=$($Release.assets.Count)"
    } catch {
        Write-Error "[$AppName] Failed to query GitHub releases: $_"
        Write-DebugLog "ERROR" "GitHub API query failed: $_"
        exit 1
    }
    $Asset = $Release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    Write-DebugLog "VAR selected asset=$($Asset.name) url=$($Asset.browser_download_url)"
    if (-not $Asset) {
        Write-Error "[$AppName] No matching asset ('$AssetPattern') in release $($Release.tag_name)."
        Write-DebugLog "ERROR" "No asset matching '$AssetPattern' in release $($Release.tag_name)"
        exit 1
    }
    $ZipPath = Join-Path $BinDir $Asset.name
    Write-Host "  -> Downloading $AppName $($Release.tag_name)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Downloading $($Asset.browser_download_url) -> $ZipPath"
    try {
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        # Never leave a partial file in the cache: the cached-zip branch above runs
        # first on the next attempt, so a truncated download would be reused and
        # every later run would die in Expand-Archive instead of downloading again.
        if (Test-Path $ZipPath) { Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue }
        Write-Warning "  -> Download failed: $_"
        Write-DebugLog "ERROR" "Download failed from $($Asset.browser_download_url): $_"
        exit 1
    }
    $zipSize = (Get-Item $ZipPath).Length
    Write-DebugLog "INFO" "Download complete. File=$ZipPath size=$zipSize bytes"
    if (-not $PinnedVersion) { $PinnedVersion = $Release.tag_name }
}

# 3. Extract
if (-not (Test-Path $AppBinDir)) {
    New-Item -Path $AppBinDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created AppBinDir: $AppBinDir"
}
Write-Host "  -> Extracting..." -ForegroundColor Gray
Write-DebugLog "INFO" "Extracting $ZipPath -> $AppBinDir"
try {
    Expand-Archive -Path $ZipPath -DestinationPath $AppBinDir -Force -ErrorAction Stop
} catch {
    # A cached zip can be corrupt past its central directory (the part Test-ZipArchive
    # checks); drop it so the next run re-downloads rather than failing on the same
    # file forever.
    Write-Warning "  -> Extraction failed: $_"
    Write-DebugLog "ERROR" "Extraction failed for '$ZipPath': $_"
    if (Test-Path $ZipPath) { Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue }
    exit 1
}
Write-DebugLog "INFO" "Extraction complete"

# The release zip wraps everything in a single "Sonarr" folder. Flatten it, the
# way 09_bazarr.ps1 and 10_flaresolverr.ps1 do, because update_sonarr.ps1 swaps
# this directory with Swap-AppDirectoryWithRollback -- which flattens
# single-directory zips. Leaving the install nested meant the registered NSSM
# Application (<InstallDir>\Sonarr\Sonarr\Sonarr.exe) stopped existing after the
# first update, so the new build could never start.
$NestedExe = Join-Path $AppBinDir "$AppName\$AppName.exe"
if ((Test-Path $NestedExe) -and -not (Test-Path (Join-Path $AppBinDir "$AppName.exe"))) {
    $NestedDir = Join-Path $AppBinDir $AppName
    Write-DebugLog "INFO" "Flattening single-directory archive: $NestedDir -> $AppBinDir"
    Get-ChildItem -Path $NestedDir -Force | ForEach-Object { Move-Item -Path $_.FullName -Destination $AppBinDir -Force }
    Remove-Item -Path $NestedDir -Recurse -Force
    Write-DebugLog "INFO" "Archive flattened"
}

$AppExe = Get-ChildItem -Path $AppBinDir -Recurse -Filter "$AppName.exe" | Select-Object -First 1
Write-DebugLog "VAR AppExe=$($AppExe.FullName)"
if (-not $AppExe) {
    Write-Error "[$AppName] $AppName.exe not found after extraction."
    Write-DebugLog "ERROR" "$AppName.exe not found in $AppBinDir after extraction"
    exit 1
}

# 4. Data directory
Write-DebugLog "VAR DataDir=$DataDir (exists=$(Test-Path $DataDir))"
if (-not (Test-Path $DataDir)) { New-Item -Path $DataDir -ItemType Directory -Force | Out-Null }
Grant-SeedboxDirAccess -Path $DataDir -Username $SvcUser

# 4b. Restore Sonarr data from previous install -------------------------------
# The uninstaller saved sonarr.db* + config.xml to
# %LOCALAPPDATA%\win-seedbox\arr-backup\sonarr. Restore before the service
# first starts so Sonarr boots with the old library intact.
$ArrBackupDir = Join-Path $env:LOCALAPPDATA "win-seedbox\arr-backup\sonarr"
$ArrDbFile    = Join-Path $DataDir "sonarr.db"
Write-DebugLog "VAR ArrBackupDir=$ArrBackupDir (exists=$(Test-Path $ArrBackupDir))"
Write-DebugLog "VAR target sonarr.db exists=$(Test-Path $ArrDbFile)"
if ((Test-Path $ArrBackupDir) -and -not (Test-Path $ArrDbFile)) {
    Write-Host "  -> Restoring Sonarr data from previous install..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Restoring Sonarr data from $ArrBackupDir -> $DataDir"
    try {
        Copy-Item -Path (Join-Path $ArrBackupDir "*") -Destination $DataDir -Force -ErrorAction Stop
    } catch {
        # SilentlyContinue used to hide this, and the backup was deleted regardless.
        Write-Warning "  -> Could not restore Sonarr data from '$ArrBackupDir': $_"
        Write-DebugLog "ERROR" "Sonarr data restore failed: $_"
    }

    # Re-align the restored config.xml with the current config.json: the
    # port and URL base may have changed since the backup was taken.
    $ConfigXml = Join-Path $DataDir "config.xml"
    if (Test-Path $ConfigXml) {
        try {
            [xml]$xml = Get-Content -Path $ConfigXml -Encoding UTF8
            Set-ConfigXmlValue -Xml $xml -Name "Port" -Value ([string]$AppPort)
            if ($DomainMode -eq "duckdns") {
                Set-ConfigXmlValue -Xml $xml -Name "UrlBase" -Value "/$AppLower"
            } else {
                # A backup taken in DuckDNS mode still carries UrlBase=/sonarr; it must
                # not survive a Cloudflare-mode reinstall. Remove the node (not the
                # text) -- see Remove-ConfigXmlValue.
                Remove-ConfigXmlValue -Xml $xml -Name "UrlBase"
            }
            $xml.Save($ConfigXml)
            Write-DebugLog "INFO" "Restored config.xml re-aligned: port=$AppPort"
        } catch {
            # Write-DebugLog is a no-op unless General.DebugLogging is on, so warn
            # on the console too: an unaligned config.xml (wrong port / stale
            # UrlBase) leaves Sonarr unreachable through Caddy and no other step
            # re-checks it.
            Write-Warning "  -> Could not re-align the restored config.xml: $_"
            Write-DebugLog "WARN" "config.xml re-align failed: $_"
        }
    }

    # Keep the only copy of the previous library until the restore demonstrably
    # worked: deleting it after a failed Copy-Item destroys the user's shows with
    # no way back. sonarr.db is what the restore was for.
    if (Test-Path $ArrDbFile) {
        Remove-Item -Path $ArrBackupDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-DebugLog "INFO" "Sonarr backup cleaned up after restore"
    } else {
        Write-Warning "  -> Restore did not produce sonarr.db. Keeping the backup at $ArrBackupDir"
        Write-DebugLog "WARN" "Restore did not produce $ArrDbFile -- backup left in place at $ArrBackupDir"
    }
} elseif (Test-Path $ArrBackupDir) {
    Write-DebugLog "INFO" "Sonarr backup found but sonarr.db already exists -- skip restore"
} else {
    Write-DebugLog "INFO" "No Sonarr data backup found"
}

# 5. Windows service via NSSM
Write-Host "  -> Creating Windows service..." -ForegroundColor Gray
$ExistingService = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $ExistingService)"
if (-not $ExistingService) {
    Write-DebugLog "INFO" "Creating NSSM service '$AppName' exe=$($AppExe.FullName)"
    nssm install $AppName "`"$($AppExe.FullName)`"" | Out-Null
    nssm set $AppName AppParameters "-nobrowser -data=`"$DataDir`"" | Out-Null
    nssm set $AppName Description "$AppName PVR Service" | Out-Null
    nssm set $AppName AppDirectory "$($AppExe.DirectoryName)" | Out-Null
    nssm set $AppName Start SERVICE_AUTO_START | Out-Null
    nssm set $AppName AppStdout (Join-Path $DataDir "$AppLower.log") | Out-Null
    nssm set $AppName AppStderr (Join-Path $DataDir "$AppLower.log") | Out-Null
    nssm set $AppName AppRotateFiles 1 | Out-Null
    nssm set $AppName AppRotateBytes 5242880 | Out-Null
    nssm set $AppName ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    Write-DebugLog "INFO" "NSSM service '$AppName' created. AppDirectory=$($AppExe.DirectoryName)"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists. Skipping creation."
    # Keep the registered path in step with the directory just extracted: the
    # archive is flattened above, so a service left over from an older (nested)
    # install would still point at <AppName>\<AppName>\<AppName>.exe, which no
    # longer exists, and the service would fail to start.
    $nssmCmd = (Get-Command nssm -ErrorAction SilentlyContinue).Source
    if ($nssmCmd) {
        $nssmCurrentApp = (& $nssmCmd get $AppName Application 2>$null | Out-String).Trim().Trim('"')
        if ($nssmCurrentApp -ne $AppExe.FullName) {
            Write-Host "  -> Re-pointing existing $AppName service at $($AppExe.FullName)..." -ForegroundColor Gray
            Write-DebugLog "INFO" "NSSM Application re-pointed: '$nssmCurrentApp' -> '$($AppExe.FullName)'"
            & $nssmCmd set $AppName Application $AppExe.FullName | Out-Null
            & $nssmCmd set $AppName AppDirectory $AppExe.DirectoryName | Out-Null
        }
    } else {
        Write-Warning "  -> nssm not found on PATH; cannot verify the exe path registered for the existing $AppName service."
        Write-DebugLog "WARN" "nssm not found on PATH; existing $AppName service path not verified"
    }
}

# 6. Firewall
# LAN-scoped on purpose. Caddy reaches this app over loopback (exempt from the
# firewall), so a world-open rule would only serve to expose the app's own login
# page directly on :$AppPort -- bypassing Caddy's basic-auth AND CrowdSec, which
# can only see attacks that appear in the Caddy access log.
# Remove any previous rule first: duplicates with the same DisplayName are allowed,
# so they would otherwise accumulate on every install run.
Get-NetFirewallRule -DisplayName "$AppName" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "$AppName" -Direction Inbound -LocalPort $AppPort -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for $AppName port=$AppPort"

# 7. Start + wait for config.xml creation
Write-Host "  -> Starting $AppName (waiting for first-run config)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName service. Waiting up to 90s for config.xml..."
$null = Start-ServiceBounded -Name $AppName
$ConfigXml = Join-Path $DataDir "config.xml"
$deadline  = (Get-Date).AddSeconds(90)
$waited    = 0
while (-not (Test-Path $ConfigXml) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $waited += 3
}
Write-DebugLog "VAR config.xml created=$(Test-Path $ConfigXml) waited=${waited}s"

# 8. Align config.xml with config.json (port always, UrlBase per domain mode)
# Sonarr writes config.xml itself on first run, always on its default port 8989.
# Only the restore path above used to apply Ports.Sonarr, so a fresh install with
# a non-default port created the firewall rule and every Caddy/Layer 1/Layer 2
# URL on the configured port while the app kept listening on 8989. In DuckDNS
# mode UrlBase=/sonarr must be present; in Cloudflare mode it must not be.
if (Test-Path $ConfigXml) {
    $desiredUrlBase = if ($DomainMode -eq "duckdns") { "/$AppLower" } else { "" }
    $alignPort      = $true
    $alignUrlBase   = $true
    try {
        [xml]$currentXml = Get-Content -Path $ConfigXml -Encoding UTF8
        $alignPort    = ([string]$currentXml.Config.Port) -ne ([string]$AppPort)
        $alignUrlBase = ([string]$currentXml.Config.UrlBase) -ne $desiredUrlBase
        Write-DebugLog "VAR config.xml port='$($currentXml.Config.Port)' UrlBase='$([string]$currentXml.Config.UrlBase)' desiredPort=$AppPort desiredUrlBase='$desiredUrlBase'"
    } catch {
        # Cannot read it -> rewrite both; the edit below reports the real reason.
        Write-DebugLog "WARN" "Could not read $ConfigXml before aligning it: $_"
    }

    if (-not $alignPort -and -not $alignUrlBase) {
        Write-DebugLog "INFO" "config.xml already aligned: port=$AppPort UrlBase='$desiredUrlBase'"
    } else {
        Write-DebugLog "INFO" "Aligning config.xml in $DomainMode mode: port=$AppPort UrlBase='$desiredUrlBase' (portChange=$alignPort urlBaseChange=$alignUrlBase)"
        $null = Stop-ServiceBounded -Name $AppName
        # Stop-ServiceBounded returns as soon as the SCM reports Stopped, which can be
        # before the NSSM-managed process has actually released its files, and a
        # process that is still shutting down rewrites config.xml on its way out,
        # discarding the edit made below. Wait for the service to report Stopped, the
        # same way configure_layer1_sonarr.ps1 waits before restoring its config backup.
        $stopDeadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Seconds 1
            $svcStopping = Get-Service -Name $AppName -ErrorAction SilentlyContinue
        } while ($svcStopping -and $svcStopping.Status -ne "Stopped" -and (Get-Date) -lt $stopDeadline)
        Write-DebugLog "VAR $AppName status after stop wait=$(if ($svcStopping) { $svcStopping.Status } else { 'N/A' })"
        try {
            [xml]$xml = Get-Content -Path $ConfigXml -Encoding UTF8
            $beforeUrlBase = [string]$xml.Config.UrlBase
            Write-DebugLog "VAR config.xml UrlBase before='$beforeUrlBase'"
            Set-ConfigXmlValue -Xml $xml -Name "Port" -Value ([string]$AppPort)
            if ($desiredUrlBase) {
                Set-ConfigXmlValue -Xml $xml -Name "UrlBase" -Value $desiredUrlBase
            } else {
                Remove-ConfigXmlValue -Xml $xml -Name "UrlBase"
            }
            $xml.Save($ConfigXml)
            if ($desiredUrlBase) {
                Write-Host "  -> config.xml aligned: port $AppPort, UrlBase $desiredUrlBase (DuckDNS mode)." -ForegroundColor Green
            } else {
                Write-Host "  -> config.xml aligned: port $AppPort, no UrlBase (Cloudflare mode)." -ForegroundColor Green
            }
            Write-DebugLog "INFO" "config.xml aligned: port=$AppPort UrlBase '$beforeUrlBase' -> '$desiredUrlBase'"
        } catch {
            Write-Warning "  -> Could not align config.xml: $_"
            Write-DebugLog "ERROR" "config.xml alignment failed: $_"
        }
        $null = Start-ServiceBounded -Name $AppName
        Write-DebugLog "INFO" "$AppName restarted after config.xml change"

        # Verify the edit survived the restart. Without UrlBase Sonarr answers only on
        # "/" while Caddy sends every request to "/sonarr", so a lost edit makes the app
        # unreachable through the proxy -- worth a warning rather than a silent success.
        Start-Sleep -Seconds 3
        try {
            [xml]$verifyXml = Get-Content -Path $ConfigXml -Encoding UTF8
            $verifyPort    = [string]$verifyXml.Config.Port
            $verifyUrlBase = [string]$verifyXml.Config.UrlBase
            if ($verifyPort -ne [string]$AppPort) {
                Write-Warning "  -> config.xml Port is '$verifyPort' (expected '$AppPort'). Sonarr will not answer on port $AppPort."
                Write-DebugLog "WARN" "Port verification failed: got '$verifyPort' (expected '$AppPort')"
            } elseif ($verifyUrlBase -ne $desiredUrlBase) {
                Write-Warning "  -> config.xml UrlBase is '$verifyUrlBase' (expected '$desiredUrlBase')."
                Write-DebugLog "WARN" "UrlBase verification failed: got '$verifyUrlBase' (expected '$desiredUrlBase')"
            } else {
                Write-DebugLog "INFO" "config.xml verification OK: port=$AppPort UrlBase='$desiredUrlBase'"
            }
        } catch {
            Write-DebugLog "WARN" "config.xml verification could not read config.xml: $_"
        }
    }
} else {
    # Without config.xml there is no API key to read and no port/UrlBase to set, so
    # Layer 1 cannot configure the app and Caddy has nothing reachable to proxy to.
    # Record nothing and fail: writing the lock here made the failure permanent,
    # because every later run then reported "Already installed. Skipping.".
    Write-Warning "  -> config.xml not found after 90s. Port and UrlBase not aligned."
    Write-DebugLog "ERROR" "config.xml not generated within 90s; lock file and ledger NOT written so a re-run retries"
    exit 1
}

# 9. Validate
Start-Sleep -Seconds 3
# NSSM keeps the service on LocalSystem if the "nssm set ObjectName" call above
# failed, which silently bypasses the service-isolation model (and the ACLs that
# grant seedbox-svc -- not LocalSystem administrators -- access to data and logs).
$svcAccount = (Get-CimInstance Win32_Service -Filter "Name='$AppName'" -ErrorAction SilentlyContinue).StartName
if ($svcAccount -and $svcAccount -notlike "*seedbox-svc*") {
    Write-Warning "  -> $AppName runs as '$svcAccount' (expected '.\seedbox-svc'). Check the nssm ObjectName setting."
    Write-DebugLog "WARN" "$AppName service account is '$svcAccount', expected .\seedbox-svc"
}
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    # Do NOT record success for a service that never started. Writing the lock file
    # and the ledger entry here made a broken app permanent: the next
    # master_install.ps1 run saw "Already installed. Skipping." and never repaired it.
    # Leaving both unwritten means a re-run genuinely retries, and exit 1 makes
    # master_install.ps1 report this app FAILED -- it continues with the other apps
    # and skips only this app's configure step.
    Write-Host "  -> $AppName did NOT reach Running. Not recording it as installed." -ForegroundColor Red
    Write-Warning "  -> $AppName failed to start. Check $DataDir\$AppLower.log"
    Write-DebugLog "ERROR" "$AppName did not reach Running (status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })); lock file and ledger NOT written so a re-run retries"
    exit 1
}

# 10. Lock file (stores installed version for update comparison)
$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, (New-Object System.Text.UTF8Encoding($false)))
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $LockVersion

Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "03_sonarr.ps1 complete"
