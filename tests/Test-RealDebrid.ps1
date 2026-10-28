# tests/Test-RealDebrid.ps1 -- Zurg + rclone Real-Debrid integration test module

param([int]$LayerFilter = 0)

$svc = 'RealDebrid'

if ($Config.Apps.RealDebrid -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.RealDebrid = false in config'))
    return
}

# Zurg is an internal service: the port is fixed in scripts/15_zurg.ps1 and the
# host's RealDebrid config section has no port key.
$zurgPort = 9999

# Two drives since the Zurg `directories` split: MountLetter carries zurg:movies,
# TvMountLetter carries zurg:shows.  Same fallbacks as scripts/16_rclone.ps1.
$ml     = if ($Config.RealDebrid -and $Config.RealDebrid.MountLetter) { $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':') } else { 'R' }
if ($ml -notmatch '^[A-Y]$') { $ml = 'R' }
$tl     = if ($Config.RealDebrid -and $Config.RealDebrid.PSObject.Properties['TvMountLetter'] -and $Config.RealDebrid.TvMountLetter) { $Config.RealDebrid.TvMountLetter.ToString().ToUpper().TrimEnd(':') } else { 'S' }
if ($tl -notmatch '^[A-Y]$' -or $tl -eq $ml) { $tl = if ($ml -ne 'S') { 'S' } else { 'T' } }
$mDrive = "$ml`:"
$tDrive = "$tl`:"

# Optional anime split: absolute-numbered packs get their own zurg:anime mount and
# are re-presented to Jellyfin as a renamed symlink tree by
# scripts\sync_anime_library.ps1.  Same fallbacks as scripts/16_rclone.ps1.
$animeEnabled = [bool]($Config.Anime -and $Config.Anime.PSObject.Properties['Enabled'] -and $Config.Anime.Enabled -eq $true -and
                        $Config.Anime.PSObject.Properties['Sources'] -and @($Config.Anime.Sources).Count -gt 0)
$al = if ($animeEnabled -and $Config.Anime.PSObject.Properties['MountLetter'] -and $Config.Anime.MountLetter) {
    $Config.Anime.MountLetter.ToString().ToUpper().TrimEnd(':')
} else { 'T' }
if ($al -notmatch '^[A-Y]$' -or $al -in @($ml, $tl)) {
    $al = @('T', 'U', 'V', 'W', 'X', 'Y') | Where-Object { $_ -ne $ml -and $_ -ne $tl } | Select-Object -First 1
}
$aDrive   = "$al`:"
$aLibPath = if ($animeEnabled -and $Config.Anime.PSObject.Properties['LibraryPath'] -and $Config.Anime.LibraryPath) {
    [string]$Config.Anime.LibraryPath
} else { Join-Path $InstallDir 'Anime' }

# A WinFsp drive letter belongs to the Windows session that created it.  The
# mount is created by the rclone-rd-movies service in session 0, so when this
# suite runs from an interactive desktop session (1+) the drive letter is
# invisible even on a healthy install -- that is unverifiable, not failed.
$mountVisibleHere = $true
try {
    $rdSvcInfo = Get-CimInstance Win32_Service -Filter "Name='rclone-rd-movies'" -ErrorAction SilentlyContinue
    if ($rdSvcInfo -and $rdSvcInfo.ProcessId -gt 0) {
        $rdProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($rdSvcInfo.ProcessId)" -ErrorAction SilentlyContinue
        if ($rdProc) { $mountVisibleHere = ($rdProc.SessionId -eq (Get-Process -Id $PID).SessionId) }
    }
} catch { }

# -- Layer 1: Zurg service, WebDAV, drive mounted -----------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $zurgNssm = Get-Service 'Zurg' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ZurgRunning' $(if ($zurgNssm -and $zurgNssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "Zurg NSSM service"))

    # Zurg's WebDAV is unauthenticated, so it must listen on loopback only.
    # A listener on 0.0.0.0/:: publishes the whole Real-Debrid library to the LAN.
    $listeners = @()
    try { $listeners = @(Get-NetTCPConnection -LocalPort $zurgPort -State Listen -ErrorAction Stop) } catch { }
    if ($listeners.Count -eq 0) {
        $Script:Results.Add((New-TestResult $svc 1 'ZurgWebDavLoopback' 'FAIL' "Nothing listening on :$zurgPort (Zurg is not serving; check the RealDebrid.ApiKey)"))
    } else {
        $exposed = @($listeners | Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' })
        $Script:Results.Add((New-TestResult $svc 1 'ZurgWebDavLoopback' $(if ($exposed.Count -eq 0) { 'PASS' } else { 'FAIL' }) "Zurg :$zurgPort listeners: $((@($listeners.LocalAddress) | Sort-Object -Unique) -join ', ')"))
    }

    $zurgWebDav = Invoke-ApiCheck "http://127.0.0.1:$zurgPort/" -TimeoutSec 8
    $zurgWebDavStatus = if ($zurgWebDav.ok) { 'PASS' } elseif ($listeners.Count -gt 0) { 'WARN' } else { 'FAIL' }
    $Script:Results.Add((New-TestResult $svc 1 'ZurgWebDav' $zurgWebDavStatus "Zurg WebDAV :$zurgPort" $zurgWebDav.latency_ms))

    # The listener answers for minutes before __all__ has any entries: Zurg
    # publishes the tree only after compiling its torrent cache.  A mount made in
    # that window serves an empty root until rclone's directory cache expires, so
    # "WebDAV responds" alone is not a usable-mount signal.
    $zurgAllCount = 0
    $zurgAllError = $null
    try {
        $zurgAllResp  = Invoke-WebRequest -Uri "http://127.0.0.1:$zurgPort/dav/__all__/" -Method Get `
                            -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $zurgAllCount = ([regex]::Matches($zurgAllResp.Content, '<[Dd]:response')).Count - 1
        if ($zurgAllCount -lt 0) { $zurgAllCount = 0 }
    } catch {
        $zurgAllError = $_.Exception.Message
    }
    $zurgAllDetail = if ($zurgAllError) { "listing failed: $zurgAllError" } else { "$zurgAllCount entrie(s)" }
    $Script:Results.Add((New-TestResult $svc 1 'ZurgAllEnumerated' $(if ($zurgAllCount -gt 0) { 'PASS' } else { 'WARN' }) "Zurg __all__: $zurgAllDetail"))

    $mMounted = Test-Path "$mDrive\"
    if ($mMounted) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'PASS' "Movies drive $mDrive mounted"))
    } elseif ($mountVisibleHere) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'FAIL' "Movies drive $mDrive not mounted"))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'SKIP' "Drive $mDrive is owned by the rclone-rd-movies service session (0) and is not visible from this session -- verify from a service context"))
    }

    $tMounted = Test-Path "$tDrive\"
    if ($tMounted) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveShowsMounted_$tDrive" 'PASS' "Shows drive $tDrive mounted"))
    } elseif ($mountVisibleHere) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveShowsMounted_$tDrive" 'FAIL' "Shows drive $tDrive not mounted"))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 "DriveShowsMounted_$tDrive" 'SKIP' "Drive $tDrive is owned by the rclone-rd-shows service session (0) and is not visible from this session -- verify from a service context"))
    }

    if ($animeEnabled) {
        $aSvcInfo = Get-Service 'rclone-rd-anime' -ErrorAction SilentlyContinue
        $Script:Results.Add((New-TestResult $svc 1 'AnimeServiceRunning' $(if ($aSvcInfo -and $aSvcInfo.Status -eq 'Running') { 'PASS' } elseif (-not $aSvcInfo) { 'FAIL' } else { 'WARN' }) "rclone-rd-anime NSSM service ($(if ($aSvcInfo) { $aSvcInfo.Status } else { 'missing' }))"))

        if (Test-Path "$aDrive\") {
            $Script:Results.Add((New-TestResult $svc 1 "DriveAnimeMounted_$aDrive" 'PASS' "Anime drive $aDrive mounted"))
        } elseif ($mountVisibleHere) {
            $Script:Results.Add((New-TestResult $svc 1 "DriveAnimeMounted_$aDrive" 'FAIL' "Anime drive $aDrive not mounted"))
        } else {
            $Script:Results.Add((New-TestResult $svc 1 "DriveAnimeMounted_$aDrive" 'SKIP' "Drive $aDrive is owned by the rclone-rd-anime service session (0) and is not visible from this session -- verify from a service context"))
        }
    }
}

# -- Layer 2: Jellyfin RD library points at the mount letter ------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $jellyfinPort = $Config.Ports.Jellyfin
    $apiKeyPath   = Join-Path $InstallDir 'secrets\jellyfin_api_key.txt'
    $apiKey       = $null
    if (Test-Path $apiKeyPath) {
        $apiKey = ([System.IO.File]::ReadAllText($apiKeyPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
    }
    if ($apiKey) {
        # Jellyfin 12.x answers 401 for X-Emby-Authorization / X-Emby-Token, with an
        # API key just as with a user token; only the Authorization header carrying
        # the MediaBrowser client string plus Token= is accepted. Same format as
        # collect_status.ps1 and configure_layer2_jellyfin_libraries.ps1.
        $jfClient = 'MediaBrowser Client="seedbox-tests", Device="test-suite", DeviceId="seedbox-tests", Version="1.0.0"'
        $jfAuth   = @{ 'Authorization' = ($jfClient + ', Token="' + $apiKey + '"') }
        $jellyfinBase = Get-AppUrlBase 'jellyfin' $Config.General.DomainMode
        $libs = Invoke-ApiCheck "http://127.0.0.1:$jellyfinPort${jellyfinBase}/Library/VirtualFolders" $jfAuth -TimeoutSec 8
        if ($libs.ok) {
            $libPaths = @($libs.data | ForEach-Object { $_.Locations } | ForEach-Object { $_ })
            $hasMovieDrive = $libPaths | Where-Object { $_ -match "^$([regex]::Escape($mDrive))" }
            $Script:Results.Add((New-TestResult $svc 2 "JellyfinMoviesRD" $(if ($hasMovieDrive) { 'PASS' } else { 'WARN' }) "Jellyfin library on $mDrive"))
            $hasTvDrive = $libPaths | Where-Object { $_ -match "^$([regex]::Escape($tDrive))" }
            $Script:Results.Add((New-TestResult $svc 2 "JellyfinShowsRD" $(if ($hasTvDrive) { 'PASS' } else { 'WARN' }) "Jellyfin library on $tDrive"))
            if ($animeEnabled) {
                $hasAnimeLib = $libPaths | Where-Object { $_ -match "^$([regex]::Escape($aLibPath))" }
                $Script:Results.Add((New-TestResult $svc 2 'JellyfinAnimeLibrary' $(if ($hasAnimeLib) { 'PASS' } else { 'WARN' }) "Jellyfin library on $aLibPath"))
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'JellyfinLibraries' 'FAIL' $libs.error))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinLibraries' 'SKIP' 'No Jellyfin API key'))
    }
}

# -- Layer 3: Mount is non-empty ----------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    if (Test-Path "$mDrive\") {
        $items = @(Get-ChildItem "$mDrive\" -ErrorAction SilentlyContinue)
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$mDrive" $(if ($items.Count -gt 0) { 'PASS' } else { 'WARN' }) "$($items.Count) item(s) in $mDrive"))
    } elseif (-not $mountVisibleHere) {
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$mDrive" 'SKIP' "Drive $mDrive belongs to the rclone-rd-movies service session (0) -- not visible from this session"))
    } else {
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$mDrive" 'FAIL' "Drive $mDrive not mounted"))
    }

    if (Test-Path "$tDrive\") {
        $tItems = @(Get-ChildItem "$tDrive\" -ErrorAction SilentlyContinue)
        # Zero entries is a valid shows tree; it just means no episode torrents.
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$tDrive" $(if ($tItems.Count -gt 0) { 'PASS' } else { 'WARN' }) "$($tItems.Count) item(s) in $tDrive"))
    } elseif (-not $mountVisibleHere) {
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$tDrive" 'SKIP' "Drive $tDrive belongs to the rclone-rd-shows service session (0) -- not visible from this session"))
    } else {
        $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$tDrive" 'FAIL' "Drive $tDrive not mounted"))
    }

    if ($animeEnabled) {
        $animeLinks = 0
        if (Test-Path -LiteralPath $aLibPath) {
            $animeLinks = @(Get-ChildItem -LiteralPath $aLibPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSObject.Properties['LinkType'] -and $_.LinkType -eq 'SymbolicLink' }).Count
        }
        # No anime in Real-Debrid yet is a valid empty view; a mounted anime drive
        # that produced no links is the signal that scripts\sync_anime_library.ps1
        # has never run (or matched nothing).
        $animeLinkStatus = if ($animeLinks -gt 0) { 'PASS' } elseif (Test-Path "$aDrive\") { 'WARN' } else { 'SKIP' }
        $Script:Results.Add((New-TestResult $svc 3 'AnimeLibraryLinks' $animeLinkStatus "$animeLinks episode link(s) in $aLibPath"))
    }
}
