param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_recyclarr.ps1 started"

$RecyclarrDir = Join-Path $PSScriptRoot "..\recyclarr"
$RecyclarrExe = Join-Path $RecyclarrDir "recyclarr.exe"
$ConfigFile   = Join-Path $RecyclarrDir "recyclarr.yml"
$DomainMode   = $Config.General.DomainMode

Write-DebugLog "VAR RecyclarrDir=$RecyclarrDir"
Write-DebugLog "VAR RecyclarrExe=$RecyclarrExe (exists=$(Test-Path $RecyclarrExe))"
Write-DebugLog "VAR ConfigFile=$ConfigFile (exists=$(Test-Path $ConfigFile))"
Write-DebugLog "VAR DomainMode=$DomainMode"

# -- 1. Download recyclarr.exe if missing --------------------------------------
if (-not (Test-Path $RecyclarrExe)) {
    Write-Host "  -> Downloading recyclarr..." -ForegroundColor Gray
    Write-DebugLog "INFO" "recyclarr.exe not found. Downloading from GitHub..."
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/recyclarr/recyclarr/releases/latest" -UseBasicParsing
        Write-DebugLog "VAR recyclarr release tag=$($release.tag_name) assets=$($release.assets.Count)"
        $asset   = $release.assets | Where-Object { $_.name -like "*win-x64*" } | Select-Object -First 1
        Write-DebugLog "VAR recyclarr asset=$($asset.name)"
        if (-not $asset) {
            Write-Warning "[Recyclarr] No win-x64 asset found in latest release."
            Write-DebugLog "ERROR" "No win-x64 asset in recyclarr release $($release.tag_name)"
            exit 1
        }
        $zipPath = Join-Path $env:TEMP "recyclarr-win-x64.zip"
        Write-DebugLog "INFO" "Downloading $($asset.browser_download_url) -> $zipPath"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
        $zipSize = (Get-Item $zipPath).Length
        Write-DebugLog "VAR downloaded zip size=$zipSize bytes"
        Expand-Archive -Path $zipPath -DestinationPath $RecyclarrDir -Force
        Remove-Item $zipPath -Force
        Write-Host "     [OK] Downloaded recyclarr $($release.tag_name)" -ForegroundColor Green
        Write-DebugLog "INFO" "recyclarr $($release.tag_name) extracted to $RecyclarrDir"
    } catch {
        Write-Warning "[Recyclarr] Failed to download: $_"
        Write-DebugLog "ERROR" "recyclarr download failed: $_"
        exit 1
    }
}

if (-not (Test-Path $RecyclarrExe)) {
    Write-Warning "[Recyclarr] recyclarr.exe not found at '$RecyclarrExe' after download."
    Write-DebugLog "ERROR" "recyclarr.exe not found at $RecyclarrExe after download"
    exit 1
}

# -- 2. Read API keys from config.xml files ------------------------------------
$SonarrKey = $null
$RadarrKey = $null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-DebugLog "VAR isAdmin=$isAdmin"

if ($Config.Apps.Sonarr -eq $true) {
    $sonarrXml = "C:\ProgramData\Sonarr\config.xml"
    Write-DebugLog "VAR Sonarr config.xml exists=$(Test-Path $sonarrXml)"
    if (Test-Path $sonarrXml) {
        $SonarrKey = ([xml](Get-Content $sonarrXml -Encoding UTF8)).Config.ApiKey
        Write-DebugLog "VAR SonarrKey found=$((-not [string]::IsNullOrEmpty($SonarrKey)))"
    }
}
if ($Config.Apps.Radarr -eq $true) {
    $radarrXml = "C:\ProgramData\Radarr\config.xml"
    Write-DebugLog "VAR Radarr config.xml exists=$(Test-Path $radarrXml)"
    if (Test-Path $radarrXml) {
        $RadarrKey = ([xml](Get-Content $radarrXml -Encoding UTF8)).Config.ApiKey
        Write-DebugLog "VAR RadarrKey found=$((-not [string]::IsNullOrEmpty($RadarrKey)))"
    }
}

$SonarrBase  = if ($DomainMode -eq "duckdns") { "/sonarr" } else { "" }
$RadarrBase  = if ($DomainMode -eq "duckdns") { "/radarr" } else { "" }
$SonarrUrl   = "http://127.0.0.1:$($Config.Ports.Sonarr)$SonarrBase"
$RadarrUrl   = "http://127.0.0.1:$($Config.Ports.Radarr)$RadarrBase"
Write-DebugLog "VAR SonarrUrl=$SonarrUrl RadarrUrl=$RadarrUrl"

if (-not $SonarrKey -and -not $RadarrKey) {
    if (-not $isAdmin) {
        Write-Warning "[Recyclarr] Run as Administrator to access Sonarr/Radarr config files."
        Write-DebugLog "ERROR" "Not running as admin  --  cannot read config files"
    } else {
        Write-Warning "[Recyclarr] No API keys found. Ensure Sonarr/Radarr are installed and have run at least once."
        Write-DebugLog "ERROR" "No API keys found for Sonarr or Radarr"
    }
    exit 1
}

# -- 3. Write secrets.yml to Recyclarr app-data dir ---------------------------
# Recyclarr v8 always reads secrets from %APPDATA%\recyclarr\secrets.yml
$AppDataDir  = Join-Path $env:APPDATA "recyclarr"
$SecretsFile = Join-Path $AppDataDir "secrets.yml"
New-Item -ItemType Directory -Force $AppDataDir | Out-Null
Write-DebugLog "VAR AppDataDir=$AppDataDir SecretsFile=$SecretsFile"

# Build secrets.yml selectively: only emit keys that are non-null so Recyclarr
# does not try to authenticate with an empty string against a non-existent service.
$secretLines = [System.Collections.Generic.List[string]]::new()
if ($SonarrKey) {
    $secretLines.Add("sonarr_base_url: `"http://127.0.0.1:$($Config.Ports.Sonarr)$SonarrBase`"")
    $secretLines.Add("sonarr_api_key: `"$SonarrKey`"")
}
if ($RadarrKey) {
    $secretLines.Add("radarr_base_url: `"http://127.0.0.1:$($Config.Ports.Radarr)$RadarrBase`"")
    $secretLines.Add("radarr_api_key: `"$RadarrKey`"")
}
$secrets = $secretLines -join "`n"
[System.IO.File]::WriteAllText($SecretsFile, $secrets, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Recyclarr secrets.yml written to $SecretsFile (sonarr_key=$((-not [string]::IsNullOrEmpty($SonarrKey))) radarr_key=$((-not [string]::IsNullOrEmpty($RadarrKey))))"

# -- 4. Run recyclarr sync -----------------------------------------------------
# Recyclarr's Spectre.Console calls SetConsoleMode() on its stdout handle.
# This fails with "The handle is invalid" when stdout is a pipe (e.g. when the
# installer captures output via *>&1 | Tee-Object), because child processes
# inherit the piped handle and it is not a real console handle.
# Start-Process -WindowStyle Hidden gives recyclarr its own hidden console with
# valid handles. Output is surfaced from the debug log recyclarr writes to APPDATA.
Write-Host "  -> Running recyclarr sync..." -ForegroundColor Gray
Write-DebugLog "INFO" "Running recyclarr sync (configFile=$ConfigFile)..."
$logDir   = Join-Path $env:APPDATA "recyclarr\logs\cli"
$snapshot = Get-ChildItem $logDir -Filter "*.debug.log" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
Write-DebugLog "VAR recyclarr log dir=$logDir existing logs=$($snapshot.Count)"

try {
    $proc = Start-Process -FilePath $RecyclarrExe `
        -ArgumentList "sync", "-c", "`"$ConfigFile`"" `
        -Wait -PassThru -WindowStyle Hidden
    Write-DebugLog "VAR recyclarr exit code=$($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) {
        throw "recyclarr exited with code $($proc.ExitCode)"
    }
    Write-Host "  [OK] Recyclarr sync complete." -ForegroundColor Green
    Write-DebugLog "INFO" "recyclarr sync completed successfully"
} catch {
    Write-Warning "[Recyclarr] Sync failed: $_"
    Write-DebugLog "ERROR" "recyclarr sync failed: $_"
    exit 1
} finally {
    $newLog = Get-ChildItem $logDir -Filter "*.debug.log" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin $snapshot } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-DebugLog "VAR new recyclarr log=$($newLog.FullName)"
    if ($newLog) {
        $logLines = Get-Content $newLog.FullName |
            Where-Object { $_ -match '^\[[\d:]+ (INF|WRN|ERR)\]' }
        Write-DebugLog "INFO" "recyclarr log lines matching INF/WRN/ERR=$($logLines.Count)"
        $logLines | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Gray
            Write-DebugLog "VAR recyclarr log: $_"
        }
    }
}
Write-DebugLog "INFO" "configure_layer2_recyclarr.ps1 complete"
