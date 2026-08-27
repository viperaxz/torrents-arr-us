param(
    [switch]$AutoApprove   # skip all confirmation prompts
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as an Administrator!"
    exit 1
}

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found. Cannot determine InstallDir."
    exit 1
}
$Config     = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$InstallDir = $Config.General.InstallDir
$LocksDir   = Join-Path $InstallDir ".locks"
$BinDir     = Join-Path $PSScriptRoot "bin"

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "scripts\debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "master_update.ps1 started. AutoApprove=$AutoApprove"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  win-seedbox Update Manager" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------------------
# PHASE 1: Self-update (project scripts + versions.json)
# -----------------------------------------------------------------------------
Write-Host "[Self-Update] Checking for project script updates..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Self-update check ==="

$isGitRepo = Test-Path (Join-Path $PSScriptRoot ".git")
Write-DebugLog "VAR isGitRepo=$isGitRepo"

$selfUpdated = $false

if ($isGitRepo) {
    try {
        Write-Host "  -> Fetching from origin..." -ForegroundColor Gray
        $global:LASTEXITCODE = 0
        & git -C $PSScriptRoot fetch origin main --quiet 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  -> Could not fetch from origin (exit=$LASTEXITCODE). Update check may be stale."
            Write-DebugLog "WARN" "git fetch exit=$LASTEXITCODE -- cannot reliably compare SHAs"
        }

        $localSha  = (& git -C $PSScriptRoot rev-parse HEAD 2>&1).Trim()
        $remoteSha = (& git -C $PSScriptRoot rev-parse origin/main 2>&1).Trim()
        Write-DebugLog "VAR localSHA=$localSha remoteSHA=$remoteSha"

        if ($localSha -ne $remoteSha) {
            $changelog = & git -C $PSScriptRoot log --oneline HEAD..origin/main 2>&1
            Write-Host ""
            Write-Host "  Project update available:" -ForegroundColor Yellow
            foreach ($line in $changelog) { Write-Host "    $line" -ForegroundColor DarkGray }
            Write-Host ""

            $apply = $AutoApprove
            if (-not $apply) {
                $answer = Read-Host "  Apply project update? [Y/n]"
                $apply = ($answer -eq "" -or $answer -match '^[Yy]')
            }

            if ($apply) {
                Write-Host "  -> Applying project update (git pull)..." -ForegroundColor Yellow
                Write-DebugLog "INFO" "Running git pull origin main"
                & git -C $PSScriptRoot pull origin main 2>&1 | Out-Null
                Write-Host "  -> Project updated. Re-launching update script..." -ForegroundColor Green
                Write-DebugLog "INFO" "Self-update applied. Re-executing master_update.ps1."
                $relaunchArgs = @()
                if ($AutoApprove) { $relaunchArgs += "-AutoApprove" }
                & powershell.exe -ExecutionPolicy Bypass -File "$PSScriptRoot\master_update.ps1" @relaunchArgs
                exit $LASTEXITCODE
            } else {
                Write-Host "  -> Project update skipped." -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Self-update skipped by user."
            }
        } else {
            Write-Host "  -> Project scripts are up to date." -ForegroundColor Green
            Write-DebugLog "INFO" "No project updates (HEAD == origin/main)"
        }
    } catch {
        Write-Warning "  -> Could not check for project updates (git error): $_"
        Write-DebugLog "WARN" "Self-update git check failed: $_"
    }
} else {
    Write-Host "  -> Not a git repository. Skipping project self-update." -ForegroundColor DarkGray
    Write-Host "     (Clone the repo with git to enable automatic project updates.)" -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Skipping self-update: not a git repository"
}

# -----------------------------------------------------------------------------
# PHASE 2: Fetch remote versions.json
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Versions] Fetching remote version manifest..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Fetch remote versions.json ==="

$LocalVersionsPath = Join-Path $PSScriptRoot "versions.json"
if (-not (Test-Path $LocalVersionsPath)) {
    Write-Error "Local versions.json not found. Cannot perform update."
    exit 1
}
$LocalVersions = Get-Content -Raw $LocalVersionsPath | ConvertFrom-Json

$RemoteVersionsUrl = $LocalVersions.github_raw_url
if (-not $RemoteVersionsUrl) {
    $RemoteVersionsUrl = "https://raw.githubusercontent.com/viperaxz/torrents-arr-us/main/versions.json"
}

try {
    $RemoteVersions = Invoke-RestMethod -Uri $RemoteVersionsUrl -UseBasicParsing
    Write-Host "  -> Remote manifest loaded (schema $($RemoteVersions.schema), updated $($RemoteVersions.updated))." -ForegroundColor Green
    Write-DebugLog "INFO" "Remote versions.json loaded. updated=$($RemoteVersions.updated)"
} catch {
    Write-Warning "  -> Could not fetch remote versions.json: $_"
    Write-Warning "     Using local versions.json for update check."
    Write-DebugLog "WARN" "Remote versions.json fetch failed: $_. Using local."
    $RemoteVersions = $LocalVersions
}

# -----------------------------------------------------------------------------
# PHASE 3: Compare installed versions vs manifest
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Versions] Comparing installed versions..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Version comparison ==="

function Get-InstalledVersion([string]$AppName) {
    $lower    = $AppName.ToLower()
    $lockFile = Join-Path $LocksDir ".$lower.lock"
    if (Test-Path $lockFile) {
        $v = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v) { return $v } else { return "unknown" }
    }
    return $null   # not installed
}

$updates = [System.Collections.Generic.List[hashtable]]::new()
$appOrder = @("Sonarr","Radarr","Prowlarr","Bazarr","Flaresolverr","Jellyfin","Deluge","ffmpeg","Caddy")

foreach ($appName in $appOrder) {
    $manifestEntry = $RemoteVersions.apps.$appName
    if (-not $manifestEntry) { continue }

    $manifestVer  = $manifestEntry.version
    $installedVer = Get-InstalledVersion $appName

    if ($null -eq $installedVer) {
        Write-Host ("  {0,-15} not installed (skipping)" -f $appName) -ForegroundColor DarkGray
        continue
    }
    if ($installedVer -eq "unknown") {
        Write-Host ("  {0,-15} installed (version unknown) -> {1}" -f $appName, $manifestVer) -ForegroundColor DarkGray
        continue
    }

    $normalInstalledVer  = $installedVer.TrimStart('v')
    $normalManifestVer   = $manifestVer.TrimStart('v')

    if ($normalInstalledVer -ne $normalManifestVer) {
        $securityFlag = ($manifestEntry.PSObject.Properties["security"] -and $manifestEntry.security -eq $true)
        $noteText     = if ($manifestEntry.PSObject.Properties["securityNote"]) { $manifestEntry.securityNote } else { "" }
        $color        = if ($securityFlag) { "Red" } else { "Yellow" }
        $tag          = if ($securityFlag) { " [SECURITY]" } else { "" }
        Write-Host ("  {0,-15} {1} -> {2}{3}" -f $appName, $installedVer, $manifestVer, $tag) -ForegroundColor $color
        if ($securityFlag -and $noteText) { Write-Host ("               {0}" -f $noteText) -ForegroundColor Red }
        $updates.Add(@{
            Name         = $appName
            Installed    = $installedVer
            Manifest     = $manifestVer
            Source       = $manifestEntry.source
            Security     = $securityFlag
            SecurityNote = $noteText
            Entry        = $manifestEntry
        })
    } else {
        Write-Host ("  {0,-15} {1} (up to date)" -f $appName, $installedVer) -ForegroundColor Green
    }
}
Write-DebugLog "INFO" "Version comparison complete. Updates pending: $($updates.Count)"

if ($updates.Count -eq 0) {
    Write-Host ""
    Write-Host "All apps are up to date." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "$($updates.Count) update(s) available." -ForegroundColor Yellow

$proceed = $AutoApprove
if (-not $proceed) {
    $answer = Read-Host "Apply all updates? [Y/n]"
    $proceed = ($answer -eq "" -or $answer -match '^[Yy]')
}
if (-not $proceed) {
    Write-Host "Update cancelled." -ForegroundColor DarkGray
    exit 0
}

# -----------------------------------------------------------------------------
# PHASE 4: Apply updates
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Update] Applying updates..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Apply updates ==="

$updateResults = @{}

foreach ($upd in $updates) {
    $appName  = $upd.Name
    $newVer   = $upd.Manifest
    $source   = $upd.Source
    $entry    = $upd.Entry

    if ($upd.Security -and $upd.SecurityNote) {
        Write-Host ""
        Write-Host "  [SECURITY] $appName - $($upd.SecurityNote)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Updating $appName $($upd.Installed) -> $newVer ..." -ForegroundColor Cyan
    Write-DebugLog "INFO" "Updating $($appName): $($upd.Installed) -> $newVer (source=$source)"

    try {
        if ($source -eq "chocolatey") {
            # -- Choco upgrade ------------------------------------------------
            $pkg = $entry.package
            Write-Host "    choco upgrade $pkg --version $newVer" -ForegroundColor Gray
            choco upgrade $pkg --version $newVer -y --no-progress | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "choco upgrade exited with code $LASTEXITCODE" }
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

        } elseif ($source -eq "github") {
            # -- GitHub binary swap with rollback -----------------------------
            $appBinDir = Join-Path $InstallDir $appName
            $appBinBak = "$appBinDir.bak"
            $assetPattern = $entry.asset
            $repo         = $entry.repo

            # Download the new release zip
            $apiUri = "https://api.github.com/repos/$repo/releases/tags/$newVer"
            Write-Host "    Fetching $apiUri ..." -ForegroundColor Gray
            $release = Invoke-RestMethod -Uri $apiUri -UseBasicParsing
            $asset   = $release.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
            if (-not $asset) { throw "No asset matching '$assetPattern' in release $newVer" }

            $zipName = if ($appName -in @("Bazarr","Flaresolverr")) {
                "$($appName.ToLower())-$newVer.zip"
            } else {
                $asset.name
            }
            $zipPath = Join-Path $BinDir $zipName
            if (-not (Test-Path $zipPath)) {
                Write-Host "    Downloading $($asset.name)..." -ForegroundColor Gray
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
                Write-DebugLog "INFO" "Downloaded $($asset.browser_download_url) -> $zipPath"
            } else {
                Write-Host "    Using cached $zipName." -ForegroundColor Gray
            }

            # Stop service
            $svc = Get-Service -Name $appName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Write-Host "    Stopping $appName service..." -ForegroundColor Gray
                Stop-Service -Name $appName -Force
                Start-Sleep -Seconds 3
            }

            # Backup existing binaries
            if (Test-Path $appBinBak) { Remove-Item $appBinBak -Recurse -Force }
            if (Test-Path $appBinDir) {
                Rename-Item -Path $appBinDir -NewName "$appName.bak" -Force
                Write-DebugLog "INFO" "Backed up $appBinDir to $appBinBak"
            }

            # Extract new binaries
            New-Item -Path $appBinDir -ItemType Directory -Force | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $appBinDir -Force

            # Flatten single-directory zips (Bazarr, Flaresolverr pattern)
            $children = Get-ChildItem $appBinDir
            if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
                $inner = $children[0].FullName
                Get-ChildItem $inner | ForEach-Object { Move-Item $_.FullName $appBinDir -Force }
                Remove-Item $inner -Recurse -Force
            }

            # Restart service
            Start-Service -Name $appName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10

            # Health check  --  service must be Running
            $svcAfter = Get-Service -Name $appName -ErrorAction SilentlyContinue
            if (-not $svcAfter -or $svcAfter.Status -ne "Running") {
                Write-Warning "    Health check FAILED for $appName  --  rolling back."
                Write-DebugLog "WARN" "$appName health check failed. Rolling back."

                Stop-Service -Name $appName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                if (Test-Path $appBinDir)  { Remove-Item $appBinDir  -Recurse -Force }
                if (Test-Path $appBinBak)  { Rename-Item -Path $appBinBak -NewName $appName -Force }
                Start-Service -Name $appName -ErrorAction SilentlyContinue

                $updateResults[$appName] = "ROLLBACK"
                continue
            }

            # Success: remove backup, clean old cached zips for this app
            if (Test-Path $appBinBak) { Remove-Item $appBinBak -Recurse -Force }
            Get-ChildItem $BinDir -Filter "$($appName.ToLower())-*.zip" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $zipName } |
                ForEach-Object { Remove-Item $_.FullName -Force }
            Get-ChildItem $BinDir -Filter "$appName.*.zip" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $asset.name } |
                ForEach-Object { Remove-Item $_.FullName -Force }

        } elseif ($source -eq "github_source") {
            Write-Host "    $appName is built from source and cannot be auto-updated." -ForegroundColor DarkYellow
            Write-Host "    Run: .\master_install.ps1 -Force $appName" -ForegroundColor DarkYellow
            $updateResults[$appName] = "SKIPPED (source build)"
            continue

        } else {
            Write-Warning "    Unknown source '$source' for $appName. Skipping."
            $updateResults[$appName] = "SKIPPED (unknown source)"
            continue
        }

        # Write updated lock file
        $lower    = $appName.ToLower()
        $lockFile = Join-Path $LocksDir ".$lower.lock"
        [System.IO.File]::WriteAllText($lockFile, $newVer, [System.Text.Encoding]::UTF8)
        Write-Host "    $appName updated to $newVer." -ForegroundColor Green
        Write-DebugLog "INFO" "$appName successfully updated to $newVer"
        $updateResults[$appName] = "OK"

    } catch {
        Write-Warning "    Update FAILED for $appName : $_"
        Write-DebugLog "ERROR" "$appName update failed: $_"
        $updateResults[$appName] = "FAILED: $_"
    }
}

# -----------------------------------------------------------------------------
# PHASE 5: Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Update Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

foreach ($upd in $updates) {
    $result = $updateResults[$upd.Name]
    $color  = switch -Wildcard ($result) {
        "OK"       { "Green" }
        "ROLLBACK" { "Red" }
        "FAILED*"  { "Red" }
        default    { "DarkYellow" }
    }
    Write-Host ("  {0,-15} {1}" -f $upd.Name, $result) -ForegroundColor $color
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-DebugLog "INFO" "master_update.ps1 finished."
