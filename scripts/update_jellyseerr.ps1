# update_jellyseerr.ps1
# Per-app update script: Jellyseerr (source rebuild).
# Jellyseerr has no prebuilt Windows binary.  This script downloads the source
# archive for the pinned tag (upstream repo is seerr-team/seerr), refreshes the
# bundled portable Node.js 22 LTS, rebuilds with pnpm, and swaps the app
# directory with rollback.
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
$NodeExe     = Join-Path $NodeDir "node.exe"
$NodeStageDir = Join-Path $AppBinDir "node-new"
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

    # -- 0. Stage the newest portable Node.js 22 LTS ---------------------------
    # The installer always resolves the newest 22.x LTS, but an in-place update
    # used to keep whatever runtime was bundled at install time -- so Node
    # security fixes (22.23.4 distrusted the compromised eMudhra intermediate
    # CAs, shipped with Seerr 3.5.1) never reached an existing install.  Stage
    # the runtime here; it is built with below and swapped in while the service
    # is stopped.  A failed index lookup keeps the bundled runtime.
    $nodeHave = if (Test-Path $NodeExe) { (& $NodeExe --version 2>$null) } else { "" }
    $nodeWant = $null
    try {
        $nodeIndex = Invoke-RestMethod "https://nodejs.org/dist/index.json" -UseBasicParsing -ErrorAction Stop
        $node22    = $nodeIndex | Where-Object { $_.version -like "v22.*" -and $_.lts } | Select-Object -First 1
        if ($node22) { $nodeWant = $node22.version }
    } catch {
        Write-Warning "  -> Node.js release index unavailable; keeping the bundled runtime."
    }
    $stageNode = [bool]($nodeWant -and $nodeHave -ne $nodeWant)
    if ($stageNode) {
        Write-Host "  -> Staging Node.js $nodeWant (bundled: $(if ($nodeHave) { $nodeHave } else { 'unknown' }))..." -ForegroundColor Gray
        $nodeZip = Join-Path $BinDir "node-$nodeWant-win-x64.zip"
        if (-not (Test-Path $nodeZip)) {
            Invoke-WebRequest -Uri "https://nodejs.org/dist/$nodeWant/node-$nodeWant-win-x64.zip" -OutFile $nodeZip -UseBasicParsing -ErrorAction Stop
        }
        if (Test-Path $NodeStageDir) { Remove-Item $NodeStageDir -Recurse -Force }
        Expand-Archive -Path $nodeZip -DestinationPath $NodeStageDir -Force
        $nodeSub = Get-ChildItem $NodeStageDir -Directory | Select-Object -First 1
        if ($nodeSub) {
            Get-ChildItem $nodeSub.FullName | Move-Item -Destination $NodeStageDir
            Remove-Item $nodeSub.FullName -Recurse -Force
        }
        # The installer also drops pnpm.exe beside node.exe so build sub-scripts
        # find it on PATH; keep that invariant in the refreshed runtime.
        if (Test-Path $PnpmExe) { Copy-Item $PnpmExe (Join-Path $NodeStageDir "pnpm.exe") -Force }
    }

    $vNum = $Version -replace '^v', ''

    # -- 1. Download source archive -------------------------------------------
    $srcZip = Join-Path $BinDir "jellyseerr-v$vNum-source.zip"
    if (-not (Test-Path $srcZip)) {
        $srcUrl = "https://github.com/seerr-team/seerr/archive/refs/tags/v$vNum.zip"
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
        # Merge instead of overwrite: the source archive ships .npmrc with
        # engine-strict=true and its allow-list in package.json#pnpm.onlyBuiltDependencies.
        # pnpm 10 blocks dependency build scripts unless allow-listed, so both lists
        # are combined (a bare overwrite would drop the upstream settings).
        $npmrcLines = @()
        if (Test-Path $npmrcFile) {
            $npmrcLines = @(Get-Content -Path $npmrcFile -ErrorAction Stop |
                Where-Object { $_ -notmatch '^\s*onlyBuiltDependencies(\[\])?\s*=' })
        }
        $buildDeps = @("unrs-resolver")
        $pkgJson = Join-Path $NewSrcDir "package.json"
        if (Test-Path $pkgJson) {
            try {
                $pkg = Get-Content -Raw -Path $pkgJson | ConvertFrom-Json
                if ($pkg.pnpm -and $pkg.pnpm.PSObject.Properties["onlyBuiltDependencies"] -and $pkg.pnpm.onlyBuiltDependencies) {
                    $buildDeps += @($pkg.pnpm.onlyBuiltDependencies | ForEach-Object { [string]$_ })
                }
            } catch {}
        }
        $buildDeps = @($buildDeps | Where-Object { $_ } | Select-Object -Unique)
        $npmrcLines += @($buildDeps | ForEach-Object { "onlyBuiltDependencies[]=$_" })
        [System.IO.File]::WriteAllLines($npmrcFile, $npmrcLines, [System.Text.Encoding]::ASCII)
    } catch {}

    Write-Host "  -> Building Jellyseerr (5-10 min, please wait)..." -ForegroundColor Gray
    $savedPath  = $env:PATH
    # Build with the runtime that will actually serve the app, not the stale one.
    $BuildNodeDir = if ($stageNode) { $NodeStageDir } else { $NodeDir }
    $env:PATH   = "$BuildNodeDir;" + $env:PATH
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
    # Never Stop-Service here: an nssm service wedged in Stop Pending blocks it
    # forever (see service_helpers.ps1), and Jellyseerr -- which logs at debug and
    # writes a lot to stdout -- is the worst offender in this suite.
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { $null = Stop-UpdateService -Name $ServiceName }
    Start-Sleep -Seconds 3

    # Swap the staged runtime first: the service points at node\node.exe, so the
    # path stays valid and the new bundle boots on the patched Node.
    if ($stageNode -and (Test-Path $NodeStageDir)) {
        $nodeBak = "$NodeDir.bak"
        if (Test-Path $nodeBak) { Remove-Item $nodeBak -Recurse -Force }
        if (Test-Path $NodeDir) { Rename-Item -Path $NodeDir -NewName "node.bak" -Force }
        Rename-Item -Path $NodeStageDir -NewName "node" -Force
        Write-Host "  -> Node.js runtime refreshed to $nodeWant." -ForegroundColor Gray
    }

    $appBak = "$AppSrcDir.bak"
    if (Test-Path $appBak) { Remove-Item $appBak -Recurse -Force }
    if (Test-Path $AppSrcDir) { Rename-Item -Path $AppSrcDir -NewName "app.bak" -Force }
    Rename-Item -Path $NewSrcDir -NewName "app" -Force

    $null = Start-ServiceBounded -Name $ServiceName

    # A running NSSM service proves nothing for Jellyseerr: the new bundle runs
    # database migrations on its first boot and can crash-loop afterwards. Poll the
    # API (this is the same endpoint the installer waits on) and let a timeout fall
    # through to the rollback below.
    $apiPort = if ($Config -and $Config.Ports -and $Config.Ports.PSObject.Properties["Jellyseerr"]) {
        $Config.Ports.Jellyseerr
    } else {
        5055
    }
    $deadline = (Get-Date).AddSeconds(180)
    $apiUp = $false
    while (-not $apiUp -and (Get-Date) -lt $deadline) {
        try {
            $status = Invoke-RestMethod -Uri "http://127.0.0.1:$apiPort/api/v1/status" `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($status.version) { $apiUp = $true } else { Start-Sleep -Seconds 5 }
        } catch {
            Start-Sleep -Seconds 5
        }
    }
    if (-not $apiUp) { throw "Jellyseerr API not responding on port $apiPort after swap" }

    $svcAfter = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "Jellyseerr service not Running after swap" }

    if (Test-Path $appBak) { Remove-Item $appBak -Recurse -Force }
    $nodeBak = "$NodeDir.bak"
    if (Test-Path $nodeBak) { Remove-Item $nodeBak -Recurse -Force -ErrorAction SilentlyContinue }
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    # Capture before running anything else: the helpers below emit their own
    # output and this message is what the operator sees in the update report.
    $errMessage = $_.Exception.Message
    # Rollback: restore the previous app directory, but only when the backup
    # rename actually happened.  Failures during download or build leave the
    # live app directory untouched.
    $appBak = "$AppSrcDir.bak"
    $null = Stop-UpdateService -Name $ServiceName
    Start-Sleep -Seconds 3
    if (Test-Path $appBak) {
        if (Test-Path $AppSrcDir) { Remove-Item $AppSrcDir -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $appBak -NewName "app" -Force
    }
    # Restore the previous runtime too: the rollback must leave both halves of
    # the update at the versions that were known to work together.
    $nodeBak = "$NodeDir.bak"
    if (Test-Path $nodeBak) {
        if (Test-Path $NodeDir) { Remove-Item $NodeDir -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $nodeBak -NewName "node" -Force
    }
    if (Test-Path $NodeStageDir) { Remove-Item $NodeStageDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = Start-ServiceBounded -Name $ServiceName
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $errMessage }
}
