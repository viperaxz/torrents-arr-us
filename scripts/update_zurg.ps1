# update_zurg.ps1
# Per-app update script: Zurg (GitHub release, single-exe swap).
# zurg.exe lives next to config.yml, so only the executable is replaced.
# NOTE: Zurg versions historically shipped mount-path regressions (the
# compilePattern panic in v0.9.3), so the swap is gated on the WebDAV listener
# answering again.  The rclone mount is deliberately NOT part of that gate: Zurg
# republishes __all__ only after compiling its torrent cache (minutes), and
# rclone keeps serving the previous listing meanwhile.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
# Anime split helpers: needed by the config migration below (zurg:anime directory).
. (Join-Path $PSScriptRoot "anime_helpers.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName     = "Zurg"
$ServiceName = "Zurg"
$ExePath     = Join-Path $InstallDir "Zurg\zurg.exe"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "zurg.exe not found at $ExePath" }
}

try {
    $repo    = $Config._Versions.Apps.$AppName.repo
    $headers = @{ "User-Agent" = "win-seedbox-installer" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$Version" -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object {
        $_.name -match "windows" -and ($_.name -match "amd64" -or $_.name -match "x64")
    } | Select-Object -First 1
    if (-not $asset) { throw "No Windows amd64/x64 asset found in Zurg release $Version" }

    $tmpDir = Join-Path $env:TEMP "zurg-update-$Version"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    $newExe = $null

    if ($asset.name -like "*.zip") {
        $dlZip = Join-Path $tmpDir "zurg.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dlZip -UseBasicParsing
        $exDir = Join-Path $tmpDir "ex"
        New-Item -Path $exDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $dlZip -DestinationPath $exDir -Force
        $newExe = Get-ChildItem $exDir -Recurse -Filter "*.exe" | Select-Object -First 1
    } else {
        $dlExe = Join-Path $tmpDir "zurg-new.exe"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dlExe -UseBasicParsing
        $newExe = Get-Item $dlExe
    }
    if (-not $newExe) { throw "Could not extract a Zurg executable from the release asset" }

    # A bare-exe asset used to leave $newExe as a STRING, so $newExe.FullName was
    # empty and the swap failed with a null NewExePath.  Get-Item above keeps both
    # branches returning a FileInfo.
    $newExePath = $newExe.FullName

    # Zurg reports Running while it is still in its network test; the WebDAV
    # listener opens ~30 s after start.  Gate the swap on the port answering, so a
    # release that starts but never serves is rolled back.
    $zurgPort   = 9999
    $webdavGate = {
        param()
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            try {
                $null = Invoke-WebRequest -Uri "http://127.0.0.1:$zurgPort/" -Method Get `
                    -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                return $true
            } catch {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { return $true }
                Start-Sleep -Seconds 3
            }
        }
        return $false
    }

    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExePath -ServiceNames @($ServiceName) -HealthSeconds 10 `
                -PostHealthCheck $webdavGate
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    # One-time migrations for installs created before the split(s):
    #   * add Zurg's `directories` block so the rclone mounts (zurg:movies /
    #     zurg:shows) have something to mount;
    #   * add the optional `anime` directory, which routes absolute-numbered anime
    #     packs out of zurg:shows and into zurg:anime.
    # Only a successful swap reaches here, and each extra restart happens once.
    $zurgCfgPath = Join-Path $InstallDir "Zurg\config.yml"
    if (Test-Path $zurgCfgPath) {
        $zurgCfgText = [System.IO.File]::ReadAllText($zurgCfgPath)
        $zurgCfgChanged = $false
        if ($zurgCfgText -notmatch '(?m)^directories:') {
            $dirBlock = @"

directories:
  shows:
    group: media
    group_order: 10
    filters:
      - has_episodes: true
  movies:
    group: media
    group_order: 20
    only_show_the_biggest_file: true
    filters:
      - regex: /.*/
"@
            $zurgCfgText = $zurgCfgText.TrimEnd() + "`n" + $dirBlock.TrimStart("`r", "`n")
            $zurgCfgChanged = $true
            Write-UcLog "INFO" "Adding Zurg directories (movies/shows split)"
        }

        if (Get-Command Get-AnimeTorrentRegex -ErrorAction SilentlyContinue) {
            $animeRegex = Get-AnimeTorrentRegex -Config $Config
            if ($animeRegex -and $zurgCfgText -notmatch '(?m)^\s+anime:') {
                $animeBlock = "  anime:`n    group: media`n    group_order: 5`n    filters:`n      - and:`n        - has_episodes: true`n        - regex: /$animeRegex/`n"
                # Zurg picks the first matching directory by group_order, so the
                # block must be inserted directly under `directories:` -- ahead of
                # shows/movies -- or those torrents stay in zurg:shows.
                $dirHeader = [regex]::Match($zurgCfgText, '(?m)^directories:[ \t]*\r?\n')
                if ($dirHeader.Success) {
                    $zurgCfgText = $zurgCfgText.Insert($dirHeader.Index + $dirHeader.Length, $animeBlock)
                    $zurgCfgChanged = $true
                    Write-UcLog "INFO" "Adding Zurg anime directory (absolute-numbered packs)"
                }
            }
        }

        if ($zurgCfgChanged) {
            [System.IO.File]::WriteAllText($zurgCfgPath, $zurgCfgText, (New-Object System.Text.UTF8Encoding($false)))
            $null = Restart-ServiceBounded -Name $ServiceName -StopTimeoutSeconds 60 -StartTimeoutSeconds 120
            Write-UcLog "INFO" "Zurg config migrated and $ServiceName restarted"
        }
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "exe swapped, WebDAV listener verified" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
