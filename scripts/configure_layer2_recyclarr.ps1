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

$RecyclarrDir    = Join-Path $PSScriptRoot "..\recyclarr"
$RecyclarrExe    = Join-Path $RecyclarrDir "recyclarr.exe"
$ConfigFile      = Join-Path $RecyclarrDir "recyclarr.yml"
# Recyclarr resolves its app-data dir through the Windows Known Folder API, which
# ignores an overridden %APPDATA% environment variable (verified: with APPDATA
# pointed elsewhere, recyclarr still reported
# "App Data Dir: <profile>\AppData\Roaming\recyclarr").  Resolve the same way so
# secrets.yml is written exactly where recyclarr looks for it.
$RoamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
if (-not $RoamingAppData) { $RoamingAppData = $env:APPDATA }
$AppDataDir      = Join-Path $RoamingAppData "recyclarr"
$SecretsFile     = Join-Path $AppDataDir "secrets.yml"
$EffectiveConfig = Join-Path $AppDataDir "win-seedbox.yml"
$DomainMode      = $Config.General.DomainMode
$RecyclarrVersion = $null

Write-DebugLog "VAR RecyclarrDir=$RecyclarrDir"
Write-DebugLog "VAR RecyclarrExe=$RecyclarrExe (exists=$(Test-Path $RecyclarrExe))"
Write-DebugLog "VAR ConfigFile=$ConfigFile (exists=$(Test-Path $ConfigFile))"
Write-DebugLog "VAR AppDataDir=$AppDataDir"
Write-DebugLog "VAR SecretsFile=$SecretsFile"
Write-DebugLog "VAR EffectiveConfig=$EffectiveConfig"
Write-DebugLog "VAR DomainMode=$DomainMode"

# -- 1. Download recyclarr.exe if missing --------------------------------------
# Version + asset name come from versions.json (merged into Config as _Versions
# by master_configure_layer2.ps1), so Layer 2 installs the same build the
# updater tracks. "latest" means unpinned.
$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Recyclarr) { $Config._Versions.Apps.Recyclarr.version } else { $null }
$AssetPattern  = if ($Config._Versions -and $Config._Versions.Apps.Recyclarr -and $Config._Versions.Apps.Recyclarr.asset) { $Config._Versions.Apps.Recyclarr.asset } else { "*win-x64.zip" }
if ($PinnedVersion -and $PinnedVersion -ieq "latest") { $PinnedVersion = $null }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetPattern=$AssetPattern"

if (-not (Test-Path $RecyclarrExe)) {
    Write-Host "  -> Downloading recyclarr..." -ForegroundColor Gray
    Write-DebugLog "INFO" "recyclarr.exe not found. Downloading from GitHub..."
    $ApiUri = if ($PinnedVersion) {
        "https://api.github.com/repos/recyclarr/recyclarr/releases/tags/$PinnedVersion"
    } else {
        "https://api.github.com/repos/recyclarr/recyclarr/releases/latest"
    }
    Write-DebugLog "INFO" "Querying GitHub API: $ApiUri"
    try {
        $release = Invoke-RestMethod $ApiUri -UseBasicParsing
        Write-DebugLog "VAR recyclarr release tag=$($release.tag_name) assets=$($release.assets.Count)"
        $asset   = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
        Write-DebugLog "VAR recyclarr asset=$($asset.name)"
        if (-not $asset) {
            Write-Warning "[Recyclarr] No asset matching '$AssetPattern' in release $($release.tag_name)."
            Write-DebugLog "ERROR" "No asset matching '$AssetPattern' in recyclarr release $($release.tag_name)"
            exit 1
        }
        $zipPath = Join-Path $env:TEMP $asset.name
        Write-DebugLog "INFO" "Downloading $($asset.browser_download_url) -> $zipPath"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
        $zipSize = (Get-Item $zipPath).Length
        Write-DebugLog "VAR downloaded zip size=$zipSize bytes"
        Expand-Archive -Path $zipPath -DestinationPath $RecyclarrDir -Force
        Remove-Item $zipPath -Force
        Write-Host "     [OK] Downloaded recyclarr $($release.tag_name)" -ForegroundColor Green
        Write-DebugLog "INFO" "recyclarr $($release.tag_name) extracted to $RecyclarrDir"
        $RecyclarrVersion = $release.tag_name
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
# An instance whose API key cannot be read (app disabled, config.xml missing or
# unreadable) is left out of the generated config in step 4 and is never synced.
$SonarrSettings = $null
$RadarrSettings = $null
$SonarrKey = $null
$RadarrKey = $null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-DebugLog "VAR isAdmin=$isAdmin"

function Get-ArrSettings {
    # API key and UrlBase out of an *arr config.xml, or $null when it cannot be read.
    param([string]$AppName, [string]$ConfigXml)
    if (-not (Test-Path $ConfigXml)) {
        Write-DebugLog "VAR $AppName config.xml exists=False ($ConfigXml)"
        return $null
    }
    try {
        $xml = [xml](Get-Content -Raw -Path $ConfigXml -Encoding UTF8)
        return [PSCustomObject]@{
            ApiKey  = [string]$xml.Config.ApiKey
            UrlBase = [string]$xml.Config.UrlBase
        }
    } catch {
        Write-Warning "[Recyclarr] Could not read the $AppName API key from '$ConfigXml': $_"
        Write-DebugLog "ERROR" "$AppName config.xml unreadable: $_"
        return $null
    }
}

function Get-ArrBasePath {
    # The path the app actually answers on. Its config.xml is authoritative: the
    # app installers set UrlBase=/<app> in DuckDNS mode and remove it in Cloudflare
    # mode, so reading it stays correct when UrlBase was changed by hand (the
    # troubleshooting guide tells the user to re-run this script for exactly that
    # case) or when a mode switch did not re-run the app installer. DomainMode is
    # only the fallback.
    param([object]$Settings, [string]$Fallback)
    if (-not $Settings) { return $Fallback }
    $base = "$($Settings.UrlBase)".Trim().TrimEnd('/')
    if ($base -eq "") { return "" }
    if (-not $base.StartsWith("/")) { return "/$base" }
    return $base
}

if ($Config.Apps.Sonarr -eq $true) {
    $SonarrSettings = Get-ArrSettings -AppName "Sonarr" -ConfigXml "C:\ProgramData\Sonarr\config.xml"
    if ($SonarrSettings) { $SonarrKey = $SonarrSettings.ApiKey }
    Write-DebugLog "VAR SonarrKey found=$((-not [string]::IsNullOrEmpty($SonarrKey))) UrlBase='$($SonarrSettings.UrlBase)'"
}
if ($Config.Apps.Radarr -eq $true) {
    $RadarrSettings = Get-ArrSettings -AppName "Radarr" -ConfigXml "C:\ProgramData\Radarr\config.xml"
    if ($RadarrSettings) { $RadarrKey = $RadarrSettings.ApiKey }
    Write-DebugLog "VAR RadarrKey found=$((-not [string]::IsNullOrEmpty($RadarrKey))) UrlBase='$($RadarrSettings.UrlBase)'"
}

$SonarrFallback = if ($DomainMode -eq "duckdns") { "/sonarr" } else { "" }
$RadarrFallback = if ($DomainMode -eq "duckdns") { "/radarr" } else { "" }
$SonarrBase  = Get-ArrBasePath -Settings $SonarrSettings -Fallback $SonarrFallback
$RadarrBase  = Get-ArrBasePath -Settings $RadarrSettings -Fallback $RadarrFallback
$SonarrUrl   = "http://127.0.0.1:$($Config.Ports.Sonarr)$SonarrBase"
$RadarrUrl   = "http://127.0.0.1:$($Config.Ports.Radarr)$RadarrBase"
Write-DebugLog "VAR SonarrUrl=$SonarrUrl RadarrUrl=$RadarrUrl"

if ($Config.Apps.Sonarr -eq $true -and -not $SonarrKey) {
    Write-Warning "[Recyclarr] Sonarr is enabled but its API key is unavailable  --  Sonarr will NOT be synced."
    Write-DebugLog "WARN" "Sonarr enabled but no API key; Sonarr omitted from the sync"
}
if ($Config.Apps.Radarr -eq $true -and -not $RadarrKey) {
    Write-Warning "[Recyclarr] Radarr is enabled but its API key is unavailable  --  Radarr will NOT be synced."
    Write-DebugLog "WARN" "Radarr enabled but no API key; Radarr omitted from the sync"
}

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
# Recyclarr v8 always reads secrets from its config directory
# (%APPDATA%\recyclarr), whatever the config file path passed to -c is.
New-Item -ItemType Directory -Force $AppDataDir | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Build secrets.yml selectively: only emit keys that are non-null so Recyclarr
# does not try to authenticate with an empty string against a non-existent service.
$secretLines = [System.Collections.Generic.List[string]]::new()
if ($SonarrKey) {
    $secretLines.Add("sonarr_base_url: `"$SonarrUrl`"")
    $secretLines.Add("sonarr_api_key: `"$SonarrKey`"")
}
if ($RadarrKey) {
    $secretLines.Add("radarr_base_url: `"$RadarrUrl`"")
    $secretLines.Add("radarr_api_key: `"$RadarrKey`"")
}
$secrets = $secretLines -join "`n"
[System.IO.File]::WriteAllText($SecretsFile, $secrets, $Utf8NoBom)
Write-DebugLog "INFO" "Recyclarr secrets.yml written to $SecretsFile (sonarr_key=$((-not [string]::IsNullOrEmpty($SonarrKey))) radarr_key=$((-not [string]::IsNullOrEmpty($RadarrKey))))"

# The file holds live API keys, so pin its ACL to the current user +
# Administrators + SYSTEM instead of relying on inherited profile permissions.
# Best effort: a failed ACL must not stop the sync.
try {
    $acl = Get-Acl -Path $SecretsFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
    $adminSid  = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $userSid   = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $fullRights = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $allowType  = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($userSid, $adminSid, $systemSid)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $fullRights, $allowType)))
    }
    Set-Acl -Path $SecretsFile -AclObject $acl
    Write-DebugLog "INFO" "secrets.yml ACL restricted to $($userSid.Value), Administrators, SYSTEM"
} catch {
    Write-Warning "[Recyclarr] Could not restrict permissions on '$SecretsFile': $_"
    Write-DebugLog "WARN" "secrets.yml ACL hardening failed: $_"
}

# -- 4. Generate the config Recyclarr will actually read -----------------------
# recyclarr.yml documents both instances and refers to their secrets
# unconditionally with !secret. Recyclarr resolves every !secret while parsing
# the whole file and aborts the run (SecretNotFoundException) when one of them
# is missing from secrets.yml -- even for a service that is not being synced.
# The instance we have no credentials for must therefore not appear in the file
# at all, so write a per-run copy containing only the sections we can sync.
# (Verified with recyclarr 8.7.1: a missing secret fails at "Config parsing
# failed in <file>: Secret used on line N with key ... is not defined".)
# The generated file deliberately does not use the default name recyclarr.yml,
# so a manual `recyclarr sync` without -c still picks up the user's own config.
$KeepSections = [System.Collections.Generic.List[string]]::new()
if ($SonarrKey) { $KeepSections.Add("sonarr") }
if ($RadarrKey) { $KeepSections.Add("radarr") }

if (-not (Test-Path $ConfigFile)) {
    Write-Warning "[Recyclarr] Config template not found: $ConfigFile"
    Write-DebugLog "ERROR" "Config template not found: $ConfigFile"
    exit 1
}

# Split the template on top-level keys (column 0); everything else is body.
$templateLines = [System.IO.File]::ReadAllLines($ConfigFile, [System.Text.Encoding]::UTF8)
$blocks  = New-Object 'System.Collections.Specialized.OrderedDictionary'
$current = "__prologue__"
foreach ($line in $templateLines) {
    $m = [regex]::Match($line, '^([A-Za-z0-9_-]+):')
    if ($m.Success -and $m.Groups[1].Value -ne $current) {
        $name = $m.Groups[1].Value
        if (-not $blocks.Contains($name)) {
            $blocks.Add($name, [System.Collections.Generic.List[string]]::new())
        }
        # A comment line directly above a section heading labels that section,
        # so it has to disappear together with its section.
        $prev = $blocks[$current]
        $i = $prev.Count - 1
        while ($i -ge 0 -and $prev[$i] -match '^\s*$') { $i-- }
        if ($i -ge 0 -and $prev[$i] -match '^\s*#') {
            $blocks[$name].Insert(0, $prev[$i])
            $prev.RemoveAt($i)
        }
        $current = $name
    }
    if (-not $blocks.Contains($current)) {
        $blocks.Add($current, [System.Collections.Generic.List[string]]::new())
    }
    $blocks[$current].Add($line)
}

foreach ($svc in $KeepSections) {
    if (-not $blocks.Contains($svc)) {
        Write-Warning "[Recyclarr] No '${svc}:' section in $ConfigFile  --  cannot sync $svc."
        Write-DebugLog "ERROR" "Top-level '${svc}:' section missing from $ConfigFile"
        exit 1
    }
}

$effectiveLines = [System.Collections.Generic.List[string]]::new()
$effectiveLines.Add("# Generated by scripts/configure_layer2_recyclarr.ps1 -- do not edit.")
$effectiveLines.Add("# Source template: recyclarr\recyclarr.yml (sections without credentials are removed).")
foreach ($key in $blocks.Keys) {
    if ($key -eq "__prologue__") { continue }
    if (-not ($KeepSections -contains $key)) {
        Write-DebugLog "INFO" "Effective config: dropping '$key' section (no API key available)"
        continue
    }
    $effectiveLines.AddRange($blocks[$key].ToArray())
}
[System.IO.File]::WriteAllLines($EffectiveConfig, $effectiveLines.ToArray(), $Utf8NoBom)
Write-DebugLog "INFO" "Effective config written to $EffectiveConfig (sections kept: $($KeepSections -join ', '))"

# -- 5. Run recyclarr sync -----------------------------------------------------
# Recyclarr's Spectre.Console calls SetConsoleMode() on its stdout handle.
# This fails with "The handle is invalid" when stdout is a pipe (e.g. when the
# installer captures output via *>&1 | Tee-Object), because child processes
# inherit the piped handle and it is not a real console handle.
# Start-Process -WindowStyle Hidden gives recyclarr its own hidden console with
# valid handles. Output is surfaced from the debug log recyclarr writes to APPDATA.
Write-Host "  -> Running recyclarr sync..." -ForegroundColor Gray
Write-DebugLog "INFO" "Running recyclarr sync (configFile=$EffectiveConfig)..."
$logDir   = Join-Path $AppDataDir "logs\cli"
$snapshot = @(Get-ChildItem $logDir -Filter "*.debug.log" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
Write-DebugLog "VAR recyclarr log dir=$logDir existing logs=$($snapshot.Count)"

$logLines = @()
$rawLogLines = @()
try {
    $proc = Start-Process -FilePath $RecyclarrExe `
        -ArgumentList "sync", "-c", "`"$EffectiveConfig`"" `
        -Wait -PassThru -WindowStyle Hidden
    Write-DebugLog "VAR recyclarr exit code=$($proc.ExitCode)"

    $newLog = Get-ChildItem $logDir -Filter "*.debug.log" -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin $snapshot } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-DebugLog "VAR new recyclarr log=$($newLog.FullName)"
    if ($newLog) {
        $rawLogLines = @(Get-Content $newLog.FullName)
        $logLines = @($rawLogLines |
            Where-Object { $_ -match '^\[[\d:]+ (INF|WRN|ERR)\]' })
        Write-DebugLog "INFO" "recyclarr log lines matching INF/WRN/ERR=$($logLines.Count)"
    }

    if ($proc.ExitCode -ne 0) {
        throw "recyclarr exited with code $($proc.ExitCode)"
    }
    # Recyclarr exits 0 for some config problems, so the exit code alone is not
    # proof of a sync. Two shapes, both verified against 8.7.1 and 8.8.0:
    #   * an unresolvable !secret / YAML error is logged at ERR as
    #     "Config parsing failed in <file>" (exit code 1 as well);
    #   * an invalid instance (unknown quality name, a profile whose
    #     until_quality is not in its own qualities list, ...) is reported ONLY at
    #     DBG as 'Invalid instances: [{"InstanceName":...}]'; Recyclarr skips that
    #     instance, syncs the others and still exits 0, so the broken one would be
    #     dropped without a word.
    $fatal = @($rawLogLines | Where-Object {
        $_ -match 'Config parsing failed|Exiting due to fatal error|Invalid instances:\s*\[\s*\{'
    })
    if ($fatal.Count -gt 0) {
        Write-DebugLog "ERROR" "recyclarr reported a fatal error with exit code 0: $($fatal[0])"
        throw "recyclarr did not complete: $($fatal[0])"
    }
    # A clean exit code and no fatal marker is still not proof that anything was
    # synced: Recyclarr 8.x also exits 0 without processing a single instance (the
    # same-URL / no-instance case logs only 'Split instances: ...' at DBG). Every
    # synced instance logs 'Processing <Service> server <name>' at INF, so require
    # at least one.
    $instancesExpected  = @($effectiveLines | Where-Object { $_ -match '^\s+base_url:\s' }).Count
    $instancesProcessed = @($rawLogLines | Where-Object { $_ -match '^\[[\d:]+ INF\] [^:]+: Processing (Sonarr|Radarr) server ' }).Count
    if ($instancesProcessed -eq 0) {
        Write-DebugLog "ERROR" "recyclarr exited 0 but processed no instance (config defines $instancesExpected)"
        throw "recyclarr exited 0 but did not process any instance (no 'Processing ... server' log line)"
    }
    if ($instancesExpected -gt 0 -and $instancesProcessed -lt $instancesExpected) {
        Write-Warning "[Recyclarr] Only $instancesProcessed of $instancesExpected instance(s) were processed; check the log lines above."
        Write-DebugLog "WARN" "recyclarr processed $instancesProcessed of $instancesExpected instances"
    }
    Write-Host "  [OK] Recyclarr sync complete." -ForegroundColor Green
    Write-DebugLog "INFO" "recyclarr sync completed successfully"
} catch {
    Write-Warning "[Recyclarr] Sync failed: $_"
    Write-DebugLog "ERROR" "recyclarr sync failed: $_"
    exit 1
} finally {
    foreach ($line in $logLines) {
        Write-Host "  $line" -ForegroundColor Gray
        Write-DebugLog "VAR recyclarr log: $line"
    }
}

# -- Ledger entry for the updater ----------------------------------------------
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
if (-not $RecyclarrVersion -and (Test-Path $RecyclarrExe)) {
    # Layer 2 re-run with the binary already present: ask it for its version.
    # --version can fail when stdout is not a real console (Spectre.Console), so
    # the version resource of the exe is the fallback.
    $rcOut = (& $RecyclarrExe --version 2>$null | Select-Object -First 1)
    if ($rcOut -match '([0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
        $RecyclarrVersion = $Matches[1]
    } else {
        $exeInfo = (Get-Item $RecyclarrExe).VersionInfo
        if ("$($exeInfo.ProductVersion) $($exeInfo.FileVersion)" -match '([0-9]+\.[0-9]+\.[0-9]+)' -and $Matches[1] -ne "0.0.0") {
            $RecyclarrVersion = $Matches[1]
        }
    }
}
if ($RecyclarrVersion) {
    Set-InstalledVersion -InstallDir $Config.General.InstallDir -AppName "Recyclarr" -Version $RecyclarrVersion
} else {
    Write-Warning "[Recyclarr] Installed version could not be determined; the updater skips Recyclarr until a ledger entry exists."
    Write-DebugLog "WARN" "Recyclarr version unknown; ledger entry not written"
}

Write-DebugLog "INFO" "configure_layer2_recyclarr.ps1 complete"

exit 0
