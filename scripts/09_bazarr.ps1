param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "09_bazarr.ps1 started"

$AppName    = "Bazarr"
$AppLower   = "bazarr"
$AppPort    = $Config.Ports.Bazarr
$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir $AppName       # Python source lives here
$DataDir    = "C:\ProgramData\$AppName"
$ConfigDir  = Join-Path $DataDir "config"
$ConfigFile = Join-Path $ConfigDir "config.yaml"
$LockFile   = Join-Path $InstallDir ".locks\.$AppLower.lock"
$DomainMode = $Config.General.DomainMode
$SvcUser    = "seedbox-svc"
$SvcPass    = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort"
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir DataDir=$DataDir"
Write-DebugLog "VAR ConfigFile=$ConfigFile"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR DomainMode=$DomainMode SvcUser=$SvcUser"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Bazarr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Bazarr != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- helpers -------------------------------------------------------------------
function Test-YamlNeedsQuoting {
    param([string]$Value)
    # YAML plain scalars cannot contain: : # { } [ ] , & * ? | - < > = ! % @ `
    # They also cannot start with a quote, backtick, or whitespace.
    if ($Value -match '[\:\#\{\}\[\]\,\&\*\?\|\-\<\>\=\!\%\@\`]') { return $true }
    if ($Value -match '^\s') { return $true }
    if ($Value -match '\s$') { return $true }
    if ($Value -match "['`"]") { return $true }
    return $false
}

function Set-YamlKey {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    Write-DebugLog "INFO" "Set-YamlKey: file=$Path section=$Section key=$Key value=$Value"
    $quotedValue = if (Test-YamlNeedsQuoting $Value) { "'$Value'" } else { $Value }
    $lines     = Get-Content $Path
    $inSection = $false
    $found     = $false
    $sectionIndent = ""
    $out       = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        if ($line -match "^(\s*)$([regex]::Escape($Section)):") {
            $inSection = $true
            $sectionIndent = $Matches[1]
            $out.Add($line); continue
        }
        if ($line -match "^\S" -and $line -notmatch "^---") {
            if ($inSection -and -not $found) {
                $indent = if ($sectionIndent) { "$sectionIndent  " } else { "  " }
                $out.Add("$indent$Key`: $quotedValue"); $found = $true
            }
            $inSection = $false
        }
        if ($inSection -and $line -match "^(\s+)$([regex]::Escape($Key)):\s*") {
            $indent = $Matches[1]
            $out.Add("$indent$Key`: $quotedValue"); $found = $true; continue
        }
        $out.Add($line)
    }
    if ($inSection -and -not $found) {
        $indent = if ($sectionIndent) { "$sectionIndent  " } else { "  " }
        $out.Add("$indent$Key`: $quotedValue")
    }
    [System.IO.File]::WriteAllText($Path, ($out -join "`n"), (New-Object System.Text.UTF8Encoding $false))
    Write-DebugLog "INFO" "Set-YamlKey complete. Found existing key=$found"
}

# -- 1. Ensure Python 3.12 is installed ---------------------------------------
# Pin to 3.12: pre-built wheels exist for all Bazarr dependencies on cp312.
# Avoids the source-build failures that occur with newer Python versions.
# Detection order:
#   1. C:\Python312\python.exe (Chocolatey default)
#   2. Any C:\Python3*\python.exe (user-installed or other package managers)
#   3. python on PATH via Get-Command (system-wide or venv)
# Prefers the highest 3.12.x found; falls back to any 3.x >= 3.9.
Write-Host "  -> Checking Python..." -ForegroundColor Gray
$PythonExe = $null

# Helper: try a candidate path, verify it's Python 3.x, return version tuple
function Test-PythonCandidate {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $verOut = & $Path --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($verOut -match 'Python (\d+)\.(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            $patch = [int]$Matches[3]
            if ($major -eq 3 -and $minor -ge 9) {
                return [PSCustomObject]@{ Path=$Path; Major=$major; Minor=$minor; Patch=$patch; VersionStr="$major.$minor.$patch" }
            }
        }
    } catch {}
    return $null
}

# Step 1: Check C:\Python312 (Chocolatey default)
$candidate = Test-PythonCandidate "C:\Python312\python.exe"
if ($candidate) { $PythonExe = $candidate.Path; Write-DebugLog "INFO" "Found Python $($candidate.VersionStr) at $PythonExe (Chocolatey default)" }

# Step 2: Scan C:\Python3* directories (user-installed, winget, etc.)
if (-not $PythonExe) {
    Get-ChildItem "C:\Python3*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object {
            if ($PythonExe) { return }
            $candidate = Test-PythonCandidate (Join-Path $_.FullName "python.exe")
            if ($candidate) { $PythonExe = $candidate.Path; Write-DebugLog "INFO" "Found Python $($candidate.VersionStr) at $PythonExe (C:\Python3* scan)" }
        }
}

# Step 3: Check PATH (system-wide installs, venvs, etc.)
if (-not $PythonExe) {
    $gc = Get-Command python -ErrorAction SilentlyContinue
    if ($gc) {
        $candidate = Test-PythonCandidate $gc.Source
        if ($candidate) { $PythonExe = $candidate.Path; Write-DebugLog "INFO" "Found Python $($candidate.VersionStr) at $PythonExe (PATH)" }
    }
}

Write-DebugLog "VAR PythonExe after auto-detection=$PythonExe"

# Step 4: If still not found, install via Chocolatey
if (-not $PythonExe) {
    Write-Host "  -> Python 3.12 not found. Installing via Chocolatey..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Python not found on system. Installing python312 via choco..."
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        choco install python312 -y --no-progress | Out-Null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install python312 exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[Bazarr] choco install python312 returned exit code $LASTEXITCODE. Trying other Python locations..."
        Write-DebugLog "WARN" "choco install python312 non-zero exit: $LASTEXITCODE"
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-DebugLog "INFO" "PATH refreshed after Python install"
    $candidate = Test-PythonCandidate "C:\Python312\python.exe"
    if ($candidate) { $PythonExe = $candidate.Path }
}

if (-not $PythonExe) {
    Write-Warning "[$AppName] Python 3.9+ not found. Bazarr requires Python. Skipping."
    Write-DebugLog "ERROR" "Python 3.9+ not found after all detection + install attempts"
    exit 1
}

$pyInfo = Test-PythonCandidate $PythonExe
$pyVersion = if ($pyInfo) { "Python $($pyInfo.VersionStr)" } else { "(unknown version)" }
Write-Host "  -> $pyVersion at $PythonExe" -ForegroundColor Gray
Write-DebugLog "VAR Python path=$PythonExe version=$pyVersion"

# -- 2. Download Bazarr from GitHub -------------------------------------------
$BinDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR BinDir=$BinDir"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Bazarr) { $Config._Versions.Apps.Bazarr.version } else { $null }
$AssetName     = if ($Config._Versions -and $Config._Versions.Apps.Bazarr) { $Config._Versions.Apps.Bazarr.asset } else { "bazarr.zip" }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetName=$AssetName"

# Version-specific cache check
$CacheFile = if ($PinnedVersion) { Join-Path $BinDir "bazarr-$PinnedVersion.zip" } else { $null }
$CachedZip = if ($CacheFile -and (Test-Path $CacheFile)) {
    Get-Item $CacheFile
} else {
    Get-ChildItem $BinDir -Filter "bazarr-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-DebugLog "VAR cached bazarr zip=$($CachedZip.Name) (found=$($null -ne $CachedZip))"

if ($CachedZip) {
    Write-Host "  -> Using cached $($CachedZip.Name)..." -ForegroundColor Gray
    $ZipPath = $CachedZip.FullName
    Write-DebugLog "INFO" "Using cached zip: $ZipPath"
} else {
    $ApiUri = if ($PinnedVersion) {
        "https://api.github.com/repos/morpheus65535/bazarr/releases/tags/$PinnedVersion"
    } else {
        "https://api.github.com/repos/morpheus65535/bazarr/releases/latest"
    }
    $displayVer = if ($PinnedVersion) { $PinnedVersion } else { "latest" }
    Write-Host "  -> Fetching $AppName release $displayVer..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API: $ApiUri"
    try {
        $Release = Invoke-RestMethod -Uri $ApiUri -UseBasicParsing
        Write-DebugLog "VAR GitHub release tag=$($Release.tag_name)"
    } catch {
        Write-Error "[$AppName] Failed to query GitHub releases: $_"
        Write-DebugLog "ERROR" "GitHub API query failed: $_"
        exit 1
    }
    $Version = $Release.tag_name
    $Asset   = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    Write-DebugLog "VAR asset name=$($Asset.name) url=$($Asset.browser_download_url)"
    if (-not $Asset) {
        Write-Error "[$AppName] Asset '$AssetName' not found in release $Version."
        Write-DebugLog "ERROR" "Asset '$AssetName' not found in release $Version"
        exit 1
    }
    $ZipPath = Join-Path $BinDir "bazarr-$Version.zip"
    Write-Host "  -> Downloading Bazarr $Version..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Downloading $($Asset.browser_download_url) -> $ZipPath"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath -UseBasicParsing
    $zipSize = (Get-Item $ZipPath).Length
    Write-DebugLog "INFO" "Download complete. ZipPath=$ZipPath size=$zipSize bytes"
    if (-not $PinnedVersion) { $PinnedVersion = $Version }
}

# -- 3. Extract ----------------------------------------------------------------
Write-Host "  -> Extracting..." -ForegroundColor Gray
$existingSvc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR existing $AppName service=$(if ($existingSvc) { $existingSvc.Status } else { 'NOT FOUND' })"
if ($existingSvc) {
    Write-DebugLog "INFO" "Stopping existing $AppName service before extraction..."
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
$appBinExists = Test-Path $AppBinDir
Write-DebugLog "VAR AppBinDir exists=$appBinExists  --  will be removed before fresh extract"
if ($appBinExists) { Remove-Item $AppBinDir -Recurse -Force }
New-Item -Path $AppBinDir -ItemType Directory -Force | Out-Null
Write-DebugLog "INFO" "Extracting $ZipPath -> $AppBinDir"
Expand-Archive -Path $ZipPath -DestinationPath $AppBinDir -Force

# Flatten single-directory zips (e.g. bazarr-1.4.x/ wrapping the source)
$children = Get-ChildItem $AppBinDir
Write-DebugLog "VAR top-level items in AppBinDir after extract=$($children.Count) first=$($children[0].Name)"
if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
    $sub = $children[0].FullName
    Write-DebugLog "INFO" "Flattening single-directory zip. Moving contents of $sub -> $AppBinDir"
    Get-ChildItem $sub | Move-Item -Destination $AppBinDir
    Remove-Item $sub -Recurse -Force
    Write-DebugLog "INFO" "Flatten complete"
}

$BazarrPy = Join-Path $AppBinDir "bazarr.py"
Write-DebugLog "VAR BazarrPy=$BazarrPy (exists=$(Test-Path $BazarrPy))"
if (-not (Test-Path $BazarrPy)) {
    Write-Error "[$AppName] bazarr.py not found after extraction."
    Write-DebugLog "ERROR" "bazarr.py not found in $AppBinDir after extraction"
    exit 1
}

# -- 4. Install Python requirements -------------------------------------------
$ReqFile = Join-Path $AppBinDir "requirements.txt"
Write-DebugLog "VAR requirements.txt exists=$(Test-Path $ReqFile)"
if (Test-Path $ReqFile) {
    Write-Host "  -> Installing Python requirements (may take a few minutes)..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Installing Python requirements from $ReqFile"

    $pipOk    = $false
    $webrtcOk = $false

    # Use try-catch so pip stderr never propagates as a terminating PS error,
    # regardless of the inherited $ErrorActionPreference from the caller.
    Write-DebugLog "INFO" "Attempting webrtcvad-wheels install first..."
    try {
        $ErrorActionPreference = "Continue"
        $null = & $PythonExe -m pip install "webrtcvad-wheels>=2.0.10" --prefer-binary --quiet --no-warn-script-location 2>&1
        $webrtcOk = ($LASTEXITCODE -eq 0)
        Write-DebugLog "VAR webrtcvad-wheels install exit=$LASTEXITCODE webrtcOk=$webrtcOk"
    } catch {
        $webrtcOk = $false
        Write-DebugLog "WARN" "webrtcvad-wheels install threw exception: $_"
    }

    if (-not $webrtcOk) {
        Write-Host "  -> webrtcvad-wheels not available for this Python version (no MSVC build tools)." -ForegroundColor Yellow
        Write-Host "     ffsubsync disabled; alass will handle subtitle sync." -ForegroundColor Yellow
        Write-DebugLog "WARN" "webrtcvad-wheels unavailable  --  installing requirements without webrtcvad"
        $FilteredReq = [System.IO.Path]::GetTempFileName() + ".txt"
        (Get-Content $ReqFile | Where-Object { $_ -notmatch "webrtcvad" }) | Set-Content $FilteredReq
        Write-DebugLog "VAR filtered requirements file=$FilteredReq"
        try {
            $ErrorActionPreference = "Continue"
            $null = & $PythonExe -m pip install -r $FilteredReq --prefer-binary --quiet --no-warn-script-location 2>&1
            $pipOk = ($LASTEXITCODE -eq 0)
            Write-DebugLog "VAR filtered pip install exit=$LASTEXITCODE pipOk=$pipOk"
        } catch {
            $pipOk = $false
            Write-DebugLog "ERROR" "filtered pip install failed: $_"
        }
        Remove-Item $FilteredReq -ErrorAction SilentlyContinue
    } else {
        Write-DebugLog "INFO" "webrtcvad-wheels installed. Running full requirements.txt install..."
        try {
            $ErrorActionPreference = "Continue"
            $null = & $PythonExe -m pip install -r $ReqFile --prefer-binary --quiet --no-warn-script-location 2>&1
            $pipOk = ($LASTEXITCODE -eq 0)
            Write-DebugLog "VAR full pip install exit=$LASTEXITCODE pipOk=$pipOk"
        } catch {
            $pipOk = $false
            Write-DebugLog "ERROR" "full pip install failed: $_"
        }
    }

    $ErrorActionPreference = "Stop"

    if ($pipOk) {
        Write-Host "  -> Requirements installed." -ForegroundColor Green
        Write-DebugLog "INFO" "Python requirements installed successfully"
    } else {
        Write-Warning "[$AppName] Some requirements failed to install. Core functionality may be affected."
        Write-DebugLog "WARN" "pip install finished with errors. pipOk=$pipOk"
    }
} else {
    Write-Warning "[$AppName] requirements.txt not found; skipping pip install."
    Write-DebugLog "WARN" "requirements.txt not found at $ReqFile"
}

# -- 5. Directories + permissions ---------------------------------------------
Write-DebugLog "VAR DataDir=$DataDir ConfigDir=$ConfigDir"
New-Item -Path $DataDir   -ItemType Directory -Force | Out-Null
New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
Grant-SeedboxDirAccess -Path $AppBinDir -Username $SvcUser
Grant-SeedboxDirAccess -Path $DataDir   -Username $SvcUser

# -- 6. Windows service via NSSM ----------------------------------------------
Write-Host "  -> Creating Windows service..." -ForegroundColor Gray
$svcExists = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svcExists)"
if (-not $svcExists) {
    Write-DebugLog "INFO" "Creating NSSM service '$AppName' python=$PythonExe bazarr=$BazarrPy"
    nssm install $AppName "`"$PythonExe`"" | Out-Null
    nssm set $AppName AppParameters "`"$BazarrPy`" --no-update -c `"$DataDir`"" | Out-Null
    nssm set $AppName AppDirectory  $AppBinDir | Out-Null
    nssm set $AppName Description   "Bazarr - Subtitle Manager for Sonarr and Radarr" | Out-Null
    nssm set $AppName Start         SERVICE_AUTO_START | Out-Null
    nssm set $AppName AppStdout     (Join-Path $DataDir "bazarr-stdout.log") | Out-Null
    nssm set $AppName AppStderr     (Join-Path $DataDir "bazarr-stderr.log") | Out-Null
    nssm set $AppName ObjectName    ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service '$AppName' created under '$SvcUser'." -ForegroundColor Gray
    Write-DebugLog "INFO" "NSSM service '$AppName' created. stdoutLog=$(Join-Path $DataDir 'bazarr-stdout.log')"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists"
}

# -- 7. Firewall ---------------------------------------------------------------
# LAN-scoped: Caddy proxies over loopback, so exposing this port to the internet
# would only bypass basic-auth and CrowdSec detection. See 03_sonarr.ps1.
New-NetFirewallRule -DisplayName $AppName -Direction Inbound -LocalPort $AppPort `
    -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for $AppName port=$AppPort"

# -- 8. First-run: wait for config.yaml + API ready ---------------------------
# Bazarr performs multiple config.yaml writes during startup (initial create,
# then a defaults-fill pass). We must wait for the API to be up before stopping,
# otherwise our base_url edit gets overwritten on the next start.
Write-Host "  -> Starting Bazarr for first-run config generation (up to 180s)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName service for first-run initialization..."
Start-Service -Name $AppName -ErrorAction SilentlyContinue
$svcAfterStart = Get-Service -Name $AppName -ErrorAction SilentlyContinue
$svcStatus = if ($svcAfterStart) { $svcAfterStart.Status } else { "NOT FOUND" }
Write-DebugLog "VAR $AppName status immediately after start=$svcStatus"
if ($svcStatus -ne "Running") {
    Write-Warning "  -> Bazarr service did not start. Check $DataDir\bazarr-stderr.log"
    Write-DebugLog "ERROR" "$AppName service is $svcStatus after start. Check bazarr-stderr.log"
}

# Phase 1: wait for config.yaml to appear
Write-DebugLog "INFO" "Phase 1: waiting up to 120s for config.yaml at $ConfigFile"
$deadline = (Get-Date).AddSeconds(120)
$waited   = 0
while (-not (Test-Path $ConfigFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $waited += 5
}
Write-DebugLog "VAR config.yaml created=$(Test-Path $ConfigFile) waited=${waited}s"

if (-not (Test-Path $ConfigFile)) {
    Write-Warning "  -> config.yaml not generated after 120s. Base URL will not be set automatically."
    Write-DebugLog "WARN" "config.yaml not generated within 120s. base_url will not be set."
} else {
    # Phase 2: wait for API (base_url='' so no prefix), confirming all startup writes are done
    Write-Host "  -> Waiting for Bazarr API to finish initializing (up to 90s)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Phase 2: waiting up to 90s for Bazarr API at http://127.0.0.1:$AppPort/api/system/ping"
    $apiReady = $false
    $apiDeadline = (Get-Date).AddSeconds(90)
    $apiWaited = 0
    while (-not $apiReady -and (Get-Date) -lt $apiDeadline) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/api/system/ping" `
                -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
            $apiReady = $true
        } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
    }
    Write-DebugLog "VAR Bazarr API ready=$apiReady waited=${apiWaited}s"
    if (-not $apiReady) {
        Write-Host "  -> API did not respond in 90s; proceeding anyway (base_url may not persist)." -ForegroundColor Yellow
        Write-DebugLog "WARN" "Bazarr API not ready after 90s  --  proceeding anyway"
    }

    Write-DebugLog "INFO" "Stopping $AppName before config.yaml edit..."
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # -- 9. Set base_url for DuckDNS path routing ------------------------------
    if ($DomainMode -eq "duckdns") {
        Write-DebugLog "INFO" "DuckDNS mode: setting base_url=/$AppLower in $ConfigFile"
        Set-YamlKey -Path $ConfigFile -Section "general" -Key "base_url" -Value "/$AppLower"
        Write-Host "  -> base_url set to /$AppLower (DuckDNS mode)." -ForegroundColor Green
        Write-DebugLog "INFO" "config.yaml base_url updated to '/$AppLower'"
    } else {
        Write-DebugLog "INFO" "Cloudflare mode: base_url not set in config.yaml"
    }

    Write-DebugLog "INFO" "Restarting $AppName after config edit..."
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
}

# -- 10. Validate --------------------------------------------------------------
Start-Sleep -Seconds 3
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    Write-Warning "  -> $AppName may not have started. Check $DataDir\bazarr-stderr.log"
    Write-DebugLog "WARN" "$AppName may not be running. Check $DataDir\bazarr-stderr.log"
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"
Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "09_bazarr.ps1 complete"
