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

# MountLetter is the base letter and the installer mounts exactly one drive:
# movies, from zurg's __all__ tree.  TV shows are NOT split onto a second drive
# (the WebDAV layer cannot separate them), so only this one drive is expected.
$ml     = if ($Config.RealDebrid -and $Config.RealDebrid.MountLetter) { $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':') } else { 'R' }
if ($ml -notmatch '^[A-Y]$') { $ml = 'R' }   # same fallback as scripts/16_rclone.ps1
$mDrive = "$ml`:"

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

    $mMounted = Test-Path "$mDrive\"
    if ($mMounted) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'PASS' "Movies drive $mDrive mounted"))
    } elseif ($mountVisibleHere) {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'FAIL' "Movies drive $mDrive not mounted"))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" 'SKIP' "Drive $mDrive is owned by the rclone-rd-movies service session (0) and is not visible from this session -- verify from a service context"))
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
        $jellyfinBase = Get-AppUrlBase 'jellyfin' $Config.General.DomainMode
        $libs = Invoke-ApiCheck "http://127.0.0.1:$jellyfinPort${jellyfinBase}/Library/VirtualFolders" @{'X-Emby-Authorization'="MediaBrowser Token=`"$apiKey`""} -TimeoutSec 8
        if ($libs.ok) {
            $libPaths = @($libs.data | ForEach-Object { $_.Locations } | ForEach-Object { $_ })
            $hasMovieDrive = $libPaths | Where-Object { $_ -match "^$([regex]::Escape($mDrive))" }
            $Script:Results.Add((New-TestResult $svc 2 "JellyfinMoviesRD" $(if ($hasMovieDrive) { 'PASS' } else { 'WARN' }) "Jellyfin library on $mDrive"))
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
}
