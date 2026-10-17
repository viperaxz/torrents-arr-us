param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")

# Bounded service control: nssm services wedge in Stop/Start Pending and the
# built-in cmdlets wait indefinitely. See service_helpers.ps1.
if (-not (Get-Command Start-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
# Shared choco plumbing: PATH-safe resolution plus retry-on-transient-feed-failure.
. (Join-Path $PSScriptRoot "choco_helpers.ps1")
Write-DebugLog "INFO" "07_deluge.ps1 started"

$AppName       = "Deluge"
$AppLower      = "deluge"
$DaemonPort    = $Config.Ports.Deluge
$WebPort       = $Config.Ports.DelugeWeb
# BitTorrent peer port -- must be forwarded on your router.
# Default 56881 avoids ISP throttling on well-known ports like 6881.
$BTPort        = if ($Config.Ports.PSObject.Properties['DelugeBT'] -and $Config.Ports.DelugeBT) {
    [int]$Config.Ports.DelugeBT
} else {
    Write-DebugLog "WARN" "Ports.DelugeBT not set in config.json. Using default 56881."
    56881
}
$InstallDir    = $Config.General.InstallDir
$DataDir       = Join-Path $InstallDir "Deluge-data"
$LockFile      = Join-Path $InstallDir ".locks\.$AppLower.lock"
$SvcUser       = "seedbox-svc"
$SvcPass       = $Config.General.ServiceAccountPassword
$SecretsDir    = Join-Path $InstallDir "secrets"
$AuthFile      = Join-Path $DataDir "auth"
$CoreConf      = Join-Path $DataDir "core.conf"
$WebConf       = Join-Path $DataDir "web.conf"
$DaemonLog     = Join-Path $DataDir "deluged.log"
$WebLog        = Join-Path $DataDir "deluge-web.log"
$dlPath        = $Config.Paths.Downloads

Write-DebugLog "VAR AppName=$AppName DaemonPort=$DaemonPort WebPort=$WebPort BTPort=$BTPort"
Write-DebugLog "VAR InstallDir=$InstallDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR SecretsDir=$SecretsDir AuthFile=$AuthFile"
Write-DebugLog "VAR SvcUser=$SvcUser SvcPass=[REDACTED]"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

# Deluge's Label plugin resolves an incoming label with self.labels[label_id] and
# raises KeyError when it has never seen it, so every grab carrying an unknown label
# fails on the *arr side (Radarr logs
#   DelugeException: ... File "deluge_label\core.py", line 307, in get_options
#   KeyError: 'radarr'
# ). configure_layer2_sonarr.ps1 sets tvCategory "tv-sonarr" and
# configure_layer2_radarr.ps1 sets movieCategory "radarr", but nothing ever created
# those labels, so keep the two in step here. Deluge owns label.conf -- it rewrites
# the file from memory -- so the labels are created through its own API instead.
$DelugeLabels = @("tv-sonarr", "radarr")
function Ensure-DelugeLabels {
    param([int]$Port, [string[]]$Labels)

    $labelAuthFile = Join-Path $SecretsDir "deluge_auth.txt"
    $labelPassword = if (Test-Path $labelAuthFile) {
        (Get-Content -Path $labelAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    } else {
        $Config.General.AdminPassword
    }
    if (-not $labelPassword) {
        Write-DebugLog "WARN" "Deluge label setup skipped: no password available"
        return
    }

    Write-Host "  -> Ensuring Deluge labels exist ($($Labels -join ', '))..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Ensuring Deluge labels: $($Labels -join ',')"

    $labelSess    = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $labelJsonUrl = "http://127.0.0.1:$Port/json"
    $labelDeadline = (Get-Date).AddSeconds(45)
    $labelAuth    = $false
    while (-not $labelAuth -and (Get-Date) -lt $labelDeadline) {
        try {
            $authBody = @{ method = "auth.login"; params = @($labelPassword); id = 1 } | ConvertTo-Json -Compress
            $authRes  = Invoke-RestMethod -Uri $labelJsonUrl -Method Post -Body $authBody `
                -ContentType "application/json" -WebSession $labelSess -TimeoutSec 20 -ErrorAction Stop
            if ($authRes.result -eq $true) { $labelAuth = $true } else { Start-Sleep -Seconds 3 }
        } catch {
            Start-Sleep -Seconds 3
        }
    }
    if (-not $labelAuth) {
        Write-Warning "  -> Deluge Web UI did not accept the admin password -- labels not created."
        Write-DebugLog "WARN" "Deluge label setup skipped: auth.login never succeeded"
        return
    }

    $labelExisting = @()
    try {
        $listBody = @{ method = "label.get_labels"; params = @(); id = 2 } | ConvertTo-Json -Compress
        $listRes  = Invoke-RestMethod -Uri $labelJsonUrl -Method Post -Body $listBody `
            -ContentType "application/json" -WebSession $labelSess -TimeoutSec 20 -ErrorAction Stop
        $labelExisting = @($listRes.result | Where-Object { $null -ne $_ })
    } catch {
        Write-DebugLog "WARN" "label.get_labels failed: $_"
    }
    Write-DebugLog "VAR Deluge labels before=$($labelExisting -join ',')"

    $labelAdded = 0
    foreach ($labelName in $Labels) {
        if ($labelExisting -contains $labelName) { continue }
        try {
            $addBody = @{ method = "label.add"; params = @($labelName); id = 3 } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri $labelJsonUrl -Method Post -Body $addBody `
                -ContentType "application/json" -WebSession $labelSess -TimeoutSec 20 -ErrorAction Stop | Out-Null
            $labelAdded++
            Write-DebugLog "INFO" "Deluge label '$labelName' created"
        } catch {
            Write-Warning "  -> Could not create Deluge label '$labelName': $_"
            Write-DebugLog "WARN" "label.add '$labelName' failed: $_"
        }
    }

    # Read back rather than trusting label.add: a plugin that is not enabled accepts
    # the RPC and silently does nothing. The daemon applies the add asynchronously,
    # so poll instead of reading once -- a single immediate read returned the
    # pre-change list on a fresh install, which turned a working setup into a red
    # "labels still missing" error.
    $labelFinal   = @()
    $labelDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $labelDeadline) {
        $labelFinal = @()
        try {
            $verifyBody = @{ method = "label.get_labels"; params = @(); id = 4 } | ConvertTo-Json -Compress
            $verifyRes  = Invoke-RestMethod -Uri $labelJsonUrl -Method Post -Body $verifyBody `
                -ContentType "application/json" -WebSession $labelSess -TimeoutSec 20 -ErrorAction Stop
            $labelFinal = @($verifyRes.result | Where-Object { $null -ne $_ })
        } catch {
            Write-DebugLog "WARN" "label.get_labels verify failed: $_"
        }
        $labelMissing = @($Labels | Where-Object { $labelFinal -notcontains $_ })
        if ($labelMissing.Count -eq 0) { break }
        Start-Sleep -Seconds 2
    }
    $labelMissing = @($Labels | Where-Object { $labelFinal -notcontains $_ })
    if ($labelMissing.Count -eq 0) {
        Write-Host "  -> Deluge labels ready: $($labelFinal -join ', ')" -ForegroundColor Green
        Write-DebugLog "INFO" "Deluge labels ready (added=$labelAdded): $($labelFinal -join ',')"
    } else {
        Write-Warning "  -> Deluge is missing label(s): $($labelMissing -join ', ') -- downloads from those categories will fail."
        Write-DebugLog "ERROR" "Deluge labels still missing: $($labelMissing -join ',')"
    }
}

if ($Config.Apps.Deluge -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Deluge != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    # A Deluge installed before the label step existed still has no labels, so heal
    # it on every run rather than only when the lock file is absent.
    $svcWebInstalled = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
    if ($svcWebInstalled -and $svcWebInstalled.Status -eq "Running") {
        Ensure-DelugeLabels -Port $WebPort -Labels $DelugeLabels
    } else {
        Write-DebugLog "WARN" "Deluge labels not checked: DelugeWeb is not running"
    }
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Deluge from the upstream mirror ----------------------------------------
# Chocolatey still ships Deluge 2.1.1, whose Web UI cannot work behind a reverse
# proxy: 2.1.1 registers its Twisted base child with a str key while Twisted
# traverses with bytes, so every /deluge/... request 404s and Caddy's
# "handle /deluge*" block can never serve it.  Upstream fixed that after the
# 2.1.1 release (Deluge PRs #390/#391) and publishes the fixed build as an NSIS
# installer, so Deluge is installed from the upstream mirror instead; Chocolatey
# is kept only as a guarded fallback (see 1b below).
#
# NOTE: this acquisition block is duplicated verbatim in scripts\07_deluge.ps1
# and scripts\update_deluge.ps1 -- the installer and the updater must use exactly
# the same discovery and verification path, so keep both copies in sync.
$DelugeMirrorIndexUrl   = "https://ftp.osuosl.org/pub/deluge/windows/"
$DelugeMirrorVersionUrl = "https://ftp.osuosl.org/pub/deluge/version"
# First release carrying the Twisted base-path fix.  Older builds reintroduce the
# /deluge 404, so they are refused rather than installed.
$DelugeMinFixedVersion  = "2.2.0"
$DelugeReleaseRegex     = '^\d+(\.\d+)+$'
# The upstream NSIS script sets InstallDir "$PROGRAMFILES64\Deluge", which is
# therefore where the service binaries are expected to land.
$DelugeTargetDir        = Join-Path $env:ProgramFiles "Deluge"

$DelugeManifest = if ($Config -and $Config.PSObject.Properties["_Versions"] -and
                      $Config._Versions.PSObject.Properties["Apps"] -and
                      $Config._Versions.Apps.PSObject.Properties["Deluge"]) {
                      $Config._Versions.Apps.Deluge
                  } else { $null }
# Optional manifest overrides so another mirror can be used without editing this
# script (keys: url = windows/ directory listing, versionUrl = release marker).
if ($DelugeManifest -and $DelugeManifest.PSObject.Properties["url"] -and $DelugeManifest.url) {
    $DelugeMirrorIndexUrl = $DelugeManifest.url
}
if ($DelugeManifest -and $DelugeManifest.PSObject.Properties["versionUrl"] -and $DelugeManifest.versionUrl) {
    $DelugeMirrorVersionUrl = $DelugeManifest.versionUrl
}

# The mirror is HTTPS and a fresh PowerShell 5.1 session still negotiates TLS 1.0
# by default (00_prerequisites.ps1 only raises it for the Chocolatey bootstrap).
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
    Write-DebugLog "WARN" "Could not enable TLS 1.2: $_"
}

function ConvertTo-DelugeVersionParts {
    # "2.10.0" -> 2,10,0.  Callers validate the shape first.
    param([Parameter(Mandatory=$true)][string]$Version)
    $clean = ($Version -replace '^[vV]', '').Trim()
    return @($clean.Split('.') | ForEach-Object { [int]$_ })
}

function Compare-DelugeVersionString {
    # Numeric, segment-wise comparison, so 2.10.0 ranks above 2.9.0 (a plain
    # string sort would pick the older build).  Returns -1, 0 or 1.
    param([Parameter(Mandatory=$true)][string]$A, [Parameter(Mandatory=$true)][string]$B)
    $partsA = ConvertTo-DelugeVersionParts -Version $A
    $partsB = ConvertTo-DelugeVersionParts -Version $B
    $max = [Math]::Max($partsA.Count, $partsB.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $segA = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
        $segB = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }
        if ($segA -lt $segB) { return -1 }
        if ($segA -gt $segB) { return 1 }
    }
    return 0
}

function ConvertTo-DelugeText {
    # Invoke-WebRequest hands back .Content as a byte[] for responses the server
    # does not label as text (the OSUOSL mirror serves "version" and ".sha256"
    # as application/octet-stream).  A [string] cast would render that as
    # "50 46 50 46 48 10", so decode explicitly.
    param([object]$Content)
    if ($null -eq $Content) { return "" }
    if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
    return [string]$Content
}

function Get-DelugeMirrorListing {
    # File names published in the mirror's windows/ directory.  The page is an
    # Apache autoindex: one <a href="name">name</a> per entry, mixed with sort
    # links, a parent link and the site's own "https://..." chrome.
    param([Parameter(Mandatory=$true)][string]$IndexUrl)
    $response = Invoke-WebRequest -Uri $IndexUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $html     = ConvertTo-DelugeText -Content $response.Content
    $names    = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($html, 'href="([^"]+)"')) {
        $name = [System.Uri]::UnescapeDataString($match.Groups[1].Value)
        # Keep plain entry names only: this drops the "?C=N;O=D" sort links, the
        # "/pub/deluge/" parent link and the "https://..." site chrome.
        if (-not $name -or $name.Contains("/") -or $name.Contains("?") -or $name.Contains(":")) { continue }
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    Write-DebugLog "INFO" "Deluge mirror listing $IndexUrl returned $($names.Count) entries"
    return $names.ToArray()
}

function Get-DelugeMirrorReleaseMarker {
    # The mirror publishes the current release as plain text next to the windows/
    # directory (observed: "2.2.0\n").  Anything that is not a plain release
    # number (empty, an HTML error page, "2.3.0-rc1") is ignored.
    param([string]$VersionUrl)
    if (-not $VersionUrl) { return $null }
    try {
        $response = Invoke-WebRequest -Uri $VersionUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $content  = ConvertTo-DelugeText -Content $response.Content
    } catch {
        Write-DebugLog "WARN" "Deluge release marker unreachable ($VersionUrl): $_"
        return $null
    }
    $marker = $content.TrimStart([char]0xFEFF).Trim()
    if ($marker -match $DelugeReleaseRegex) { return $marker }
    Write-DebugLog "WARN" "Deluge release marker is not a plain release version: '$marker'"
    return $null
}

function Select-DelugeMirrorRelease {
    # Highest published "deluge-<version>-win64-setup.exe" that also has its
    # sibling ".sha256".  Only a bare "<digits>[.<digits>...]" version is
    # accepted between the prefix and "-win64-setup.exe", so pre-releases
    # ("-rc1", "-beta"), 32-bit and libtorrent-variant ("-lt2.0") builds can
    # never win.  Returns $null when nothing qualifies.
    param([Parameter(Mandatory=$true)][string[]]$Names)
    $bestVersion = $null
    $bestFile    = $null
    foreach ($name in $Names) {
        if ($name -notmatch '^deluge-.*setup\.exe$') { continue }
        $match = [regex]::Match($name, '^deluge-(?<ver>\d+(?:\.\d+)+)-win64-setup\.exe$')
        if (-not $match.Success) {
            Write-DebugLog "VAR" "Skipping mirror build (not a plain win64 release): $name"
            continue
        }
        $version = $match.Groups['ver'].Value
        if ($Names -notcontains "$name.sha256") {
            Write-DebugLog "VAR" "Skipping mirror build (no .sha256 sibling published): $name"
            continue
        }
        if ((Compare-DelugeVersionString -A $version -B $DelugeMinFixedVersion) -lt 0) {
            Write-DebugLog "VAR" "Skipping mirror build (older than $DelugeMinFixedVersion): $name"
            continue
        }
        if (-not $bestVersion -or (Compare-DelugeVersionString -A $version -B $bestVersion) -gt 0) {
            $bestVersion = $version
            $bestFile    = $name
        }
    }
    if (-not $bestFile) { return $null }
    return [PSCustomObject]@{ Version = $bestVersion; FileName = $bestFile }
}

function Resolve-DelugeRelease {
    # Decides which build to install, and never guesses:
    #   pin    - versions.json names an exact version (must exist on the mirror)
    #   marker - the mirror's release marker, once its Windows build is published
    #   index  - highest matching version in the windows/ listing
    # A parse or lookup failure throws instead of silently falling back to an
    # older/different build.
    param(
        [string]$PinnedVersion,
        [string]$IndexUrl   = $DelugeMirrorIndexUrl,
        [string]$VersionUrl = $DelugeMirrorVersionUrl
    )
    if ($PinnedVersion) {
        $pin = $PinnedVersion.Trim()
        if ($pin.StartsWith("v") -or $pin.StartsWith("V")) { $pin = $pin.Substring(1) }
        if ($pin -notmatch $DelugeReleaseRegex) {
            throw "versions.json pins Deluge to '$PinnedVersion', which is not a plain version number"
        }
        if ((Compare-DelugeVersionString -A $pin -B $DelugeMinFixedVersion) -lt 0) {
            throw ("versions.json pins Deluge $pin, which predates $DelugeMinFixedVersion and has the broken " +
                   "/deluge base path - set Apps.Deluge.version to $DelugeMinFixedVersion or to 'latest'")
        }
        return [PSCustomObject]@{ Version = $pin; FileName = "deluge-$pin-win64-setup.exe"; Source = "pin" }
    }

    $names  = Get-DelugeMirrorListing -IndexUrl $IndexUrl
    $marker = Get-DelugeMirrorReleaseMarker -VersionUrl $VersionUrl
    if ($marker) {
        $markerFile = "deluge-$marker-win64-setup.exe"
        if (($names -contains $markerFile) -and ($names -contains "$markerFile.sha256") -and
            ((Compare-DelugeVersionString -A $marker -B $DelugeMinFixedVersion) -ge 0)) {
            return [PSCustomObject]@{ Version = $marker; FileName = $markerFile; Source = "marker" }
        }
        Write-DebugLog "WARN" "Release marker '$marker' has no installable Windows build in $IndexUrl; using the newest published build instead"
    }
    $pick = Select-DelugeMirrorRelease -Names $names
    if (-not $pick) {
        throw "no deluge-<version>-win64-setup.exe with a .sha256 sibling and version >= $DelugeMinFixedVersion is published in $IndexUrl"
    }
    return [PSCustomObject]@{ Version = $pick.Version; FileName = $pick.FileName; Source = "index" }
}

function Save-DelugeInstaller {
    # Downloads "<file>" plus its sibling "<file>.sha256" and verifies the hash
    # before the file is ever executed.  The installer is cached in $Destination,
    # but its hash is re-checked on every run against a freshly fetched .sha256,
    # so a truncated or tampered cache entry can never be installed.
    # Returns the path of the verified installer; throws on any mismatch.
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][string]$IndexUrl,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    if (-not (Test-Path $Destination)) { New-Item -Path $Destination -ItemType Directory -Force | Out-Null }
    $installerPath = Join-Path $Destination $FileName

    $shaUrl = "$IndexUrl$FileName.sha256"
    $shaResponse = Invoke-WebRequest -Uri $shaUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $shaRaw = ConvertTo-DelugeText -Content $shaResponse.Content
    # Observed format is sha256sum text mode: "<64 lowercase hex>  <filename>\n"
    # (two spaces, LF terminated).  Any separator is accepted, but the digest
    # must be the first token and a named artifact must be the one we asked for.
    $shaMatch = [regex]::Match($shaRaw.Trim(), '^(?<hash>[0-9a-fA-F]{64})(?:\s+\*?(?<name>\S+))?$')
    if (-not $shaMatch.Success) {
        throw "cannot parse $shaUrl (expected a 64 hex digit SHA256 digest)"
    }
    $expectedHash = $shaMatch.Groups['hash'].Value
    if ($shaMatch.Groups['name'].Success -and $shaMatch.Groups['name'].Value -ine $FileName) {
        throw "checksum file $shaUrl names '$($shaMatch.Groups['name'].Value)', not '$FileName'"
    }

    if (Test-Path $installerPath) {
        $cachedHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
        if ($cachedHash -ieq $expectedHash) {
            Write-DebugLog "INFO" "Reusing verified installer $installerPath ($expectedHash)"
            return $installerPath
        }
        Write-DebugLog "WARN" "Cached installer hash mismatch ($cachedHash); re-downloading $FileName"
        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    }

    # Download to a side name: a half-written file must never look like a usable
    # installer to a later run.
    $partialPath = "$installerPath.download"
    Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -Uri "$IndexUrl$FileName" -OutFile $partialPath -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop
    } catch {
        Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue
        throw
    }
    $actualHash = (Get-FileHash -Path $partialPath -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) {
        Remove-Item -Path $partialPath -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch for $FileName (expected $expectedHash, got $actualHash) - refusing to install"
    }
    Move-Item -Path $partialPath -Destination $installerPath -Force
    Write-DebugLog "INFO" "Verified $FileName (SHA256 $actualHash) -> $installerPath"
    return $installerPath
}

function Stop-DelugeForInstall {
    # The upstream installer aborts when a Deluge process is alive (its .onInit
    # checks the "deluge" mutex) and it cannot replace deluged.exe while the
    # daemon holds the image open - either way a silent install would be a no-op.
    param(
        [string[]]$ServiceNames = @("DelugeDaemon", "DelugeWeb"),
        [string[]]$ProcessNames = @("deluged", "deluge-web")
    )
    foreach ($svcName in $ServiceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Stopped") {
            Write-DebugLog "INFO" "Stopping service $svcName (was $($svc.Status))"
            $null = Stop-ServiceBounded -Name $svcName
        }
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 1
    }
    foreach ($proc in @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)) {
        Write-DebugLog "WARN" "Force-stopping lingering $($proc.ProcessName) (pid $($proc.Id))"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Install-DelugeFromMirror {
    # Runs the NSIS installer unattended into $TargetDir.
    # "/S" is NSIS's silent switch and "/D=<dir>" overrides $INSTDIR; /D has to be
    # the last argument and must NOT be quoted, so the argument string is handed
    # to CreateProcess verbatim (Start-Process or the call operator would wrap the
    # "Program Files" path in quotes and break NSIS's own parsing).
    param(
        [Parameter(Mandatory=$true)][string]$InstallerPath,
        [Parameter(Mandatory=$true)][string]$TargetDir
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName         = $InstallerPath
    $startInfo.Arguments        = "/S /D=$TargetDir"
    $startInfo.UseShellExecute  = $false
    $startInfo.WorkingDirectory = Split-Path $InstallerPath
    Write-DebugLog "INFO" "Running `"$InstallerPath`" /S /D=$TargetDir"
    $proc = [System.Diagnostics.Process]::Start($startInfo)
    if (-not $proc.WaitForExit(900000)) {
        $proc.Kill()
        throw "the Deluge installer did not finish within 15 minutes"
    }
    Write-DebugLog "INFO" "Deluge installer exit code=$($proc.ExitCode)"
    return $proc.ExitCode
}

function Wait-DelugeInstalled {
    # NSIS can return before every payload file is flushed, so the exit code is
    # not trusted: poll for the binaries the NSSM services need.
    param(
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [int]$TimeoutSeconds = 180
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path (Join-Path $TargetDir "deluged.exe")) -and (Test-Path (Join-Path $TargetDir "deluge-web.exe"))) {
            Write-DebugLog "INFO" "Deluge payload present in $TargetDir"
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-DelugeInstalledVersion {
    # Reads the version of the build on disk.  The upstream PyInstaller layout
    # ships "_internal\deluge-<version>.dist-info\METADATA", which is the only
    # trustworthy record of what is installed (Chocolatey's bookkeeping knows
    # nothing about an installer that was run directly).
    param([Parameter(Mandatory=$true)][string]$TargetDir)
    foreach ($root in @((Join-Path $TargetDir "_internal"), $TargetDir)) {
        if (-not (Test-Path $root)) { continue }
        $distInfo = Get-ChildItem -Path $root -Directory -Filter "deluge-*.dist-info" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $distInfo) { continue }
        $metadataPath = Join-Path $distInfo.FullName "METADATA"
        if (Test-Path $metadataPath) {
            $versionLines = @(Get-Content -Path $metadataPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^Version:\s*\S' })
            if ($versionLines.Count -gt 0) {
                $detected = ($versionLines[0] -replace '^Version:\s*', '').Trim()
                if ($detected -match $DelugeReleaseRegex) { return $detected }
            }
        }
        if ($distInfo.Name -match '^deluge-(?<ver>\d+(?:\.\d+)+)\.dist-info$') {
            return $Matches['ver']
        }
    }
    return $null
}

function Install-DelugeRelease {
    # Runs a verified installer and returns the version that ends up on disk.  An
    # installer that silently aborts (a lingering Deluge process) must not be
    # mistaken for a success, so the result is read off the payload instead of
    # from the exit code: the version has to match the installer that ran and,
    # when the layout carries no readable version, the executable still has to
    # have been replaced.
    param(
        [Parameter(Mandatory=$true)][string]$InstallerPath,
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [Parameter(Mandatory=$true)][string]$ExpectedVersion
    )
    $exePath    = Join-Path $TargetDir "deluged.exe"
    $beforeTime = if (Test-Path $exePath) { (Get-Item $exePath).LastWriteTimeUtc } else { $null }

    Install-DelugeFromMirror -InstallerPath $InstallerPath -TargetDir $TargetDir | Out-Null
    if (-not (Wait-DelugeInstalled -TargetDir $TargetDir)) {
        throw "the installer finished but $exePath never appeared (is another Deluge instance running?)"
    }
    $afterTime   = (Get-Item $exePath).LastWriteTimeUtc
    $wasReplaced = (-not $beforeTime) -or ($afterTime -ne $beforeTime)
    $detected    = Get-DelugeInstalledVersion -TargetDir $TargetDir

    if ($detected) {
        if ((Compare-DelugeVersionString -A $detected -B $ExpectedVersion) -ne 0) {
            if (-not $wasReplaced) {
                throw "the installer did not replace $exePath - it aborts while a Deluge process is running (build on disk is $detected, expected $ExpectedVersion)"
            }
            throw "the build on disk is Deluge $detected, not the verified $ExpectedVersion"
        }
        return $detected
    }
    # No readable version in the payload (a non-PyInstaller layout): the only
    # evidence available is that the executable was actually swapped.
    if (-not $wasReplaced) {
        throw "the installer did not replace $exePath - it aborts while a Deluge process is running"
    }
    Write-DebugLog "WARN" "No on-disk Deluge version found in $TargetDir; trusting the verified installer version $ExpectedVersion"
    return $ExpectedVersion
}

function Get-ChocoAvailableVersion {
    # Version Chocolatey would install for a package (repository metadata).  This
    # is a REMOTE query -- the one community.chocolatey.org intermittently answers
    # with 503/504 -- so it goes through Invoke-Choco, which retries that class of
    # failure instead of letting it abort the step.
    param([Parameter(Mandatory=$true)][string]$Package)
    $result = Invoke-Choco -Arguments @('search', $Package, '--exact', '-r') -Quiet
    $output = if ($result.Ran) { $result.Output } else { $null }
    Write-DebugLog "VAR choco search $Package --exact -r => $output"
    if ($result.Ran -and ($result.ExitCode -ne 0 -or $result.Transient)) {
        $searchTail = [string]$output
        if ($searchTail.Length -gt 800) { $searchTail = $searchTail.Substring($searchTail.Length - 800) }
        Write-DebugLog "WARN" "choco search $Package failed (exit $($result.ExitCode), transient=$($result.Transient), attempts=$($result.Attempts)): $searchTail"
    }
    if ([string]::IsNullOrWhiteSpace($output)) { return $null }
    $parts = ([string]($output -split "`n" | Where-Object { $_ -match '\|' } | Select-Object -First 1)) -split '\|'
    if ($parts.Count -ge 2 -and $parts[1].Trim()) { return $parts[1].Trim() }
    return $null
}

$PinnedVersion = if ($DelugeManifest) { $DelugeManifest.version } else { $null }
# "latest"/"unknown" are manifest sentinels, not versions: discover the newest
# published build instead of failing the step.
if ($PinnedVersion -and ($PinnedVersion -ieq "latest" -or $PinnedVersion -ieq "unknown")) {
    Write-DebugLog "WARN" "Ignoring non-version manifest pin for Deluge: '$PinnedVersion'"
    $PinnedVersion = $null
}

function Get-InstalledChocoVersion {
    # Reads what Chocolatey reports for a package.
    # Returns: "<version>" | "unknown" (listed but unparseable) | $null (absent)
    param([Parameter(Mandatory=$true)][string]$Package)
    $listOutput = Get-ChocoInstalledVersion -Package $Package
    Write-DebugLog "VAR choco list --exact $Package -r => $listOutput"
    return $listOutput
}

$DelugeDownloadDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR PinnedVersion=$PinnedVersion DelugeTargetDir=$DelugeTargetDir DelugeDownloadDir=$DelugeDownloadDir"

# A box that was installed through Chocolatey still has the broken 2.1.1
# registered there; log it, because the mirror build now owns those binaries.
if (Resolve-ChocoExe) {
    Write-DebugLog "VAR choco reports deluge $(Get-InstalledChocoVersion -Package 'deluge')"
} else {
    Write-DebugLog "WARN" "choco not found - the Chocolatey fallback is unavailable (the mirror path does not need it)"
}

$installedVersion = Get-DelugeInstalledVersion -TargetDir $DelugeTargetDir
if ($installedVersion) {
    Write-DebugLog "INFO" "Deluge build already on disk: $installedVersion"
}

# 1a. Preferred path: the checksum-verified upstream installer.
$acquirePath   = $null
$delugeRelease = $null
try {
    $delugeRelease = Resolve-DelugeRelease -PinnedVersion $PinnedVersion
    Write-Host "  -> Installing Deluge $($delugeRelease.Version) from the upstream mirror (resolved via $($delugeRelease.Source))..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Resolved Deluge $($delugeRelease.Version) ($($delugeRelease.FileName)) via $($delugeRelease.Source)"

    $delugeInstaller = Save-DelugeInstaller -FileName $delugeRelease.FileName -IndexUrl $DelugeMirrorIndexUrl -Destination $DelugeDownloadDir
    Stop-DelugeForInstall
    $installedVersion = Install-DelugeRelease -InstallerPath $delugeInstaller -TargetDir $DelugeTargetDir -ExpectedVersion $delugeRelease.Version
    $acquirePath = "ftp"
} catch {
    Write-Warning "[$AppName] Upstream mirror install failed: $($_.Exception.Message)"
    Write-DebugLog "WARN" "Upstream mirror install failed: $_"

    # 1b. Last resort: Chocolatey, and only when its repository offers a build
    # that already contains the Twisted base-path fix (under a pin: exactly the
    # pinned version).  Chocolatey still serves 2.1.1, and silently installing
    # that would rebuild the /deluge 404 this path exists to fix, so an older
    # candidate is refused -- failing is better than a broken Web UI.
    if (-not (Resolve-ChocoExe)) {
        Write-Warning "[$AppName] Chocolatey is not available (00_prerequisites.ps1 installs it) and the mirror path failed. Cannot install Deluge."
        Write-DebugLog "ERROR" "choco not found (searched PATH, the standard install path and the registry) and the mirror path failed; aborting Deluge install"
        exit 1
    }
    $chocoCandidate = Get-ChocoAvailableVersion -Package "deluge"
    $fallbackReason = $null
    if (-not $chocoCandidate) {
        $fallbackReason = "Chocolatey has no 'deluge' package to offer"
    } elseif ($chocoCandidate -notmatch $DelugeReleaseRegex) {
        $fallbackReason = "Chocolatey offers Deluge '$chocoCandidate', which is not a plain version number"
    } elseif ((Compare-DelugeVersionString -A $chocoCandidate -B $DelugeMinFixedVersion) -lt 0) {
        $fallbackReason = "Chocolatey only offers Deluge $chocoCandidate, which predates $DelugeMinFixedVersion and has the broken /deluge base path"
    } elseif ($PinnedVersion -and ($chocoCandidate -ine $PinnedVersion)) {
        $fallbackReason = "Chocolatey offers Deluge $chocoCandidate, not the pinned $PinnedVersion"
    }
    if ($fallbackReason) {
        Write-Warning "[$AppName] Refusing the Chocolatey fallback: $fallbackReason."
        Write-DebugLog "ERROR" "Chocolatey fallback refused: $fallbackReason"
        exit 1
    }

    Write-Host "  -> Falling back to Chocolatey (deluge $chocoCandidate)..." -ForegroundColor Yellow
    Write-DebugLog "WARN" "Falling back to Chocolatey for deluge $chocoCandidate"
    $delugeInstall = Invoke-Choco -Arguments @('install', 'deluge', '--version', $chocoCandidate, '-y', '--no-progress')
    $delugeTail = $delugeInstall.Output
    if ($delugeTail -and $delugeTail.Length -gt 800) { $delugeTail = $delugeTail.Substring($delugeTail.Length - 800) }
    Write-DebugLog "INFO" "choco install deluge exit=$($delugeInstall.ExitCode) attempts=$($delugeInstall.Attempts)"
    if (-not $delugeInstall.Ran) {
        Write-DebugLog "ERROR" "choco install deluge: choco.exe not found"
    } elseif ($delugeInstall.ExitCode -ne 0 -or $delugeInstall.Transient) {
        Write-Warning "[$AppName] choco install deluge returned exit code $($delugeInstall.ExitCode). Checking whether the package landed anyway..."
        Write-DebugLog "WARN" "choco install deluge non-zero exit (exit $($delugeInstall.ExitCode), transient=$($delugeInstall.Transient), attempts=$($delugeInstall.Attempts)): $delugeTail"
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-DebugLog "INFO" "PATH refreshed after deluge install"
    $acquirePath = "choco"
    # The exit code alone is not authoritative (choco returns non-zero for warnings
    # such as a pending reboot): read the version off the installed payload.
    $installedVersion = Get-DelugeInstalledVersion -TargetDir $DelugeTargetDir
    if (-not $installedVersion) { $installedVersion = $chocoCandidate }
}

if (-not $installedVersion) {
    # Writing the lock file and the ledger entry after a failed install would make every
    # later run report "Already installed. Skipping." (a stale deluge.exe on the box makes
    # this reachable even when the payload is gone) and would tell the updater that the
    # manifest pin is installed, so a transient mirror/network failure could never be
    # retried. Leave both untouched and fail the step so master_install.ps1 logs Deluge as
    # failed and a re-run installs it.
    Write-Warning "[$AppName] No Deluge build is present after the install attempt. Not writing the lock file so a re-run retries."
    Write-DebugLog "ERROR" "Deluge absent after install attempt (path=$acquirePath); lock file not written"
    exit 1
}
Write-DebugLog "INFO" "Deluge acquired via '$acquirePath'; on-disk version=$installedVersion"
Write-Host "  -> Deluge $installedVersion installed (source: $acquirePath)." -ForegroundColor Green

# Find deluged.exe and deluge-web.exe.  The mirror install directory is probed
# first on purpose: a leftover Chocolatey shim in C:\ProgramData\chocolatey\bin
# could otherwise win and point at the broken 2.1.1 build.
$delugeCandidates = New-Object System.Collections.Generic.List[string]
$delugeCandidates.Add((Join-Path $DelugeTargetDir "deluged.exe"))
$delugedOnPath = Get-Command deluged.exe -ErrorAction SilentlyContinue
if ($delugedOnPath) { $delugeCandidates.Add($delugedOnPath.Source) }
$delugeCandidates.Add("C:\ProgramData\chocolatey\bin\deluged.exe")
foreach ($delugeRoot in (Get-ChildItem "C:\Program Files" -Directory -Filter "Deluge*" -ErrorAction SilentlyContinue)) {
    $delugeCandidate = Get-ChildItem $delugeRoot.FullName -Filter "deluged.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($delugeCandidate) { $delugeCandidates.Add($delugeCandidate.FullName) }
}
$delugedPath = $null
foreach ($candidate in $delugeCandidates) {
    if ($candidate -and (Test-Path $candidate)) { $delugedPath = $candidate; break }
}
Write-DebugLog "VAR delugedPath=$delugedPath"
Write-DebugLog "VAR deluged candidates: $($delugeCandidates -join ' | ')"
if (-not $delugedPath) {
    Write-Error "[$AppName] deluged.exe not found. The Deluge install may have failed."
    Write-DebugLog "ERROR" "deluged.exe not found in $DelugeTargetDir, PATH, chocolatey bin or C:\Program Files\Deluge*"
    exit 1
}

# Same directory as the daemon, so daemon and Web UI always come from one build.
$delugeWebPath = Join-Path (Split-Path $delugedPath) "deluge-web.exe"
if (-not (Test-Path $delugeWebPath)) {
    $delugeWebOnPath = Get-Command deluge-web.exe -ErrorAction SilentlyContinue
    $delugeWebPath = if ($delugeWebOnPath) { $delugeWebOnPath.Source } else { $null }
}
Write-DebugLog "VAR delugeWebPath=$delugeWebPath"
if (-not $delugeWebPath) {
    Write-Warning "[$AppName] deluge-web.exe not found. Web UI will not be available."
    Write-DebugLog "WARN" "deluge-web.exe not found. Web UI skipped."
}

# -- 2. Data directory + ACLs --------------------------------------------------
Write-DebugLog "VAR DataDir exists=$(Test-Path $DataDir)"
if (-not (Test-Path $DataDir)) {
    New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created $DataDir"
}
Grant-SeedboxDirAccess -Path $DataDir -Username $SvcUser

# The daemon runs as $SvcUser and writes every download into Paths.Downloads, but
# master_install only creates that directory -- it never grants the service account
# access, so this relies on the drive's inherited ACL.  Grant it explicitly.
if ($dlPath) {
    Grant-SeedboxDirAccess -Path $dlPath -Username $SvcUser
} else {
    Write-Warning "[$AppName] Paths.Downloads is not set in config.json -- download location ACL not configured."
    Write-DebugLog "WARN" "Paths.Downloads empty -- skipped ACL grant for download location"
}

# -- 2b. Restore Deluge state from previous install ---------------------------
$DelugeBackupDir = Join-Path $env:LOCALAPPDATA "win-seedbox\deluge-state-backup"
$DelugeBackupStateDir = Join-Path $DelugeBackupDir "state"
Write-DebugLog "VAR DelugeBackupDir=$DelugeBackupDir (exists=$(Test-Path $DelugeBackupDir))"
Write-DebugLog "VAR DelugeBackupStateDir=$DelugeBackupStateDir (exists=$(Test-Path $DelugeBackupStateDir))"
if ((Test-Path $DelugeBackupStateDir) -and -not (Test-Path (Join-Path $DataDir "state"))) {
    Write-Host "  -> Restoring Deluge torrent state from previous install..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Restoring Deluge state from $DelugeBackupStateDir to $DataDir\state"
    Copy-Item -Recurse -Force $DelugeBackupStateDir "$DataDir\state" -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "Deluge state restored successfully"
    # Clean up backup to avoid stale restores on future reinstalls
    Remove-Item -Recurse -Force $DelugeBackupDir -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "Deluge backup cleaned up after successful restore"
} elseif (Test-Path $DelugeBackupDir) {
    Write-DebugLog "INFO" "Deluge backup found but DataDir\state already exists -- skip restore"
} else {
    Write-DebugLog "INFO" "No Deluge state backup found"
}

# -- 3. Generate auth file -----------------------------------------------------
Set-SecretsDirAcl -Path $SecretsDir -SvcUsername $SvcUser
$DelugeAuthFile = Join-Path $SecretsDir "deluge_auth.txt"
$delugeAuthExists = Test-Path $DelugeAuthFile
Write-DebugLog "VAR DelugeAuthFile exists=$delugeAuthExists"

if (-not $delugeAuthExists) {
    # Use the admin password from config.json so users only need one credential.
    # The same password protects the dashboard (Caddy basic_auth) and Deluge Web UI.
    $DelugePassword = $Config.General.AdminPassword
    # BOM-free: this file is read as a credential -- no stray BOM allowed
    [System.IO.File]::WriteAllText($DelugeAuthFile, $DelugePassword, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> Saved Deluge auth password -> $DelugeAuthFile" -ForegroundColor Gray
    Write-DebugLog "INFO" "Using admin password for Deluge. Saved to $DelugeAuthFile"
} else {
    $DelugePassword = (Get-Content -Path $DelugeAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    Write-DebugLog "INFO" "Using existing Deluge password from $DelugeAuthFile"
}

Write-DebugLog "VAR DelugePassword=[REDACTED] (length=$($DelugePassword.Length))"

# -- 4. Write Deluge config files ----------------------------------------------
if (-not (Test-Path $AuthFile)) {
    Write-Host "  -> Writing Deluge auth file..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing auth file to $AuthFile"
    # Format: username:password:auth_level (10 = admin)
    # localclient allows localhost connections without password check
    $authContent = "localclient:`$1`$localclient:10`r`nseedbox:${DelugePassword}:10`r`n"
    # BOM-free -- Deluge reads auth line-by-line
    [System.IO.File]::WriteAllText($AuthFile, $authContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> Deluge auth file written to $AuthFile" -ForegroundColor Green
    Write-DebugLog "INFO" "Auth file written with localclient + seedbox accounts"
} else {
    Write-DebugLog "INFO" "Auth file already exists at $AuthFile -- not overwritten"
}

# Write core.conf -- Deluge config JSON (two-line format: header + config)
if (-not (Test-Path $CoreConf)) {
    Write-Host "  -> Writing deluge core.conf..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing core.conf to $CoreConf"
    $safeDlPath = $dlPath -replace '\\', '/'
    # High port avoids ISP throttling on default 6881 (configurable via Ports.DelugeBT).
    # DHT/LSD enabled for public tracker peer discovery.
    # Private torrents ignore DHT via the private flag automatically.
    # Tuned for 1 Gbps symmetric: 15 active downloads, 50 seeding,
    # 1500 global connections, 8 upload slots per torrent.
    # Upload capped at 720 Mbps (90 MB/s) to leave headroom for TCP ACKs.
    # 2 GiB disk cache (131072 x 16 KiB blocks) reduces HDD random I/O.
    $coreJson = @"
{"file": 1, "format": 1}
{
    "download_location": "$safeDlPath",
    "listen_ports": [$BTPort, $BTPort],
    "random_port": false,
    "dht": true,
    "upnp": true,
    "natpmp": true,
    "lsd": true,
    "utpex": true,
    "max_connections_global": 1500,
    "max_connections_per_second": 200,
    "max_connections_per_torrent": 120,
    "max_half_open_connections": 500,
    "max_upload_slots_global": 100,
    "max_upload_slots_per_torrent": 8,
    "max_active_limit": 100,
    "max_active_seeding": 50,
    "max_active_downloading": 15,
    "max_upload_speed": 90000.0,
    "max_download_speed": -1.0,
    "enc_in_policy": 2,
    "enc_out_policy": 2,
    "enc_level": 2,
    "cache_size": 131072,
    "cache_expiry": 300,
    "stop_seed_at_ratio": false,
    "remove_seed_at_ratio": false,
    "add_paused": false,
    "auto_managed": true,
    "allow_remote": false,
    "daemon_port": $DaemonPort,
    "enabled_plugins": ["Label"]
}
"@
    [System.IO.File]::WriteAllText($CoreConf, $coreJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> core.conf written to $CoreConf" -ForegroundColor Green
    Write-DebugLog "INFO" "core.conf written. download_location=$safeDlPath daemon_port=$DaemonPort"
} else {
    Write-DebugLog "INFO" "core.conf already exists at $CoreConf -- not overwritten"
}

# Write web.conf -- pre-configure Web UI password to match admin password
if (-not (Test-Path $WebConf)) {
    Write-Host "  -> Writing deluge web.conf..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing web.conf to $WebConf"

    # Generate salt and compute SHA1(salt + adminPassword) so the Web UI
    # is immediately usable with the same password as the dashboard.
    $saltBytes = New-Object byte[] 20
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $webSalt = [System.BitConverter]::ToString($saltBytes) -replace '-', '' -replace '([0-9A-F]{2})', '$1'
    $webSalt = $webSalt.Substring(0, 40).ToLower()

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hashInput = [System.Text.Encoding]::UTF8.GetBytes($webSalt + $DelugePassword)
    $webHash = [System.BitConverter]::ToString($sha1.ComputeHash($hashInput)) -replace '-', ''
    $webHash = $webHash.ToLower()

    # "interface" is pinned to loopback on purpose: Deluge's own default is 0.0.0.0,
    # which would expose the Web UI (plain HTTP, direct JSON-RPC, no Caddy basicauth
    # in front of it) to the whole LAN.  Caddy, Sonarr and Radarr all talk to it
    # over 127.0.0.1.
    $webJson = @"
{"file": 1, "format": 1}
{
    "port": $WebPort,
    "interface": "127.0.0.1",
    "enabled": true,
    "allow_remote": false,
    "first_login": false,
    "pwd_salt": "$webSalt",
    "pwd_sha1": "$webHash",
    "session_timeout": 3600,
    "sessions": {}
}
"@
    [System.IO.File]::WriteAllText($WebConf, $webJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> web.conf written (Web UI password pre-configured, loopback-only)" -ForegroundColor Green
    Write-DebugLog "INFO" "web.conf written. port=$WebPort interface=127.0.0.1, first_login=false, password pre-set"
} else {
    Write-DebugLog "INFO" "web.conf already exists at $WebConf -- not overwritten"
}

# -- 5. NSSM services ----------------------------------------------------------
# These services are created and owned by this script; NSSM re-applies their
# parameters idempotently.  When a service already exists it is recycled rather
# than skipped: a machine that was installed by Chocolatey, or one that switched
# DomainMode, would otherwise keep a daemon pointing at the wrong config
# directory or a Web UI without the DuckDNS "--base /deluge" argument, which is
# exactly the setting that makes /deluge work behind Caddy.
function Test-DelugeNssmService {
    param([Parameter(Mandatory=$true)][string]$Name)
    try {
        $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
    } catch {
        Write-DebugLog "WARN" "Could not query service '$Name': $_"
        return $false
    }
    if (-not $serviceInfo -or -not $serviceInfo.PathName) { return $false }
    return ($serviceInfo.PathName -match 'nssm')
}

# Daemon service
Write-Host "  -> Creating Windows services..." -ForegroundColor Gray
$existingDaemon = Get-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeDaemon service exists=$($null -ne $existingDaemon)"
if (-not $existingDaemon) {
    Write-DebugLog "INFO" "Creating NSSM service 'DelugeDaemon' exe=$delugedPath"
    nssm install DelugeDaemon "`"$delugedPath`"" | Out-Null
    nssm set DelugeDaemon AppParameters "--config `"$DataDir`" --loglevel info --logfile `"$DaemonLog`"" | Out-Null
    nssm set DelugeDaemon Description "Deluge BitTorrent Daemon" | Out-Null
    nssm set DelugeDaemon AppDirectory (Split-Path $delugedPath) | Out-Null
    nssm set DelugeDaemon Start SERVICE_AUTO_START | Out-Null
    nssm set DelugeDaemon AppStdout $DaemonLog | Out-Null
    nssm set DelugeDaemon AppStderr $DaemonLog | Out-Null
    nssm set DelugeDaemon AppRotateFiles 1 | Out-Null
    nssm set DelugeDaemon AppRotateBytes 5242880 | Out-Null
    nssm set DelugeDaemon ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set DelugeDaemon AppExit Default Restart | Out-Null
    nssm set DelugeDaemon AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service 'DelugeDaemon' created under '$SvcUser'." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeDaemon' created. config=$DataDir log=$DaemonLog"
} else {
    Write-Host "  -> Service 'DelugeDaemon' already exists." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeDaemon' already exists"
    if (Test-DelugeNssmService -Name "DelugeDaemon") {
        nssm set DelugeDaemon Application "`"$delugedPath`"" | Out-Null
        nssm set DelugeDaemon AppParameters "--config `"$DataDir`" --loglevel info --logfile `"$DaemonLog`"" | Out-Null
        nssm set DelugeDaemon AppDirectory (Split-Path $delugedPath) | Out-Null
        Write-DebugLog "INFO" "Re-applied DelugeDaemon NSSM parameters (exe=$delugedPath config=$DataDir)"
    } else {
        Write-DebugLog "WARN" "Service 'DelugeDaemon' is not NSSM-managed -- leaving its parameters untouched"
    }
}

# Web UI service
$existingWeb = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeWeb service exists=$($null -ne $existingWeb)"
$DomainMode  = $Config.General.DomainMode
$webBaseArg  = if ($DomainMode -eq 'duckdns') { '--base /deluge' } else { '' }
Write-DebugLog "VAR DelugeWeb DomainMode=$DomainMode baseArg='$webBaseArg'"
if (-not $existingWeb -and $delugeWebPath) {
    Write-DebugLog "INFO" "Creating NSSM service 'DelugeWeb' exe=$delugeWebPath"
    nssm install DelugeWeb "`"$delugeWebPath`"" | Out-Null
    nssm set DelugeWeb AppParameters "--config `"$DataDir`" $webBaseArg --loglevel info --logfile `"$WebLog`"" | Out-Null
    nssm set DelugeWeb Description "Deluge Web UI" | Out-Null
    nssm set DelugeWeb AppDirectory (Split-Path $delugeWebPath) | Out-Null
    nssm set DelugeWeb Start SERVICE_AUTO_START | Out-Null
    nssm set DelugeWeb AppStdout $WebLog | Out-Null
    nssm set DelugeWeb AppStderr $WebLog | Out-Null
    nssm set DelugeWeb AppRotateFiles 1 | Out-Null
    nssm set DelugeWeb AppRotateBytes 5242880 | Out-Null
    nssm set DelugeWeb ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set DelugeWeb AppExit Default Restart | Out-Null
    nssm set DelugeWeb AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service 'DelugeWeb' created under '$SvcUser'." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeWeb' created. config=$DataDir log=$WebLog base='$webBaseArg'"
} elseif (-not $delugeWebPath) {
    Write-Host "  -> Skipping DelugeWeb service (deluge-web.exe not found)." -ForegroundColor Yellow
    Write-DebugLog "WARN" "DelugeWeb service skipped: deluge-web.exe not found"
} else {
    Write-Host "  -> Service 'DelugeWeb' already exists." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeWeb' already exists"
    if (Test-DelugeNssmService -Name "DelugeWeb") {
        nssm set DelugeWeb Application "`"$delugeWebPath`"" | Out-Null
        nssm set DelugeWeb AppParameters "--config `"$DataDir`" $webBaseArg --loglevel info --logfile `"$WebLog`"" | Out-Null
        nssm set DelugeWeb AppDirectory (Split-Path $delugeWebPath) | Out-Null
        Write-DebugLog "INFO" "Re-applied DelugeWeb NSSM parameters (exe=$delugeWebPath config=$DataDir base='$webBaseArg')"
        # The base path is only read when the Web UI process starts.
        $runningWeb = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
        if ($runningWeb -and $runningWeb.Status -eq "Running") {
            Write-Host "  -> Restarting DelugeWeb so the base path takes effect..." -ForegroundColor Gray
            $null = Restart-ServiceBounded -Name "DelugeWeb"
            Start-Sleep -Seconds 3
        }
    } else {
        Write-DebugLog "WARN" "Service 'DelugeWeb' is not NSSM-managed -- leaving its parameters untouched"
    }
}

# -- 6. Firewall ---------------------------------------------------------------
# Remove any previous rules first: duplicates with the same DisplayName are allowed,
# so they would otherwise accumulate on every install run.
Get-NetFirewallRule -DisplayName "Deluge BT"     -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName "Deluge BT UDP" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Deluge BT"     -Direction Inbound -LocalPort $BTPort -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "Deluge BT UDP" -Direction Inbound -LocalPort $BTPort -Protocol UDP -Action Allow -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rules added for BitTorrent port $BTPort (TCP+UDP). Daemon port $DaemonPort is NOT opened (localhost-only)"
Write-Host "   -> IMPORTANT: Forward TCP+UDP port $BTPort on your router for optimal speeds." -ForegroundColor Yellow

# -- Fix Web UI: the upstream build only ships deluge-all-debug.js (verified for
#    2.2.0: the payload contains _internal\deluge\ui\web\js\deluge-all-debug.js
#    but no deluge-all.js), causing the Web UI to start in debug mode and fail to
#    display torrents.  The copy is guarded, so a build that does ship
#    deluge-all.js is left untouched.
if ($delugeWebPath) {
    # Layout candidates, in order: the upstream PyInstaller onedir tree
    # (<exe dir>\_internal\deluge\ui\web\js), the older tree, then the same two
    # under the mirror install directory.  A Chocolatey shim resolves to
    # chocolatey\bin, where no js tree exists, so a recursive search of
    # C:\Program Files\Deluge* remains as the last resort.
    $webJsDir = $null
    $webExeDir = Split-Path $delugeWebPath
    foreach ($jsCandidate in @(
            (Join-Path $webExeDir "_internal\deluge\ui\web\js"),
            (Join-Path $webExeDir "deluge\ui\web\js"),
            (Join-Path $DelugeTargetDir "_internal\deluge\ui\web\js"),
            (Join-Path $DelugeTargetDir "deluge\ui\web\js"))) {
        if (Test-Path (Join-Path $jsCandidate "deluge-all-debug.js")) { $webJsDir = $jsCandidate; break }
    }
    if (-not $webJsDir) {
        $delugeInstallRoot = Get-ChildItem "C:\Program Files" -Directory -Filter "Deluge*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($delugeInstallRoot) {
            $foundJs = Get-ChildItem $delugeInstallRoot.FullName -Filter "deluge-all-debug.js" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundJs) {
                $webJsDir = $foundJs.DirectoryName
                Write-DebugLog "INFO" "Deluge Web UI js directory resolved to $webJsDir"
            }
        }
    }
    $debugJs  = if ($webJsDir) { Join-Path $webJsDir "deluge-all-debug.js" } else { $null }
    $normalJs = if ($webJsDir) { Join-Path $webJsDir "deluge-all.js" } else { $null }
    if ($debugJs -and (Test-Path $debugJs) -and -not (Test-Path $normalJs)) {
        Copy-Item $debugJs $normalJs -Force
        Write-Host "  -> Web UI fix applied: $normalJs" -ForegroundColor Gray
        Write-DebugLog "INFO" "Deluge Web UI: copied deluge-all-debug.js -> deluge-all.js to fix debug mode"
    } elseif (-not $debugJs -or -not (Test-Path $debugJs)) {
        Write-DebugLog "WARN" "Deluge Web UI js directory not found (looked in $webJsDir) -- debug-mode fix not applied"
    } else {
        Write-DebugLog "INFO" "Deluge Web UI already ships deluge-all.js -- debug-mode fix not needed"
    }
} else {
    Write-DebugLog "WARN" "deluge-web.exe path unknown -- skipping Web UI debug-mode fix"
}

# -- 7. Start + verify Daemon --------------------------------------------------
Write-Host "  -> Starting DelugeDaemon..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting DelugeDaemon service..."
$null = Start-ServiceBounded -Name "DelugeDaemon"
Start-Sleep -Seconds 5
$svcDaemon = Get-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeDaemon status after start=$(if ($svcDaemon) { $svcDaemon.Status } else { 'NOT FOUND' })"
if ($svcDaemon -and $svcDaemon.Status -eq "Running") {
    Write-Host "  -> DelugeDaemon running on port $DaemonPort (localhost only)." -ForegroundColor Green
    Write-DebugLog "INFO" "DelugeDaemon is Running. Daemon port=$DaemonPort (localhost only)"
} else {
    Write-Warning "  -> DelugeDaemon may not have started. Check $DaemonLog"
    Write-DebugLog "WARN" "DelugeDaemon may not be running. Check $DaemonLog"
}

# -- 8. Start + verify Web UI --------------------------------------------------
if ($delugeWebPath) {
    Write-Host "  -> Starting DelugeWeb..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting DelugeWeb service..."
    $null = Start-ServiceBounded -Name "DelugeWeb"
    Start-Sleep -Seconds 5
    $svcWeb = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
    Write-DebugLog "VAR DelugeWeb status after start=$(if ($svcWeb) { $svcWeb.Status } else { 'NOT FOUND' })"
    if ($svcWeb -and $svcWeb.Status -eq "Running") {
        Write-Host "  -> Deluge Web UI running on port $WebPort (localhost only)." -ForegroundColor Green
        Write-DebugLog "INFO" "DelugeWeb is Running. Web port=$WebPort (localhost only)"
    } else {
        Write-Warning "  -> DelugeWeb may not have started. Check $WebLog"
        Write-DebugLog "WARN" "DelugeWeb may not be running. Check $WebLog"
    }
}

# -- 9. Ensure the labels the *arr download clients hand to Deluge --------------
if ($svcWeb -and $svcWeb.Status -eq "Running") {
    Ensure-DelugeLabels -Port $WebPort -Labels $DelugeLabels
} else {
    Write-DebugLog "WARN" "Deluge labels not created: DelugeWeb is not running"
}

# Record the version of the build that is on disk (read from the installed
# payload), not the manifest pin: a machine that already carried a different
# Deluge build must show up as "update available" in the updater instead of
# being compared pin-vs-pin and reported as current.  $installedVersion was set
# only after a verified install, so the lock file is never written for a failure.
$LockVersion = $installedVersion
[System.IO.File]::WriteAllText($LockFile, $LockVersion, (New-Object System.Text.UTF8Encoding($false)))
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion source=$acquirePath)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $LockVersion

Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "07_deluge.ps1 complete"
