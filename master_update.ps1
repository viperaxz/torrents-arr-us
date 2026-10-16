param(
    [switch]$AutoApprove,  # skip all confirmation prompts
    [string]$App = "",     # update only the named app (manifest key, e.g. "Sonarr")
    [switch]$WhatIf         # print the update plan without applying anything
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
. (Join-Path $PSScriptRoot "scripts\update_common.ps1")
Write-DebugLog "INFO" "master_update.ps1 started. AutoApprove=$AutoApprove App=$App WhatIf=$WhatIf"

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
                if ($App)        { $relaunchArgs += "-App"; $relaunchArgs += $App }
                if ($WhatIf)     { $relaunchArgs += "-WhatIf" }
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

$RemoteVersions = Get-RemoteManifest -LocalManifest $LocalVersions -Url $RemoteVersionsUrl
if ([object]::ReferenceEquals($RemoteVersions, $LocalVersions)) {
    Write-Warning "  -> Could not fetch remote versions.json. Using local versions.json for update check."
    Write-DebugLog "WARN" "Remote versions.json fetch failed. Using local."
} else {
    Write-Host "  -> Remote manifest loaded (schema $($RemoteVersions.schema), updated $($RemoteVersions.updated))." -ForegroundColor Green
    Write-DebugLog "INFO" "Remote versions.json loaded. updated=$($RemoteVersions.updated)"
}

# Attach the manifest to the config object so per-app update scripts can read
# repo/asset/package metadata (same convention as master_install.ps1).
$Config | Add-Member -MemberType NoteProperty -Name "_Versions" -Value $RemoteVersions -Force

# -----------------------------------------------------------------------------
# PHASE 3: Compare installed versions vs manifest (data-driven plan)
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Versions] Comparing installed versions..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Version comparison ==="

$ScriptsDir = Join-Path $PSScriptRoot "scripts"

# Self-heal: detect real versions for apps whose legacy lock files stored
# timestamps or placeholders ("installed", empty), and for apps installed
# before the ledger existed (Loki, Alloy, Recyclarr, CrowdSec have no lock
# files at all).  Record everything found in the ledger.
foreach ($prop in $RemoteVersions.apps.PSObject.Properties) {
    $appName   = $prop.Name
    $installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $appName
    if ($installed -ieq "unknown" -or $null -eq $installed) {
        $detected = Detect-InstalledVersion -AppName $appName -Entry $prop.Value -InstallDir $InstallDir
        if ($detected) {
            Set-InstalledVersion -InstallDir $InstallDir -AppName $appName -Version $detected
            Write-Host ("  {0,-18} detected installed version: {1}" -f $appName, $detected) -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Ledger migration: $appName -> $detected"
        }
    }
}

$plan = @(Get-UpdatePlan -Manifest $RemoteVersions -InstallDir $InstallDir -ScriptsDir $ScriptsDir) |
    Sort-Object App

foreach ($item in $plan) {
    switch ($item.State) {
        "current" {
            Write-Host ("  {0,-18} {1} (up to date)" -f $item.App, $item.Installed) -ForegroundColor Green
        }
        "notinstalled" {
            Write-Host ("  {0,-18} not installed (skipping)" -f $item.App) -ForegroundColor DarkGray
        }
        "unresolved" {
            Write-Host ("  {0,-18} target version unresolved (skipping)" -f $item.App) -ForegroundColor DarkGray
        }
        "unknown" {
            Write-Host ("  {0,-18} installed (version unknown) -> {1} (re-run installer to re-register)" -f $item.App, $item.Target) -ForegroundColor DarkGray
        }
        "manual" {
            Write-Host ("  {0,-18} {1} -> {2} (manual: .\master_install.ps1 -Force {0})" -f $item.App, $item.Installed, $item.Target) -ForegroundColor DarkYellow
        }
        "update" {
            $color = if ($item.Security) { "Red" } else { "Yellow" }
            $tag   = if ($item.Security) { " [SECURITY]" } else { "" }
            Write-Host ("  {0,-18} {1} -> {2}{3}" -f $item.App, $item.Installed, $item.Target, $tag) -ForegroundColor $color
            if ($item.Security -and $item.SecurityNote) {
                Write-Host ("                    {0}" -f $item.SecurityNote) -ForegroundColor Red
            }
        }
    }
}

$updates = @($plan | Where-Object { $_.State -eq "update" })
if ($App) {
    $updates = @($updates | Where-Object { $_.App -ieq $App })
    if ($updates.Count -eq 0) {
        Write-Host ""
        Write-Host "No pending update for '$App'." -ForegroundColor Green
        exit 0
    }
}
Write-DebugLog "INFO" "Version comparison complete. Updates pending: $($updates.Count)"

if ($updates.Count -eq 0) {
    $manual = @($plan | Where-Object { $_.State -eq "manual" })
    Write-Host ""
    if ($manual.Count -gt 0) {
        Write-Host "App updates are up to date." -ForegroundColor Green
        Write-Host "Manual updates (no update script): $($manual.App -join ', ')." -ForegroundColor DarkYellow
        Write-Host "Run: .\master_install.ps1 -Force <AppName>" -ForegroundColor DarkGray
    } else {
        Write-Host "All apps are up to date." -ForegroundColor Green
    }
    exit 0
}

if ($WhatIf) {
    Write-Host ""
    Write-Host "Dry run: $($updates.Count) update(s) would be applied. No changes made." -ForegroundColor Yellow
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
# PHASE 4: Apply updates (per-app update scripts)
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Update] Applying updates..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE: Apply updates ==="

$updateResults = [System.Collections.Generic.List[object]]::new()

foreach ($upd in $updates) {
    if ($upd.Security -and $upd.SecurityNote) {
        Write-Host ""
        Write-Host "  [SECURITY] $($upd.App) - $($upd.SecurityNote)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Updating $($upd.App) $($upd.Installed) -> $($upd.Target) ..." -ForegroundColor Cyan
    Write-DebugLog "INFO" "Updating $($upd.App): $($upd.Installed) -> $($upd.Target) (script=$($upd.ScriptPath))"

    $res = Invoke-UpdateScriptForPlanItem -PlanItem $upd -InstallDir $InstallDir -BinDir $BinDir -Config $Config
    if (-not $res) {
        $res = [PSCustomObject]@{
            App       = $upd.App
            Status    = "FAILED"
            Installed = $upd.Installed
            Target    = $upd.Target
            Detail    = "update script produced no result"
        }
    }
    $updateResults.Add($res)

    if ($res.Status -eq "OK" -and $res.Target) {
        # Keep the legacy lock file in sync (the ledger remains the source of truth).
        $lockFile = Join-Path $LocksDir ".$($upd.App.ToLower()).lock"
        [System.IO.File]::WriteAllText($lockFile, $res.Target, [System.Text.Encoding]::UTF8)
        Write-Host "    $($upd.App) updated to $($res.Target)." -ForegroundColor Green
        Write-DebugLog "INFO" "$($upd.App) successfully updated to $($res.Target)"
    } elseif ($res.Status -eq "SKIPPED") {
        Write-Host "    $($upd.App) skipped: $($res.Detail)" -ForegroundColor DarkYellow
    } else {
        Write-Warning "    $($upd.App): $($res.Status) - $($res.Detail)"
    }
}

# -----------------------------------------------------------------------------
# PHASE 5: Summary
# -----------------------------------------------------------------------------
Write-SummaryTable -Results $updateResults -Title "Update Summary"

$manual = @($plan | Where-Object { $_.State -eq "manual" })
if ($manual.Count -gt 0) {
    Write-Host ""
    Write-Host "  Manual updates (run .\master_install.ps1 -Force <AppName>):" -ForegroundColor DarkYellow
    foreach ($m in $manual) {
        Write-Host ("    {0,-18} {1} -> {2}" -f $m.App, $m.Installed, $m.Target) -ForegroundColor DarkGray
    }
}

Write-DebugLog "INFO" "master_update.ps1 finished."
