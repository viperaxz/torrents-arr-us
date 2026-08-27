param(
    [Parameter(Position=0)]
    [string]$Command = "",
    [switch]$AutoApprove,  # update: skip per-app confirmation prompts
    [switch]$Force         # uninstall: skip confirmation prompt
)

$ProjectRoot = $PSScriptRoot

function Show-Usage {
    Write-Host ""
    Write-Host "  Usage: box <command> [options]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Commands:" -ForegroundColor White
    Write-Host "    update      Pull latest scripts from git, then update all app binaries" -ForegroundColor White
    Write-Host "    check       Show which apps have updates available (no changes made)" -ForegroundColor White
    Write-Host "    uninstall   Remove all seedbox services, binaries, and configuration" -ForegroundColor White
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor DarkGray
    Write-Host "    -AutoApprove   Skip per-update confirmation (update only)" -ForegroundColor DarkGray
    Write-Host "    -Force         Skip uninstall confirmation (uninstall only)" -ForegroundColor DarkGray
    Write-Host ""
}

function Assert-Admin {
    param([string]$ForCommand)
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "'box $ForCommand' must be run as Administrator."
        Write-Host ""
        Write-Host "  Re-launch this window as Administrator and run the command again." -ForegroundColor Yellow
        exit 1
    }
}

# -----------------------------------------------------------------------------
switch ($Command.ToLower()) {

# -- box update ----------------------------------------------------------------
"update" {
    Assert-Admin "update"

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  box update" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Sync project code from origin
    $isGitRepo = Test-Path (Join-Path $ProjectRoot ".git")
    if ($isGitRepo) {
        Write-Host "[git] Syncing project code from origin/main..." -ForegroundColor Cyan
        try {
            $pullOutput = & git -C $ProjectRoot pull origin main 2>&1
            foreach ($line in $pullOutput) {
                $color = if ("$line" -match "Already up|up to date") { "Green" } else { "DarkGray" }
                Write-Host "  $line" -ForegroundColor $color
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "git pull returned exit code $LASTEXITCODE. Continuing with local scripts."
            } else {
                Write-Host "[git] Done." -ForegroundColor Green
            }
        } catch {
            Write-Warning "git pull failed: $_. Continuing with local scripts."
        }
    } else {
        Write-Host "[git] Not a git repository. Skipping code sync." -ForegroundColor DarkGray
        Write-Host "     Clone with git to enable automatic script updates." -ForegroundColor DarkGray
    }

    Write-Host ""

    # Step 2: Run the update script (self-update phase will skip because we already pulled)
    $updateScript = Join-Path $ProjectRoot "master_update.ps1"
    if (-not (Test-Path $updateScript)) {
        Write-Error "master_update.ps1 not found in $ProjectRoot"
        exit 1
    }
    $extraArgs = if ($AutoApprove) { @("-AutoApprove") } else { @() }
    & $updateScript @extraArgs
}

# -- box check -----------------------------------------------------------------
"check" {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  box check" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""

    # Load config for InstallDir
    $configPath = Join-Path $ProjectRoot "config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found in $ProjectRoot"
        exit 1
    }
    $config     = Get-Content -Raw $configPath | ConvertFrom-Json
    $installDir = $config.General.InstallDir
    $locksDir   = Join-Path $installDir ".locks"

    # Load local versions.json
    $localVersionsPath = Join-Path $ProjectRoot "versions.json"
    if (-not (Test-Path $localVersionsPath)) {
        Write-Error "versions.json not found. Is this an up-to-date installation?"
        exit 1
    }
    $localVersions = Get-Content -Raw $localVersionsPath | ConvertFrom-Json
    $remoteUrl     = if ($localVersions.github_raw_url) { $localVersions.github_raw_url } else {
        "https://raw.githubusercontent.com/viperaxz/torrents-arr-us/main/versions.json"
    }

    # Fetch remote versions.json
    Write-Host "[check] Fetching remote version manifest..." -ForegroundColor Gray
    $remoteVersions = $localVersions
    try {
        $remoteVersions = Invoke-RestMethod -Uri $remoteUrl -UseBasicParsing -TimeoutSec 15
        Write-Host "[check] Remote manifest: schema $($remoteVersions.schema), updated $($remoteVersions.updated)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not reach remote manifest: $_"
        Write-Host "         Comparing against local versions.json." -ForegroundColor DarkGray
    }

    Write-Host ""

    # Check project code freshness (git)
    $isGitRepo = Test-Path (Join-Path $ProjectRoot ".git")
    $projectBehind = $false
    if ($isGitRepo) {
        try {
            & git -C $ProjectRoot fetch origin main --quiet 2>&1 | Out-Null
            $localSha  = (& git -C $ProjectRoot rev-parse HEAD 2>&1).Trim()
            $remoteSha = (& git -C $ProjectRoot rev-parse origin/main 2>&1).Trim()
            $projectBehind = ($localSha -ne $remoteSha -and $remoteSha -ne "")
        } catch { }
    }

    # Compare app versions
    $pendingCount    = 0
    $securityPending = $false
    $appOrder        = @("Sonarr","Radarr","Prowlarr","Bazarr","Flaresolverr","Jellyfin","Deluge","ffmpeg","Caddy")

    Write-Host "  App versions:" -ForegroundColor White
    Write-Host ("  {0,-16} {1,-22} {2,-22} {3}" -f "App", "Installed", "Available", "Status") -ForegroundColor DarkGray
    Write-Host ("  " + ("-" * 75)) -ForegroundColor DarkGray

    foreach ($appName in $appOrder) {
        $manifestEntry = $remoteVersions.apps.$appName
        if (-not $manifestEntry) { continue }

        $lower    = $appName.ToLower()
        $lockFile = Join-Path $locksDir ".$lower.lock"

        if (-not (Test-Path $lockFile)) {
            Write-Host ("  {0,-16} {1,-22} {2,-22} {3}" -f $appName, "(not installed)", $manifestEntry.version, "") -ForegroundColor DarkGray
            continue
        }

        $installedVer   = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Trim()
        $normalInstalled = $installedVer.TrimStart('v')
        $normalManifest  = $manifestEntry.version.TrimStart('v')

        if (-not $installedVer -or $installedVer -eq "unknown") {
            Write-Host ("  {0,-16} {1,-22} {2,-22} {3}" -f $appName, "(unknown)", $manifestEntry.version, "") -ForegroundColor DarkGray
        } elseif ($normalInstalled -ne $normalManifest) {
            $isSecure = ($manifestEntry.PSObject.Properties["security"] -and $manifestEntry.security -eq $true)
            $tag      = if ($isSecure) { "[SECURITY]" } else { "[UPDATE]" }
            $color    = if ($isSecure) { "Red" } else { "Yellow" }
            Write-Host ("  {0,-16} {1,-22} {2,-22} {3}" -f $appName, $installedVer, $manifestEntry.version, $tag) -ForegroundColor $color
            if ($isSecure -and $manifestEntry.PSObject.Properties["securityNote"]) {
                Write-Host ("  {0,-16} {1}" -f "", $manifestEntry.securityNote) -ForegroundColor Red
            }
            $pendingCount++
            if ($isSecure) { $securityPending = $true }
        } else {
            Write-Host ("  {0,-16} {1,-22} {2,-22} {3}" -f $appName, $installedVer, $manifestEntry.version, "up to date") -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host ("  {0,-16} {1}" -f "Project scripts", $(if ($projectBehind) { "BEHIND origin/main [UPDATE]" } elseif ($isGitRepo) { "up to date" } else { "(not a git repo)" })) `
        -ForegroundColor $(if ($projectBehind) { "Yellow" } else { "Green" })

    Write-Host ""
    Write-Host ("  " + ("-" * 75)) -ForegroundColor DarkGray

    if ($pendingCount -eq 0 -and -not $projectBehind) {
        Write-Host "  Everything is up to date." -ForegroundColor Green
    } else {
        if ($securityPending) {
            Write-Host "  SECURITY updates pending! Run 'box update' immediately." -ForegroundColor Red
        } else {
            $items = @()
            if ($pendingCount -gt 0) { $items += "$pendingCount app update$(if ($pendingCount -gt 1) {'s'})" }
            if ($projectBehind)      { $items += "project script updates" }
            Write-Host "  $($items -join ', ') available. Run 'box update' to apply." -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# -- box uninstall -------------------------------------------------------------
"uninstall" {
    Assert-Admin "uninstall"

    $uninstallScript = Join-Path $ProjectRoot "master_uninstall.ps1"
    if (-not (Test-Path $uninstallScript)) {
        Write-Error "master_uninstall.ps1 not found in $ProjectRoot"
        exit 1
    }
    $extraArgs = if ($Force) { @("-Force") } else { @() }
    & $uninstallScript @extraArgs
}

# -- unknown / help ------------------------------------------------------------
default {
    if ($Command -ne "") {
        Write-Warning "Unknown command: '$Command'"
    }
    Show-Usage
    exit $(if ($Command -ne "") { 1 } else { 0 })
}

}
