param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at '$configPath'. Pass -Config or run from the project root."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_jellyfin_libraries.ps1 started"

$AppName      = "Jellyfin"
$Port         = $Config.Ports.Jellyfin
$Enabled      = $Config.Apps.Jellyfin -eq $true
$Layer2Config = $Config.Layer2.Jellyfin

$DomainMode   = $Config.General.DomainMode
$BaseUrl      = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
$ApiBase      = "http://127.0.0.1:$Port$BaseUrl"
$Client       = 'MediaBrowser Client="JellyfinConfig", Device="JellyfinConfig", DeviceId="JellyfinConfig001", Version="1.0.0"'
$Username     = $Config.General.AdminUsername
$Password     = $Config.General.AdminPassword

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled DomainMode=$DomainMode"
Write-DebugLog "VAR BaseUrl=$BaseUrl ApiBase=$ApiBase"
Write-DebugLog "VAR AdminUsername=$Username AdminPassword=[REDACTED]"

if (-not $Enabled) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

if (-not $Layer2Config -or $Layer2Config.MediaLibraries.Count -eq 0) {
    Write-Host "  [WARN] No Layer2 config found for $AppName media libraries. Skipping." -ForegroundColor Yellow
    Write-DebugLog "WARN" "No media libraries configured for $AppName"
    return
}

Write-DebugLog "VAR MediaLibraries=$($Layer2Config.MediaLibraries.Count)"

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -Name "JellyfinServer" -ErrorAction SilentlyContinue
if (-not $svc) {
    $svc = Get-Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*jellyfin*" -or $_.DisplayName -like "*jellyfin*" } |
           Select-Object -First 1
}
Write-DebugLog "VAR Jellyfin service found=$($null -ne $svc) name=$(if ($svc) { $svc.Name } else { 'N/A' }) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Jellyfin service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting Jellyfin service '$($svc.Name)'..."
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

# -- 2. Wait for API -----------------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$pingUrl = "$ApiBase/System/Info/Public"
Write-DebugLog "INFO" "Polling Jellyfin API at $pingUrl (up to 180s)..."
$apiUp = $false
$deadline = (Get-Date).AddSeconds(180)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $pingUrl `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR Jellyfin API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName] API not responding after 180s. Skipping."
    Write-DebugLog "ERROR" "Jellyfin API not responding after 180s"
    exit 1
}

# -- 3. Get authentication token -----------------------------------------------
Write-Host "  -> Authenticating..." -ForegroundColor Gray
Write-DebugLog "INFO" "Authenticating as '$Username'..."
$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json -Compress
$authResp = $null
try {
    $authResp = Invoke-RestMethod -Uri "$ApiBase/Users/AuthenticateByName" -Method Post `
        -Body $authBody -ContentType "application/json" `
        -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR Authentication succeeded. Token length=$($authResp.AccessToken.Length)"
} catch {
    Write-Warning "[$AppName] Authentication failed: $_"
    Write-DebugLog "ERROR" "Authentication failed: $_"
    exit 1
}

if (-not $authResp.AccessToken) {
    Write-Warning "[$AppName] No access token in response."
    Write-DebugLog "ERROR" "No access token in auth response"
    exit 1
}

$Token    = $authResp.AccessToken
$UserAuth = @{"X-MediaBrowser-Token" = $Token; "Authorization" = $Client}
Write-DebugLog "VAR UserAuth token=[REDACTED] length=$($Token.Length)"

# -- 4. Get existing libraries -------------------------------------------------
Write-Host "  -> Configuring media libraries..." -ForegroundColor Gray
Write-DebugLog "INFO" "Fetching existing Jellyfin libraries..."
$existingLibs = @()
try {
    $libsResp     = Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders" `
        -Headers $UserAuth -UseBasicParsing -ErrorAction Stop
    $existingLibs = $libsResp
    Write-DebugLog "VAR existing libraries=$($existingLibs.Count) names=$($existingLibs.Name -join ',')"
} catch {
    Write-DebugLog "WARN" "Could not retrieve existing libraries: $_"
}

# -- 5. Create or update media libraries --------------------------------------
$rdEnabled = $Config.Apps.RealDebrid -eq $true
foreach ($lib in $Layer2Config.MediaLibraries) {
    $libName = $lib.Name
    $libPath = $lib.Path
    $libType = $lib.Type

    # Skip RD/Lean libraries when RealDebrid is not enabled (Zurg/rclone not installed, drive letter missing)
    $isLean = $lib.PSObject.Properties['Lean'] -and $lib.Lean
    if ($isLean -and -not $rdEnabled) {
        Write-Host "  [SKIP] Library '$libName' ($libType) -> $libPath  -- RealDebrid is not enabled" -ForegroundColor DarkGray
        Write-DebugLog "WARN" "Skipping Lean library '$libName' (RealDebrid not enabled)"
        continue
    }

    # Skip libraries pointing to a non-existent Windows drive root (e.g. R:\)
    if ($libPath -match '^[A-Za-z]:\\?$' -and -not (Test-Path $libPath)) {
        Write-Host "  [SKIP] Library '$libName' ($libType) -> $libPath  -- drive does not exist" -ForegroundColor DarkGray
        Write-DebugLog "WARN" "Skipping library '$libName' (drive $libPath does not exist)"
        continue
    }

    $exists = $existingLibs | Where-Object { $_.Name -eq $libName }
    Write-DebugLog "VAR library '$libName' exists=$($null -ne $exists) type=$libType path=$libPath"

    if ($exists) {
        # Library exists  --  ensure the configured path is present and remove stale ones.
        $existingPaths = @($exists.Locations)
        Write-DebugLog "VAR library '$libName' existing paths=$($existingPaths -join ',')"

        if ($existingPaths -notcontains $libPath) {
            try {
                $pathDto = @{ Name = $libName; Path = $libPath } | ConvertTo-Json -Compress
                Write-DebugLog "INFO" "Adding path '$libPath' to library '$libName'..."
                Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders/Paths?refreshLibrary=false" -Method Post `
                    -Body $pathDto -ContentType "application/json" -Headers $UserAuth -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     OK Added path to library '${libName}': $libPath" -ForegroundColor Green
                Write-DebugLog "INFO" "Path added to library '$libName': $libPath"
            } catch {
                Write-Warning "     Failed to add path to library '${libName}': $_"
                Write-DebugLog "ERROR" "Failed to add path '$libPath' to library '$libName': $_"
            }
        } else {
            Write-Host "     Library '$libName' already has path: $libPath" -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Library '$libName' already has path $libPath -- skip"
        }

        # Remove any paths that are no longer in the config (stale paths from previous installs).
        foreach ($stalePath in $existingPaths) {
            if ($stalePath -ne $libPath) {
                try {
                    $encodedName = [Uri]::EscapeDataString($libName)
                    $encodedPath = [Uri]::EscapeDataString($stalePath)
                    Write-DebugLog "INFO" "Removing stale path '$stalePath' from library '$libName'..."
                    Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders/Paths?name=$encodedName&path=$encodedPath&refreshLibrary=false" `
                        -Method Delete -Headers $UserAuth -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     OK Removed stale path from '${libName}': $stalePath" -ForegroundColor Yellow
                    Write-DebugLog "INFO" "Stale path removed from library '$libName': $stalePath"
                } catch {
                    Write-DebugLog "WARN" "Could not remove stale path '$stalePath' from '$libName': $_"
                }
            }
        }
    } else {
        try {
            $jellyfinType = switch ($libType) {
                "movies"       { "movies" }
                "tvshows"      { "tvshows" }
                "music"        { "music" }
                "musicvideos"  { "musicvideos" }
                default        { "tvshows" }
            }

            # -- Build Lean LibraryOptions ----------------------------------------
            $lean = $lib.PSObject.Properties['Lean'] -and $lib.Lean
            $disableVideo  = $lean -and $lib.Lean.PSObject.Properties['DisableVideoExtraction'] -and ($lib.Lean.DisableVideoExtraction -eq $true)
            $disableMeta   = $lean -and $lib.Lean.PSObject.Properties['DisableMetadata']        -and ($lib.Lean.DisableMetadata        -eq $true)
            $disableImages = $lean -and ($lib.Lean.PSObject.Properties['DisableImages']          -and ($lib.Lean.DisableImages          -eq $true))

            Write-DebugLog "VAR creating library '$libName' jellyfinType=$jellyfinType path=$libPath lean=$lean disableVideo=$disableVideo disableMeta=$disableMeta disableImages=$disableImages"

            $libOptions = [ordered]@{
                PathInfos = @( @{ Path = $libPath } )
            }

            if ($disableVideo) {
                $libOptions['EnableChapterImageExtraction']          = $false
                $libOptions['ExtractChapterImagesDuringLibraryScan'] = $false
                $libOptions['EnableTrickplay']                       = $false
            }

            # Build TypeOptions only when metadata or image fetchers need disabling
            if ($disableMeta -or $disableImages) {
                $itemTypes = if ($jellyfinType -eq "movies") {
                    @("Movie")
                } else {
                    @("Series", "Season", "Episode")
                }
                $typeOptions = foreach ($t in $itemTypes) {
                    $entry = [ordered]@{ Type = $t }
                    if ($disableMeta)   { $entry['MetadataFetchers'] = @(); $entry['MetadataFetcherOrder'] = @() }
                    if ($disableImages) { $entry['ImageFetchers']    = @(); $entry['ImageFetcherOrder']    = @(); $entry['ImageOptions'] = @() }
                    $entry
                }
                $libOptions['TypeOptions'] = @($typeOptions)
            }

            $leanNote = if ($lean) {
                $flags = @()
                if ($disableVideo)  { $flags += "NoVideoExtraction" }
                if ($disableMeta)   { $flags += "NoMetadata" }
                if ($disableImages) { $flags += "NoImages" }
                if ($flags) { " [Lean: $($flags -join ',')]" } else { " [Lean]" }
            } else { "" }

            $libPayload = @{ LibraryOptions = $libOptions } | ConvertTo-Json -Depth 8 -Compress

            Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders?name=$([Uri]::EscapeDataString($libName))&collectionType=$jellyfinType&refreshLibrary=false" -Method Post `
                -Body $libPayload `
                -ContentType "application/json" `
                -Headers $UserAuth `
                -UseBasicParsing -ErrorAction Stop | Out-Null

            Write-Host "     OK Created library: $libName ($libType)$leanNote -> $libPath" -ForegroundColor Green
            Write-DebugLog "INFO" "Library '$libName' created (type=$jellyfinType path=$libPath$leanNote)"
        } catch {
            Write-Warning "     Failed to create library '$libName': $_"
            Write-DebugLog "ERROR" "Failed to create library '$libName': $_"
        }
    }
}

# -- 5b. Trigger library scan for drive-root libraries (e.g. R:\) --------------
# Libraries backed by rclone mounts (Real-Debrid) may appear empty if Jellyfin
# starts before the mount is ready at boot time.  A scan during install -- when
# the mount is confirmed available -- populates them immediately and ensures
# future restarts do not skip the library because it was previously "empty".
Write-Host "  -> Triggering library scan for mount-backed libraries..." -ForegroundColor Gray
Write-DebugLog "INFO" "Checking for drive-root libraries that need an immediate scan..."
$scannedCount = 0
# Re-read the current virtual folders to get ItemIds for libraries we just created/updated.
try {
    $currentLibs = Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders" `
        -Headers $UserAuth -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR current library count=$($currentLibs.Count)"
} catch {
    Write-DebugLog "WARN" "Could not re-read virtual folders: $_"
    $currentLibs = @()
}
foreach ($lib in $Layer2Config.MediaLibraries) {
    $libName = $lib.Name
    $libPath = $lib.Path
    # Only scan libraries whose path is a drive root (e.g. R:\) -- these are
    # rclone mounts that we know are ready right now but may not be at boot.
    if ($libPath -match '^[A-Za-z]:\\?$') {
        # Test-Path alone can be true while the mount root still cannot serve
        # directory listings (rclone + Zurg warming up). Verify the drive really
        # lists before scanning, otherwise Jellyfin records the library as empty
        # and skips it until its next scheduled scan.
        $driveReady    = $false
        $driveDeadline = (Get-Date).AddSeconds(60)
        while (-not $driveReady -and (Get-Date) -lt $driveDeadline) {
            try {
                $null = Get-ChildItem -Path $libPath -ErrorAction Stop
                $driveReady = $true
            } catch {
                Start-Sleep -Seconds 3
            }
        }
        if ($driveReady) {
            # Find the library ItemId from the current virtual folders list
            $vf = $currentLibs | Where-Object { $_.Name -eq $libName } | Select-Object -First 1
            if ($vf -and $vf.ItemId) {
                Write-DebugLog "VAR drive-root library '$libName' ItemId=$($vf.ItemId) path '$libPath' is accessible -- triggering scan"
                try {
                    $scanBody = @{ Name = 'RefreshLibrary'; LibraryId = $vf.ItemId } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri "$ApiBase/Library/Refresh" -Method Post `
                        -Body $scanBody -ContentType "application/json" `
                        -Headers $UserAuth -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     OK Triggered scan for library '$libName' ($libPath)" -ForegroundColor Green
                    Write-DebugLog "INFO" "Scan triggered for library '$libName' (ItemId=$($vf.ItemId), path=$libPath)"
                    $scannedCount++
                } catch {
                    Write-Warning "     Failed to trigger scan for library '$libName': $_"
                    Write-DebugLog "ERROR" "Failed to trigger scan for '$libName': $_"
                }
            } else {
                Write-DebugLog "WARN" "drive-root library '$libName' not found in virtual folders -- cannot trigger scan"
            }
        } else {
            Write-DebugLog "WARN" "drive-root library '$libName' path '$libPath' is NOT accessible -- skipping scan"
            Write-Host "  [SKIP] Library '$libName' ($libPath) drive not accessible, scan deferred." -ForegroundColor DarkGray
        }
    }
}
if ($scannedCount -eq 0) {
    Write-DebugLog "INFO" "No drive-root libraries to scan"
}

# -- 6. Create persistent API key for Sonarr/Radarr notifications --------------
$SecretsDir      = Join-Path $Config.General.InstallDir "secrets"
$JellyfinKeyFile = Join-Path $SecretsDir "jellyfin_api_key.txt"
Write-DebugLog "VAR SecretsDir=$SecretsDir JellyfinKeyFile=$JellyfinKeyFile"

Write-Host "  -> Creating Jellyfin API key for Sonarr/Radarr integration..." -ForegroundColor Gray
if (Test-Path $JellyfinKeyFile) {
    Write-Host "     API key file already exists  --  reusing." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Jellyfin API key file already exists  --  skipping creation"
} elseif (-not (Test-Path $SecretsDir)) {
    Write-Warning "     Secrets directory not found at '$SecretsDir'. Skipping API key creation."
    Write-DebugLog "WARN" "Secrets directory not found at $SecretsDir"
} else {
    try {
        $getKey = {
            ((Invoke-WebRequest -Uri "$ApiBase/Auth/Keys" -Headers $UserAuth -UseBasicParsing -ErrorAction Stop).Content |
             ConvertFrom-Json).Items |
            Where-Object { $_.AppName -eq "Seedbox-Integration" } |
            Sort-Object DateCreated | Select-Object -Last 1
        }

        Write-DebugLog "INFO" "Checking for existing Seedbox-Integration API key..."
        $apiKeyEntry = & $getKey
        Write-DebugLog "VAR existing Seedbox-Integration key found=$($null -ne $apiKeyEntry)"
        if (-not $apiKeyEntry) {
            Write-DebugLog "INFO" "Creating Seedbox-Integration API key in Jellyfin..."
            Invoke-RestMethod -Uri "$ApiBase/Auth/Keys?app=Seedbox-Integration" `
                -Method Post -Headers $UserAuth -UseBasicParsing -ErrorAction Stop | Out-Null
            $apiKeyEntry = & $getKey
        }

        if ($apiKeyEntry -and $apiKeyEntry.AccessToken) {
            [System.IO.File]::WriteAllText($JellyfinKeyFile, $apiKeyEntry.AccessToken,
                [System.Text.UTF8Encoding]::new($false))
            Write-Host "     [OK] Jellyfin API key saved for Sonarr/Radarr integration." -ForegroundColor Green
            Write-DebugLog "INFO" "Jellyfin API key saved to $JellyfinKeyFile [REDACTED]"
        } else {
            Write-Warning "     Could not retrieve Jellyfin API key from /Auth/Keys list."
            Write-DebugLog "WARN" "Could not retrieve Jellyfin API key from /Auth/Keys"
        }
    } catch {
        Write-Warning "     Failed to create Jellyfin API key: $_"
        Write-DebugLog "ERROR" "Jellyfin API key creation failed: $_"
    }
}

# -- 7. Install OpenSubtitles plugin -------------------------------------------
$OsLayer2        = $Config.Layer2.OpenSubtitles
$OsBazarr        = $Config.Layer2.Bazarr
$OsUser          = if ($OsLayer2.Username)                       { $OsLayer2.Username }                       `
                   elseif ($OsBazarr.OpenSubtitlesComUsername)   { $OsBazarr.OpenSubtitlesComUsername }   `
                   else { "" }
$OsPass          = if ($OsLayer2.Password)                       { $OsLayer2.Password }                       `
                   elseif ($OsBazarr.OpenSubtitlesComPassword)   { $OsBazarr.OpenSubtitlesComPassword }   `
                   else { "" }
$PluginsDir      = "C:\ProgramData\Jellyfin\Server\plugins"

Write-Host "  -> Installing OpenSubtitles plugin for Jellyfin..." -ForegroundColor Gray
Write-DebugLog "INFO" "Checking OpenSubtitles plugin in $PluginsDir"

$dllFound    = Get-ChildItem -Path $PluginsDir -Filter "*.dll" -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*OpenSubtitles*" } | Select-Object -First 1
$needInstall = -not $dllFound
Write-DebugLog "VAR OpenSubtitles plugin dll found=$($null -ne $dllFound) needInstall=$needInstall"

if (-not $needInstall) {
    Write-Host "     OpenSubtitles plugin already installed." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "OpenSubtitles plugin already installed"
} else {
    try {
        # Resolve installed Jellyfin version so we download a compatible plugin version.
        # The Jellyfin plugin catalog lists each release's targetAbi (minimum Jellyfin version).
        # We pick the highest plugin version whose targetAbi <= installed Jellyfin version.
        $jellyfinVer = $null
        try {
            $sysInfo     = Invoke-RestMethod -Uri "$ApiBase/System/Info/Public" -UseBasicParsing -ErrorAction Stop
            $jellyfinVer = $sysInfo.Version
        } catch {
            Write-DebugLog "WARN" "Could not determine Jellyfin version for plugin compat check: $_"
        }

        $pluginDownloadUrl = $null
        $pluginTagName     = $null

        if ($jellyfinVer) {
            Write-DebugLog "INFO" "Installed Jellyfin $jellyfinVer. Querying plugin catalog for compatible OpenSubtitles version..."
            try {
                $catalogUrl = "https://repo.jellyfin.org/files/plugin/manifest.json"
                $catalog    = Invoke-RestMethod -Uri $catalogUrl -UseBasicParsing -ErrorAction Stop
                $osGuid     = "4b9ed42f-5185-48b5-9803-6ff2989014c4"
                $osEntry    = $catalog | Where-Object { $_.guid -eq $osGuid } | Select-Object -First 1
                if ($osEntry) {
                    $compatible = $osEntry.versions | Where-Object {
                        try { [version]$_.targetAbi -le [version]$jellyfinVer } catch { $false }
                    } | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
                    if ($compatible) {
                        $pluginTagName     = "v$($compatible.version)"
                        $pluginDownloadUrl = $compatible.sourceUrl
                        Write-DebugLog "VAR plugin catalog: selected $pluginTagName (targetAbi=$($compatible.targetAbi)) for Jellyfin $jellyfinVer"
                    } else {
                        Write-DebugLog "WARN" "No compatible OpenSubtitles version found in catalog for Jellyfin $jellyfinVer"
                    }
                }
            } catch {
                Write-DebugLog "WARN" "Plugin catalog query failed: $_. Falling back to GitHub latest."
            }
        }

        # Fallback: GitHub latest (may be incompatible with older Jellyfin)
        if (-not $pluginDownloadUrl) {
            Write-DebugLog "INFO" "Fetching latest OpenSubtitles plugin release from GitHub..."
            $ghHeaders   = @{ "User-Agent" = "win-seedbox-installer" }
            $releaseInfo = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/jellyfin/jellyfin-plugin-opensubtitles/releases/latest" `
                -Headers $ghHeaders -UseBasicParsing -ErrorAction Stop
            $ghAsset = $releaseInfo.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
            if ($ghAsset) {
                $pluginTagName     = $releaseInfo.tag_name
                $pluginDownloadUrl = $ghAsset.browser_download_url
            }
        }

        if (-not $pluginDownloadUrl) {
            Write-Warning "     Could not resolve an OpenSubtitles plugin download URL."
            Write-DebugLog "WARN" "No OpenSubtitles download URL resolved"
            $needInstall = $false
        } else {
            $pluginVersion = $pluginTagName -replace '^v', ''
            $pluginDir     = Join-Path $PluginsDir "open-subtitles_$pluginVersion"
            Write-DebugLog "VAR pluginDir=$pluginDir pluginVersion=$pluginVersion"
            if (-not (Test-Path $pluginDir)) { New-Item -ItemType Directory -Path $pluginDir -Force | Out-Null }

            $zipPath = Join-Path $env:TEMP "jellyfin-opensubtitles.zip"
            Write-DebugLog "INFO" "Downloading $pluginDownloadUrl -> $zipPath"
            Invoke-WebRequest -Uri $pluginDownloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipPath -DestinationPath $pluginDir -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

            Write-Host "     OpenSubtitles plugin v$pluginVersion extracted." -ForegroundColor Green
            Write-DebugLog "INFO" "OpenSubtitles plugin v$pluginVersion extracted to $pluginDir"
            $needInstall = $true
        }
    } catch {
        Write-Warning "     Failed to download/install OpenSubtitles plugin: $_"
        Write-DebugLog "ERROR" "OpenSubtitles plugin download failed: $_"
        $needInstall = $false
    }
}

# If plugin was newly extracted, restart Jellyfin so it loads the plugin
if ($needInstall) {
    Write-Host "  -> Restarting Jellyfin to load OpenSubtitles plugin..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Restarting Jellyfin to load plugin..."
    try {
        Restart-Service -Name $svc.Name -Force -ErrorAction Stop
    } catch {
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 8

    $upAgain = $false
    $dlAgain = (Get-Date).AddSeconds(120)
    $restartWaited = 0
    while (-not $upAgain -and (Get-Date) -lt $dlAgain) {
        try {
            Invoke-WebRequest -Uri "$ApiBase/System/Info/Public" `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            $upAgain = $true
        } catch { Start-Sleep -Seconds 3; $restartWaited += 3 }
    }
    Write-DebugLog "VAR Jellyfin API back after restart=$upAgain waited=${restartWaited}s"
    if ($upAgain) {
        Write-Host "     [OK] Jellyfin restarted and online." -ForegroundColor Green
        Write-DebugLog "INFO" "Jellyfin restarted and API is up"
        # Wait for plugin subsystem to finish loading (API responds quickly, plugins load after)
        Write-Host "     Waiting for plugin subsystem to initialize..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
        try {
            $authBody2 = @{ Username = $Username; Pw = $Password } | ConvertTo-Json -Compress
            $authResp2 = Invoke-RestMethod -Uri "$ApiBase/Users/AuthenticateByName" -Method Post `
                -Body $authBody2 -ContentType "application/json" `
                -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop
            $UserAuth = @{"X-MediaBrowser-Token" = $authResp2.AccessToken; "Authorization" = $Client}
            Write-DebugLog "INFO" "Re-authenticated after plugin restart"
        } catch {
            Write-Warning "     Re-authentication after restart failed: $_"
            Write-DebugLog "WARN" "Re-auth after restart failed: $_"
        }
    } else {
        Write-Warning "     Jellyfin did not come back within 120s after plugin restart."
        Write-DebugLog "WARN" "Jellyfin API not up after 120s restart wait"
    }
}

# Configure OpenSubtitles credentials via Jellyfin plugin API
Write-DebugLog "VAR OsUser=$OsUser OsPass=[REDACTED]"
if ($OsUser -and $OsPass) {
    Write-Host "  -> Configuring OpenSubtitles plugin credentials via API..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Setting OpenSubtitles plugin credentials for user=$OsUser..."
    try {
        $allPlugins = (Invoke-WebRequest -Uri "$ApiBase/Plugins" `
            -Headers $UserAuth -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
        $osPlugin = $allPlugins | Where-Object { $_.Name -eq "Open Subtitles" } | Select-Object -First 1
        Write-DebugLog "VAR OpenSubtitles plugin loaded=$($null -ne $osPlugin) name=$(if ($osPlugin) { $osPlugin.Name } else { 'N/A' }) version=$(if ($osPlugin) { $osPlugin.Version } else { 'N/A' })"

        if (-not $osPlugin) {
            Write-Warning "     OpenSubtitles plugin not found in loaded plugins list  --  may need a manual Jellyfin restart."
            Write-DebugLog "WARN" "OpenSubtitles plugin not in loaded plugins list"
        } else {
            $rawId   = $osPlugin.Id
            $pluginGuid = "$($rawId.Substring(0,8))-$($rawId.Substring(8,4))-$($rawId.Substring(12,4))-$($rawId.Substring(16,4))-$($rawId.Substring(20,12))"
            Write-DebugLog "VAR pluginGuid=$pluginGuid"

            # GET current config; if the plugin hasn't written its config file yet (404), start empty
            $cfgHash = @{}
            try {
                $pluginCfg = (Invoke-WebRequest -Uri "$ApiBase/Plugins/$pluginGuid/Configuration" `
                    -Headers $UserAuth -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
                $pluginCfg.PSObject.Properties | ForEach-Object { $cfgHash[$_.Name] = $_.Value }
                Write-DebugLog "INFO" "Fetched existing plugin config ($($cfgHash.Count) fields)"
            } catch {
                Write-DebugLog "WARN" "GET plugin config failed (plugin config not yet initialized): $_. Will POST credentials only."
            }
            $cfgHash["Username"] = $OsUser
            $cfgHash["Password"] = $OsPass

            Invoke-RestMethod -Uri "$ApiBase/Plugins/$pluginGuid/Configuration" -Method Post `
                -Body ($cfgHash | ConvertTo-Json -Depth 5 -Compress) `
                -ContentType "application/json" `
                -Headers $UserAuth -UseBasicParsing -ErrorAction Stop | Out-Null

            Write-Host "     [OK] OpenSubtitles credentials saved (plugin: $($osPlugin.Name) v$($osPlugin.Version))." -ForegroundColor Green
            Write-DebugLog "INFO" "OpenSubtitles credentials saved (username=$OsUser password=[REDACTED])"
        }
    } catch {
        Write-Warning "     Failed to configure OpenSubtitles plugin: $_"
        Write-DebugLog "ERROR" "OpenSubtitles plugin credential configuration failed: $_"
    }
} else {
    Write-Host "     ! No OpenSubtitles.com credentials  --  fill in Layer2.OpenSubtitles in config.json." -ForegroundColor Yellow
    Write-DebugLog "WARN" "OpenSubtitles.com credentials not configured in config.json"
}

# -- 8. Trigger library scan ---------------------------------------------------
Write-Host "  -> Triggering library scan..." -ForegroundColor Gray

# Warn about any drive-letter libraries that are empty (e.g. rclone mount not yet populated)
foreach ($lib in $Layer2Config.MediaLibraries) {
    $libPath = $lib.Path
    if ($libPath -match '^[A-Za-z]:\\?$' -and (Test-Path $libPath)) {
        $childCount = @(Get-ChildItem $libPath -ErrorAction SilentlyContinue).Count
        if ($childCount -eq 0) {
            Write-Host "     ! Library '$($lib.Name)' drive $libPath is mounted but empty." -ForegroundColor Yellow
            Write-Host "       Content may still be loading. A manual rescan may be needed later." -ForegroundColor Yellow
            Write-DebugLog "WARN" "Library '$($lib.Name)' drive $libPath mounted but empty ($childCount children)"
        } else {
            Write-DebugLog "INFO" "Library '$($lib.Name)' drive $libPath has $childCount items"
        }
    }
}

Write-DebugLog "INFO" "Triggering Jellyfin library scan..."
try {
    Invoke-RestMethod -Uri "$ApiBase/Library/Refresh" -Method Post `
        -Headers $UserAuth `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "     [OK] Library scan queued." -ForegroundColor Green
    Write-DebugLog "INFO" "Jellyfin library scan triggered"
} catch {
    Write-Warning "     Failed to trigger library scan: $_"
    Write-DebugLog "WARN" "Library scan trigger failed: $_"
}

Write-Host "  [OK] $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_jellyfin_libraries.ps1 complete"
