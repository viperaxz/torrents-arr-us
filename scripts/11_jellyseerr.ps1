param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging ---------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "11_jellyseerr.ps1 started"

$AppName    = "Jellyseerr"
$AppLower   = "jellyseerr"
$AppPort    = if ($Config.Ports.PSObject.Properties["Jellyseerr"]) { $Config.Ports.Jellyseerr } else { 5055 }
$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir $AppName
$DataDir    = "C:\ProgramData\$AppName"
$LockFile   = Join-Path $InstallDir ".locks\.$AppLower.lock"
$SvcUser    = "seedbox-svc"
$SvcPass    = $Config.General.ServiceAccountPassword

# Subdirectories within AppBinDir
$NodeDir    = Join-Path $AppBinDir "node"
$PnpmExe    = Join-Path $AppBinDir "pnpm.exe"
$AppSrcDir  = Join-Path $AppBinDir "app"
$PnpmHome   = Join-Path $AppBinDir "pnpm-home"

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort"
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR NodeDir=$NodeDir PnpmExe=$PnpmExe AppSrcDir=$AppSrcDir"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Jellyseerr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Jellyseerr != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Get release version from GitHub -----------------------------------------
$BinDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR BinDir=$BinDir"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

Write-Host "  -> Querying latest Jellyseerr version..." -ForegroundColor Gray
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/Fallenbagel/jellyseerr/releases/latest" `
        -UseBasicParsing
    $Version = $Release.tag_name -replace '^v', ''
    Write-DebugLog "VAR Jellyseerr version=$Version"
} catch {
    Write-Error "[$AppName] Failed to query GitHub releases: $_"
    Write-DebugLog "ERROR" "GitHub API query failed: $_"
    exit 1
}

# -- 2. Download portable Node.js 22 LTS ----------------------------------------
$NodeExe = Join-Path $NodeDir "node.exe"
Write-DebugLog "VAR NodeExe=$NodeExe (exists=$(Test-Path $NodeExe))"
if (-not (Test-Path $NodeExe)) {
    Write-Host "  -> Downloading Node.js 22 LTS..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying Node.js release index..."
    try {
        $nodeIndex = Invoke-RestMethod "https://nodejs.org/dist/index.json" -UseBasicParsing
        $node22    = $nodeIndex | Where-Object { $_.version -like "v22.*" -and $_.lts } | Select-Object -First 1
        $NodeVer   = $node22.version
        Write-DebugLog "VAR NodeVer=$NodeVer"
    } catch {
        Write-Error "[$AppName] Failed to get Node.js version: $_"
        exit 1
    }
    $NodeZip = Join-Path $BinDir "node-$NodeVer-win-x64.zip"
    Write-DebugLog "VAR NodeZip=$NodeZip (cached=$(Test-Path $NodeZip))"
    if (-not (Test-Path $NodeZip)) {
        $nodeUrl = "https://nodejs.org/dist/$NodeVer/node-$NodeVer-win-x64.zip"
        Write-Host "  -> Downloading Node.js $NodeVer (~35 MB)..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Downloading: $nodeUrl"
        Invoke-WebRequest -Uri $nodeUrl -OutFile $NodeZip -UseBasicParsing
        Write-DebugLog "INFO" "Node.js download complete: $((Get-Item $NodeZip).Length) bytes"
    }
    Write-Host "  -> Extracting Node.js..." -ForegroundColor Gray
    New-Item -Path $NodeDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $NodeZip -DestinationPath $NodeDir -Force
    $nodeSub = Get-ChildItem $NodeDir -Directory | Select-Object -First 1
    if ($nodeSub) {
        Get-ChildItem $nodeSub.FullName | Move-Item -Destination $NodeDir
        Remove-Item $nodeSub.FullName -Recurse -Force
        Write-DebugLog "INFO" "Node.js flattened from $($nodeSub.Name)"
    }
    Write-DebugLog "INFO" "Node.js ready at $NodeExe"
}

# -- 3. Download pnpm v10.24.0 standalone executable ----------------------------
Write-DebugLog "VAR PnpmExe exists=$(Test-Path $PnpmExe)"
if (-not (Test-Path $PnpmExe)) {
    $PnpmVer    = "10.24.0"
    $pnpmCached = Join-Path $BinDir "pnpm-v$PnpmVer-win-x64.exe"
    Write-DebugLog "VAR pnpmCached=$pnpmCached (exists=$(Test-Path $pnpmCached))"
    if (-not (Test-Path $pnpmCached)) {
        Write-Host "  -> Downloading pnpm v$PnpmVer (~53 MB)..." -ForegroundColor Gray
        $pnpmUrl = "https://github.com/pnpm/pnpm/releases/download/v$PnpmVer/pnpm-win-x64.exe"
        Write-DebugLog "INFO" "Downloading: $pnpmUrl"
        Invoke-WebRequest -Uri $pnpmUrl -OutFile $pnpmCached -UseBasicParsing
        Write-DebugLog "INFO" "pnpm download complete: $((Get-Item $pnpmCached).Length) bytes"
    }
    Copy-Item $pnpmCached $PnpmExe -Force
    Write-DebugLog "INFO" "pnpm.exe ready at $PnpmExe"
}
# Also place pnpm.exe in NodeDir so it is on PATH when build sub-scripts run via cmd.
$PnpmInNode = Join-Path $NodeDir "pnpm.exe"
if (-not (Test-Path $PnpmInNode)) {
    Copy-Item $PnpmExe $PnpmInNode -Force
    Write-DebugLog "INFO" "pnpm.exe copied to NodeDir for PATH availability"
}

# -- 4. Download Jellyseerr source ----------------------------------------------
$SrcZip = Join-Path $BinDir "jellyseerr-v$Version-source.zip"
Write-DebugLog "VAR SrcZip=$SrcZip (cached=$(Test-Path $SrcZip))"
if (-not (Test-Path $SrcZip)) {
    $srcUrl = "https://github.com/Fallenbagel/jellyseerr/archive/refs/tags/v$Version.zip"
    Write-Host "  -> Downloading Jellyseerr v$Version source..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Downloading: $srcUrl"
    Invoke-WebRequest -Uri $srcUrl -OutFile $SrcZip -UseBasicParsing
    Write-DebugLog "INFO" "Source download complete: $((Get-Item $SrcZip).Length) bytes"
}

# -- 5. Extract source ----------------------------------------------------------
Write-Host "  -> Extracting source..." -ForegroundColor Gray
$existingSvc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
if (Test-Path $AppSrcDir) {
    Remove-Item $AppSrcDir -Recurse -Force
}
New-Item -Path $AppSrcDir -ItemType Directory -Force | Out-Null
Expand-Archive -Path $SrcZip -DestinationPath $AppSrcDir -Force
$srcSub = Get-ChildItem $AppSrcDir -Directory | Select-Object -First 1
if ($srcSub) {
    Get-ChildItem $srcSub.FullName | Move-Item -Destination $AppSrcDir
    Remove-Item $srcSub.FullName -Recurse -Force
    Write-DebugLog "INFO" "Source flattened from $($srcSub.Name)"
}
Write-DebugLog "INFO" "Source extracted to $AppSrcDir"

# -- 6. Build: pnpm install + pnpm build ----------------------------------------
$logsDir = Join-Path $InstallDir "logs"
if (-not (Test-Path $logsDir)) { New-Item $logsDir -ItemType Directory -Force | Out-Null }
$BuildLogFile = Join-Path $logsDir "jellyseerr_build.log"

# Allow unrs-resolver (Rust DNS resolver) to run its native build script.
# pnpm 10+ blocks build scripts by default for security; this package needs it.
# Instead of fragile JSON manipulation on package.json (which varies between
# Jellyseerr releases), write a local .npmrc that tells pnpm to trust it.
$NpmrcFile = Join-Path $AppSrcDir ".npmrc"
try {
    $npmrcContent = "onlyBuiltDependencies[]=unrs-resolver"
    [System.IO.File]::WriteAllText($NpmrcFile, $npmrcContent, [System.Text.Encoding]::ASCII)
    Write-DebugLog "INFO" "Wrote .npmrc to approve unrs-resolver build scripts"
} catch {
    Write-DebugLog "WARN" "Could not write .npmrc for unrs-resolver: $_"
}

Write-Host "  -> Installing dependencies (several minutes)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Running pnpm install --frozen-lockfile. Build log: $BuildLogFile"

$savedPath  = $env:PATH
$env:PATH   = "$NodeDir;" + $env:PATH
$env:PNPM_HOME = $PnpmHome
$env:CI     = "true"
$env:NODE_OPTIONS = "--max-old-space-size=4096"

Push-Location $AppSrcDir
# master_install sets $ErrorActionPreference="Stop"; pnpm/Next.js write to stderr which
# PowerShell wraps as ErrorRecord objects in the 2>&1 pipeline -- with EAP=Stop that
# throws immediately before the build finishes. Save/restore around each pnpm call.
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $installOut = & "$PnpmExe" install --frozen-lockfile 2>&1 | ForEach-Object { "$_" }
    $installExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    $installOut | Out-File $BuildLogFile -Encoding utf8 -Force
    Write-DebugLog "VAR pnpm install exit=$installExit"
    if ($installExit -ne 0) {
        (Get-Content $BuildLogFile -Tail 30) | ForEach-Object { Write-DebugLog "ERROR" "pnpm-install: $_" }
        Write-Error "[$AppName] pnpm install failed (exit=$installExit). See $BuildLogFile"
        exit 1
    }

    Write-Host "  -> Building Jellyseerr (5-10 min, please wait)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Running pnpm run build..."
    $ErrorActionPreference = "Continue"
    $buildOut = & "$PnpmExe" run build 2>&1 | ForEach-Object { "$_" }
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $savedEAP
    $buildOut | Out-File $BuildLogFile -Append -Encoding utf8
    Write-DebugLog "VAR pnpm build exit=$buildExit"
    if ($buildExit -ne 0) {
        (Get-Content $BuildLogFile -Tail 30) | ForEach-Object { Write-DebugLog "ERROR" "pnpm-build: $_" }
        Write-Error "[$AppName] pnpm build failed (exit=$buildExit). See $BuildLogFile"
        exit 1
    }
} finally {
    Pop-Location
    $ErrorActionPreference = $savedEAP
    $env:PATH = $savedPath
    Remove-Item Env:\PNPM_HOME    -ErrorAction SilentlyContinue
    Remove-Item Env:\CI            -ErrorAction SilentlyContinue
    Remove-Item Env:\NODE_OPTIONS  -ErrorAction SilentlyContinue
}

$ServerJs = Join-Path $AppSrcDir "dist\index.js"
Write-DebugLog "VAR ServerJs=$ServerJs (exists=$(Test-Path $ServerJs))"
if (-not (Test-Path $ServerJs)) {
    Write-Error "[$AppName] dist\index.js not found after build. See $BuildLogFile"
    exit 1
}
Write-Host "  -> Build complete." -ForegroundColor Green
Write-DebugLog "INFO" "Build complete. dist\index.js present."

# -- 7. Directories + permissions -----------------------------------------------
New-Item -Path $DataDir  -ItemType Directory -Force | Out-Null
New-Item -Path $PnpmHome -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
Grant-SeedboxDirAccess -Path $AppBinDir -Username $SvcUser
Grant-SeedboxDirAccess -Path $DataDir   -Username $SvcUser
Write-DebugLog "INFO" "Directories and ACLs set for $AppName"

# -- 8. Windows service via NSSM ------------------------------------------------
Write-Host "  -> Creating Windows service..." -ForegroundColor Gray
$svcExists = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svcExists)"

if (-not $svcExists) {
    Write-DebugLog "INFO" "Creating NSSM service '$AppName' node=$NodeExe script=$ServerJs"
    nssm install $AppName "`"$NodeExe`"" "`"$ServerJs`"" | Out-Null
    nssm set $AppName AppDirectory   $AppSrcDir | Out-Null
    nssm set $AppName Description    "Jellyseerr - Media request portal for Jellyfin" | Out-Null
    nssm set $AppName Start          SERVICE_AUTO_START | Out-Null
    nssm set $AppName AppStdout      (Join-Path $DataDir "jellyseerr-stdout.log") | Out-Null
    nssm set $AppName AppStderr      (Join-Path $DataDir "jellyseerr-stderr.log") | Out-Null
    nssm set $AppName ObjectName     ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    nssm set $AppName AppEnvironmentExtra "CONFIG_DIRECTORY=$DataDir" "PORT=$AppPort" "NODE_ENV=production" | Out-Null
    Write-Host "  -> Service '$AppName' created under '$SvcUser'." -ForegroundColor Gray
    Write-DebugLog "INFO" "NSSM service '$AppName' created. PORT=$AppPort CONFIG_DIRECTORY=$DataDir"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists - skipping creation"
}

# -- 9. Firewall ----------------------------------------------------------------
# LAN-scoped: Caddy proxies over loopback, so exposing this port to the internet
# would only bypass basic-auth and CrowdSec detection. See 03_sonarr.ps1.
New-NetFirewallRule -DisplayName "Jellyseerr" -Direction Inbound -LocalPort $AppPort `
    -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for $AppName port=$AppPort"

# -- 10. Start and wait for API -------------------------------------------------
Write-Host "  -> Starting $AppName (first start initialises the database, allow 3 min)..." `
    -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName service. Waiting up to 180s for API readiness..."
Start-Service -Name $AppName -ErrorAction SilentlyContinue

$deadline = (Get-Date).AddSeconds(180)
$started  = $false
$waited   = 0
while (-not $started -and (Get-Date) -lt $deadline) {
    try {
        $statusResp = Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/v1/status" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $started = $true
        Write-DebugLog "VAR status: version=$($statusResp.version) isSetupDone=$($statusResp.isSetupDone)"
    } catch { Start-Sleep -Seconds 5; $waited += 5 }
}
Write-DebugLog "VAR Jellyseerr API responded=$started waited=${waited}s"

$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    Write-Warning "  -> $AppName may not have started. Check $DataDir\jellyseerr-stderr.log"
    Write-DebugLog "WARN" "$AppName may not be running. Check $DataDir\jellyseerr-stderr.log"
}

New-Item -Path $LockFile -ItemType File -Force | Out-Null
Write-DebugLog "INFO" "Lock file created: $LockFile"
Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "11_jellyseerr.ps1 complete"
