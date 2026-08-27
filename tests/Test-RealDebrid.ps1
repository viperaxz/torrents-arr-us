# tests/Test-RealDebrid.ps1 -- Zurg + rclone Real-Debrid integration test module

param([int]$LayerFilter = 0)

$svc = 'RealDebrid'

if ($Config.Apps.RealDebrid -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.RealDebrid = false in config'))
    return
}

$ml     = if ($Config.RealDebrid -and $Config.RealDebrid.MountLetter) { $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':') } else { 'R' }
$slLet  = [char]([int][char]$ml + 1)
$mDrive = "$ml`:"
$sDrive = "$slLet`:"

# -- Layer 1: Zurg service, WebDAV, drives mounted -----------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $zurgNssm = Get-Service 'Zurg' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ZurgRunning' $(if ($zurgNssm -and $zurgNssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "Zurg NSSM service"))

    $zurgWebDav = Invoke-ApiCheck 'http://127.0.0.1:9999/' -TimeoutSec 8
    $Script:Results.Add((New-TestResult $svc 1 'ZurgWebDav' $(if ($zurgWebDav.ok) { 'PASS' } else { 'FAIL' }) "Zurg WebDAV :9999" $zurgWebDav.latency_ms))

    $mMounted = Test-Path "$mDrive\"
    $Script:Results.Add((New-TestResult $svc 1 "DriveMoviesMounted_$mDrive" $(if ($mMounted) { 'PASS' } else { 'FAIL' }) "Movies drive $mDrive mounted"))

    $sMounted = Test-Path "$sDrive\"
    $Script:Results.Add((New-TestResult $svc 1 "DriveShowsMounted_$sDrive" $(if ($sMounted) { 'PASS' } else { 'FAIL' }) "Shows drive $sDrive mounted"))
}

# -- Layer 2: Jellyfin RD libraries point at correct drive letters -------------
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
            $hasShowDrive  = $libPaths | Where-Object { $_ -match "^$([regex]::Escape($sDrive))" }
            $Script:Results.Add((New-TestResult $svc 2 "JellyfinMoviesRD" $(if ($hasMovieDrive) { 'PASS' } else { 'WARN' }) "Jellyfin library on $mDrive"))
            $Script:Results.Add((New-TestResult $svc 2 "JellyfinShowsRD"  $(if ($hasShowDrive)  { 'PASS' } else { 'WARN' }) "Jellyfin library on $sDrive"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'JellyfinLibraries' 'FAIL' $libs.error))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinLibraries' 'SKIP' 'No Jellyfin API key'))
    }
}

# -- Layer 3: Drives are non-empty --------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    foreach ($drive in @($mDrive, $sDrive)) {
        if (Test-Path "$drive\") {
            $items = @(Get-ChildItem "$drive\" -ErrorAction SilentlyContinue)
            $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$drive" $(if ($items.Count -gt 0) { 'PASS' } else { 'WARN' }) "$($items.Count) item(s) in $drive"))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 "DriveNonEmpty_$drive" 'FAIL' "Drive $drive not mounted"))
        }
    }
}
