# update_deluge.ps1
# Per-app update script: Deluge (upstream mirror NSIS installer, restart daemon
# + web services).  Chocolatey still ships Deluge 2.1.1, whose Web UI returns 404
# for everything behind a reverse proxy, so the upgrade comes from the upstream
# mirror, exactly like the installer does.
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

$AppName     = "Deluge"
$ServiceList = @("DelugeDaemon", "DelugeWeb")

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
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
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
    # Version Chocolatey would install for a package (repository metadata).
    param([Parameter(Mandatory=$true)][string]$Package)
    $savedEap = $ErrorActionPreference
    $output   = $null
    try {
        $ErrorActionPreference = "Continue"
        $output = choco search $Package --exact -r 2>$null
    } finally {
        $ErrorActionPreference = $savedEap
    }
    Write-DebugLog "VAR choco search $Package --exact -r => $output"
    if ([string]::IsNullOrWhiteSpace($output)) { return $null }
    $parts = ([string]($output | Select-Object -First 1)) -split '\|'
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
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $listOutput = choco list --exact $Package -r 2>$null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "VAR choco list --exact $Package -r => $listOutput"
    if ([string]::IsNullOrWhiteSpace($listOutput)) { return $null }
    $parts = ([string]($listOutput | Select-Object -First 1)) -split '\|'
    if ($parts.Count -ge 2 -and $parts[1].Trim()) { return $parts[1].Trim() }
    return "unknown"
}

# $Version is the plan target (the versions.json pin) and it wins over the
# manifest that was just read: a concrete version is honoured exactly, while
# "latest"/"unknown"/empty stays $null so the mirror discovery decides.
if ($Version -and ($Version -inotmatch '^(latest|unknown)$')) {
    $PinnedVersion = $Version
    Write-UcLog "INFO" "Deluge update pinned to $PinnedVersion"
} else {
    $PinnedVersion = $null
    Write-UcLog "INFO" "Deluge update target '$Version' is not a version - using mirror discovery"
}

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

$release      = $null
$resolveError = $null
try {
    $release = Resolve-DelugeRelease -PinnedVersion $PinnedVersion
} catch {
    $resolveError = $_.Exception.Message
    Write-UcLog "WARN" "Could not resolve a Deluge release to install: $resolveError"
}

if ($WhatIf) {
    $dryTarget = if ($release) { $release.Version } else { $Version }
    $dryDetail = if ($release) {
        "stop services + install Deluge $dryTarget from the upstream mirror ($DelugeMirrorIndexUrl) + re-apply Web UI js fix + start services"
    } else {
        "cannot resolve a Deluge release to install: $resolveError"
    }
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $dryTarget; Detail = $dryDetail }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not $release) {
    # Never guess a version here: installing an unverified build (or Chocolatey's
    # 2.1.1, which has the broken /deluge base path) is worse than reporting the
    # update as failed and leaving the working install in place.
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = "no verified Deluge build available: $resolveError" }
}

try {
    # Stop both services first: the NSIS installer aborts while a Deluge process
    # is alive (its .onInit checks the "deluge" mutex) and it cannot replace
    # deluged.exe / deluge-web.exe while the daemon holds the images open, so a
    # silent partial upgrade would otherwise be recorded as successful.
    Stop-DelugeForInstall -ServiceNames $ServiceList
    Start-Sleep -Seconds 3

    # Install into the directory the running services already use.  A legacy
    # Chocolatey install can live outside the mirror's default location, and
    # installing elsewhere would leave the services running the old, 404-broken
    # build while the update is reported as a success.
    $updateTargetDir = $DelugeTargetDir
    $svcAppPath = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\DelugeDaemon\Parameters" -Name "Application" -ErrorAction SilentlyContinue).Application
    if ($svcAppPath) {
        $svcUnquoted = $svcAppPath.Trim('"')
        $svcAppDir   = Split-Path $svcUnquoted
        if ((Split-Path $svcUnquoted -Leaf) -ieq "deluged.exe" -and
            $svcAppDir -and (Test-Path $svcAppDir) -and
            ($svcAppDir -ine "C:\ProgramData\chocolatey\bin")) {
            $updateTargetDir = $svcAppDir
            Write-UcLog "INFO" "Deluge services run from $updateTargetDir; installing the update into the same directory"
        }
    }

    $installerPath = $null
    $detected      = $null
    try {
        # Everything that can fail after the services were stopped lives here, so
        # the finally below always brings Deluge back up.
        $installerPath = Save-DelugeInstaller -FileName $release.FileName -IndexUrl $DelugeMirrorIndexUrl -Destination $BinDir
        $detected      = Install-DelugeRelease -InstallerPath $installerPath -TargetDir $updateTargetDir -ExpectedVersion $release.Version
        Write-UcLog "INFO" "Deluge $detected installed into $updateTargetDir from $DelugeMirrorIndexUrl (requested $($release.Version) via $($release.Source))"

        # The upgrade replaces the whole payload, so re-apply the Web UI js fix
        # from 07_deluge.ps1: the upstream build ships only deluge-all-debug.js,
        # which leaves the Web UI in debug mode and unable to list torrents.
        $debugJs = $null
        $jsRoots = @()
        $jsRoots += (Join-Path $updateTargetDir "_internal")
        $jsRoots += (Join-Path $updateTargetDir "deluge")
        $jsRoots += (Join-Path $DelugeTargetDir "_internal")
        $jsRoots += (Join-Path $DelugeTargetDir "deluge")
        $jsRoots += (Get-ChildItem "C:\Program Files" -Directory -Filter "Deluge*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if (Test-Path "C:\ProgramData\chocolatey\lib\deluge") { $jsRoots += "C:\ProgramData\chocolatey\lib\deluge" }
        foreach ($root in $jsRoots) {
            if (-not $root -or -not (Test-Path $root)) { continue }
            $debugJs = Get-ChildItem $root -Filter "deluge-all-debug.js" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($debugJs) { break }
        }
        if ($debugJs) {
            $normalJs = Join-Path $debugJs.DirectoryName "deluge-all.js"
            if (-not (Test-Path $normalJs)) {
                Copy-Item $debugJs.FullName $normalJs -Force
                Write-Host "  -> Re-applied Web UI fix: $normalJs" -ForegroundColor Gray
                Write-UcLog "INFO" "Re-applied deluge-all.js from deluge-all-debug.js"
            } else {
                Write-UcLog "INFO" "deluge-all.js already present -- Web UI debug-mode fix not needed"
            }
        } else {
            Write-Warning "deluge-all-debug.js not found -- Web UI debug-mode fix not re-applied."
            Write-UcLog "WARN" "deluge-all-debug.js not found during Deluge update"
        }
    } finally {
        # Start the services again even when the upgrade threw, so a failed update
        # does not leave Deluge down.
        foreach ($svcName in $ServiceList) {
            $svcNow = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svcNow -and $svcNow.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
    }

    Start-Sleep -Seconds 15
    foreach ($svcName in $ServiceList) {
        $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "$svcName not Running after upgrade" }
    }

    # Report the version that is actually on disk (not the requested pin), so the
    # ledger and the legacy lock file describe the installed build.
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $detected
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $detected; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}