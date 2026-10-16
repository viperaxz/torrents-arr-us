# update_jellyseerr.ps1
# Per-app update script: Jellyseerr (source rebuild).
# Jellyseerr has no prebuilt Windows binary.  This script downloads the source
# archive for the pinned tag, rebuilds it with the installed portable
# Node.js + pnpm, and swaps the app directory with rollback.
#
# NOTE: This takes several minutes (pnpm install + Next.js build).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName     = "Jellyseerr"
$ServiceName = "Jellyseerr"
$AppBinDir   = Join-Path $InstallDir $AppName
$NodeDir     = Join-Path $AppBinDir "node"
$PnpmExe     = Join-Path $AppBinDir "pnpm.exe"
$PnpmHome    = Join-Path $AppBinDir "pnpm-home"
$AppSrcDir   = Join-Path $AppBinDir "app"
$NewSrcDir   = Join-Path $AppBinDir "app-new"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "source rebuild via pnpm (several minutes)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    if (-not (Test-Path $PnpmExe)) { throw "pnpm.exe not found at $PnpmExe -- reinstall Jellyseerr first" }
    if (-not (Test-Path $NodeDir)) { throw "portable Node.js not found at $NodeDir -- reinstall Jellyseerr first" }

    $vNum = $Version -replace '^v', ''

    # -- 1. Download source archive -------------------------------------------
    $srcZip = Join-Path $BinDir "jellyseerr-v$vNum-source.zip"
    if (-not (Test-Path $srcZip)) {
        $srcUrl = "https://github.com/Fallenbagel/jellyseerr/archive/refs/tags/v$vNum.zip"
        Write-Host "  -> Downloading Jellyseerr v$vNum source..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $srcUrl -OutFile $srcZip -UseBasicParsing -ErrorAction Stop
    }

    # -- 2. Extract to app-new -------------------------------------------------
    if (Test-Path $NewSrcDir) { Remove-Item $NewSrcDir -Recurse -Force }
    New-Item -Path $NewSrcDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $srcZip -DestinationPath $NewSrcDir -Force
    $srcSub = Get-ChildItem $NewSrcDir -Directory | Select-Object -First 1
    if ($srcSub) {
        Get-ChildItem $srcSub.FullName | Move-Item -Destination $NewSrcDir
        Remove-Item $srcSub.FullName -Recurse -Force
    }

    # -- 3. Build --------------------------------------------------------------
    $logsDir = Join-Path $InstallDir "logs"
    if (-not (Test-Path $logsDir)) { New-Item -Path $logsDir -ItemType Directory -Force | Out-Null }
    $buildLog = Join-Path $logsDir "jellyseerr_update_build.log"

    $npmrcFile = Join-Path $NewSrcDir ".npmrc"
    try {
        [System.IO.File]::WriteAllText($npmrcFile, "onlyBuiltDependencies[]=unrs-resolver", [System.Text.Encoding]::ASCII)
    } catch {}

    Write-Host "  -> Building Jellyseerr (5-10 min, please wait)..." -ForegroundColor Gray
    $savedPath  = $env:PATH
    $env:PATH   = "$NodeDir;" + $env:PATH
    $env:PNPM_HOME = $PnpmHome
    $env:CI     = "true"
    $env:NODE_OPTIONS = "--max-old-space-size=4096"

    Push-Location $NewSrcDir
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $installOut = & "$PnpmExe" install --frozen-lockfile 2>&1 | ForEach-Object { "$_" }
        $installExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP
        $installOut | Out-File $buildLog -Encoding utf8 -Force
        if ($installExit -ne 0) { throw "pnpm install failed (exit=$installExit)" }

        $ErrorActionPreference = "Continue"
        $buildOut = & "$PnpmExe" run build 2>&1 | ForEach-Object { "$_" }
        $buildExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP
        $buildOut | Out-File $buildLog -Append -Encoding utf8
        if ($buildExit -ne 0) { throw "pnpm build failed (exit=$buildExit)" }
    } finally {
        Pop-Location
        $ErrorActionPreference = $savedEAP
        $env:PATH = $savedPath
        Remove-Item Env:\PNPM_HOME    -ErrorAction SilentlyContinue
        Remove-Item Env:\CI            -ErrorAction SilentlyContinue
        Remove-Item Env:\NODE_OPTIONS  -ErrorAction SilentlyContinue
    }

    $serverJs = Join-Path $NewSrcDir "dist\index.js"
    if (-not (Test-Path $serverJs)) { throw "dist\index.js not found after build" }

    # -- 4. Swap with rollback --------------------------------------------------
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Stop-Service -Name $ServiceName -Force }
    Start-Sleep -Seconds 3

    $appBak = "$AppSrcDir.bak"
    if (Test-Path $appBak) { Remove-Item $appBak -Recurse -Force }
    if (Test-Path $AppSrcDir) { Rename-Item -Path $AppSrcDir -NewName "app.bak" -Force }
    Rename-Item -Path $NewSrcDir -NewName "app" -Force

    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 20
    $svcAfter = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "Jellyseerr service not Running after swap" }

    if (Test-Path $appBak) { Remove-Item $appBak -Recurse -Force }
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    # Rollback: restore the previous app directory, but only when the backup
    # rename actually happened.  Failures during download or build leave the
    # live app directory untouched.
    $appBak = "$AppSrcDir.bak"
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (Test-Path $appBak) {
        if (Test-Path $AppSrcDir) { Remove-Item $AppSrcDir -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $appBak -NewName "app" -Force
    }
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
