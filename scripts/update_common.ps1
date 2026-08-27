# update_common.ps1
# Shared helpers for the win-seedbox update system.
#
# Dot-source this file from installer scripts, update scripts, the updater
# orchestrator, and the update checker.  It is dependency-free: logging goes
# through Write-DebugLog when it is already loaded, otherwise it is silent.
#
# Core concepts:
#   - Ledger:   <InstallDir>\.locks\installed_versions.json is the single local
#               source of truth for installed versions (one entry per app).
#   - Manifest: versions.json (local or remote) is the single remote source of
#               truth for recommended versions.
#   - Plan:     Get-UpdatePlan compares the two and returns a per-app plan.
#
# NOTE: This file is 100% ASCII by project convention.  Never introduce
# non-ASCII characters (no em-dashes, box drawing, or symbols).

function Write-UcLog {
    # Internal log helper: routes to Write-DebugLog when available.
    param([string]$Level, [string]$Message)
    if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) {
        if ($Message -ne "") { Write-DebugLog $Level $Message }
        else { Write-DebugLog $Level }
    }
}

# -- Ledger helpers ------------------------------------------------------------

function Get-LedgerPath {
    param([Parameter(Mandatory = $true)][string]$InstallDir)
    return (Join-Path $InstallDir ".locks\installed_versions.json")
}

function Read-InstalledLedger {
    param([Parameter(Mandatory = $true)][string]$InstallDir)
    $path = Get-LedgerPath -InstallDir $InstallDir
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content -Raw -Path $path -ErrorAction Stop
        if (-not $raw) { return $null }
        $ledger = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $ledger -or -not $ledger.apps) { return $null }
        return $ledger
    } catch {
        Write-UcLog "WARN" "Read-InstalledLedger: cannot parse $path : $_"
        return $null
    }
}

function Write-InstalledLedger {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)]$Ledger
    )
    $locksDir = Join-Path $InstallDir ".locks"
    if (-not (Test-Path $locksDir)) { New-Item -Path $locksDir -ItemType Directory -Force | Out-Null }
    $path = Get-LedgerPath -InstallDir $InstallDir
    $json = $Ledger | ConvertTo-Json -Depth 6
    # No BOM: this file is parsed by ConvertFrom-Json.
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-UcLog "INFO" "Ledger written: $path"
}

function Set-InstalledVersion {
    # Records (or removes) the installed version of an app in the ledger.
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$AppName,
        [string]$Version,
        [switch]$Remove
    )
    $ledger = Read-InstalledLedger -InstallDir $InstallDir
    if (-not $ledger) {
        $ledger = [PSCustomObject]@{ schema = 1; updated = ""; apps = [PSCustomObject]@{} }
    }
    $existing = $ledger.apps.PSObject.Properties[$AppName]

    if ($Remove) {
        if ($existing) {
            $ledger.apps.PSObject.Properties.Remove($AppName)
            Write-UcLog "INFO" "Set-InstalledVersion: removed $AppName from ledger"
        }
    } else {
        if (-not $Version -or -not (Test-VersionLike -Value $Version)) {
            Write-UcLog "WARN" "Set-InstalledVersion: skipping non-version value for $AppName ('$Version')"
            return
        }
        $entry = [PSCustomObject]@{
            version   = $Version.Trim()
            updatedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        }
        if ($existing) {
            $existing.Value = $entry
        } else {
            $ledger.apps | Add-Member -MemberType NoteProperty -Name $AppName -Value $entry
        }
        Write-UcLog "INFO" "Set-InstalledVersion: $AppName -> $($Version.Trim())"
    }

    $ledger.updated = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    Write-InstalledLedger -InstallDir $InstallDir -Ledger $ledger
}

# -- Version comparison --------------------------------------------------------

function Test-VersionLike {
    # True when the string looks like a version (not a lock placeholder).
    param([string]$Value)
    if (-not $Value) { return $false }
    $v = $Value.Trim()
    if ($v -eq "") { return $false }
    if ($v -ieq "installed" -or $v -ieq "unknown" -or $v -ieq "latest") { return $false }
    if ($v -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}') { return $false }  # ISO timestamp lock
    return $true
}

function Compare-Versions {
    # Returns -1 when A < B, 1 when A > B, 0 when equal, 2 when not comparable.
    param([string]$A, [string]$B)
    $na = ($A -replace '^[vV]', '').Trim()
    $nb = ($B -replace '^[vV]', '').Trim()
    if ($na -eq $nb) { return 0 }
    if ($na -eq "" -or $nb -eq "") { return 2 }
    if ($na -in @("latest", "unknown") -or $nb -in @("latest", "unknown")) { return 2 }

    $sa = @([regex]::Matches($na, '\d+') | ForEach-Object { [long]$_.Value })
    $sb = @([regex]::Matches($nb, '\d+') | ForEach-Object { [long]$_.Value })
    if ($sa.Count -eq 0 -or $sb.Count -eq 0) { return 2 }

    $max = [Math]::Max($sa.Count, $sb.Count)
    $different = $false
    for ($i = 0; $i -lt $max; $i++) {
        $va = if ($i -lt $sa.Count) { $sa[$i] } else { 0 }
        $vb = if ($i -lt $sb.Count) { $sb[$i] } else { 0 }
        if ($va -lt $vb) { return -1 }
        if ($va -gt $vb) { return 1 }
    }
    # Numeric segments are equal; if the strings still differ (suffixes like
    # "-rc1" vs ""), fall back to ordinal comparison.
    if ($na -ne $nb) {
        $ord = [string]::CompareOrdinal($na, $nb)
        if ($ord -lt 0) { return -1 }
        if ($ord -gt 0) { return 1 }
    }
    return 0
}

# -- Installed version lookup --------------------------------------------------

function Get-InstalledVersion {
    # Ledger first, then the legacy lock file as fallback.
    # Returns: version string | "unknown" (present but unparseable) | $null (not installed)
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$AppName
    )
    $ledger = Read-InstalledLedger -InstallDir $InstallDir
    if ($ledger) {
        $entry = $ledger.apps.PSObject.Properties[$AppName]
        if ($entry -and $entry.Value -and $entry.Value.version) {
            return $entry.Value.version.Trim()
        }
    }
    $lockFile = Join-Path $InstallDir ".locks\.$($AppName.ToLower()).lock"
    if (Test-Path $lockFile) {
        $v = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v) {
            if (Test-VersionLike -Value $v) { return $v }
            return "unknown"
        }
        return "unknown"
    }
    return $null
}

function Detect-InstalledVersion {
    # Best-effort runtime detection for apps whose legacy lock files do not
    # store a version.  Returns a version string or $null.
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [object]$Entry,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )
    try {
        if ($Entry -and $Entry.source -eq "chocolatey" -and $Entry.package) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $out = choco list --exact $Entry.package -r 2>$null
            } finally {
                $ErrorActionPreference = $oldEap
            }
            if ($out) {
                $line  = ($out | Select-Object -First 1)
                $parts = $line -split '\|'
                if ($parts.Count -ge 2 -and $parts[1].Trim()) { return $parts[1].Trim() }
            }
            return $null
        }

        switch ($AppName) {
            "rclone" {
                $exe = Join-Path $InstallDir "rclone\rclone.exe"
                if (Test-Path $exe) {
                    $v = (& $exe version 2>$null | Select-Object -First 1)
                    if ($v -match 'rclone\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
            "Grafana" {
                $exe = Join-Path $InstallDir "Grafana\bin\grafana-server.exe"
                if (-not (Test-Path $exe)) { $exe = Join-Path $InstallDir "Grafana\bin\grafana.exe" }
                if (Test-Path $exe) {
                    $v = (& $exe --version 2>$null | Select-Object -First 1)
                    if ($v -match '([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
            "Jellyseerr" {
                $pkg = Join-Path $InstallDir "Jellyseerr\app\package.json"
                if (Test-Path $pkg) {
                    $json = Get-Content -Raw -Path $pkg | ConvertFrom-Json
                    if ($json.version) { return $json.version.Trim() }
                }
            }
            "Loki" {
                $exe = Join-Path $InstallDir "Loki\loki.exe"
                if (Test-Path $exe) {
                    $v = (& $exe --version 2>$null | Select-Object -First 1)
                    if ($v -match 'version\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
            "Alloy" {
                $exe = Join-Path $InstallDir "Alloy\alloy.exe"
                if (Test-Path $exe) {
                    $v = (& $exe --version 2>$null | Select-Object -First 1)
                    if ($v -match 'version\s+v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
            "Recyclarr" {
                # Recyclarr lives in the project dir, not in InstallDir.
                $exe = Join-Path $PSScriptRoot "..\recyclarr\recyclarr.exe"
                if (Test-Path $exe) {
                    $v = (& $exe --version 2>$null | Select-Object -First 1)
                    if ($v -match '([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
            "Zurg" {
                $exe = Join-Path $InstallDir "Zurg\zurg.exe"
                if (Test-Path $exe) {
                    $v = (& $exe --version 2>$null | Select-Object -First 1)
                    if ($v -match 'v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { return $Matches[1] }
                }
            }
        }
    } catch {
        Write-UcLog "WARN" "Detect-InstalledVersion for $AppName failed: $_"
    }
    return $null
}

# -- Update plan ---------------------------------------------------------------

function Get-RemoteManifest {
    # Fetches the remote versions.json and returns it as an object.
    # Falls back to the supplied local manifest on any failure.
    # NOTE: raw.githubusercontent serves text/plain, so PowerShell 5.1
    # Invoke-RestMethod returns the raw JSON string -- parse it explicitly.
    param(
        [Parameter(Mandatory = $true)]$LocalManifest,
        [string]$Url = ""
    )
    if (-not $Url -and $LocalManifest.PSObject.Properties["github_raw_url"]) {
        $Url = $LocalManifest.github_raw_url
    }
    if (-not $Url) { return $LocalManifest }
    try {
        $result = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        if ($result -is [string]) {
            # GitHub raw serves text/plain, so PS 5.1 returns the raw JSON
            # string.  Strip UTF-8 BOM characters (the remote file can carry
            # one or more) -- ConvertFrom-Json rejects strings starting with
            # U+FEFF, and a mis-decoded BOM shows up as U+00EF U+00BB U+00BF.
            $result = $result -replace '^\uFEFF+', ''
            $bom1252 = [string]([char]0x00EF) + [char]0x00BB + [char]0x00BF
            if ($result.StartsWith($bom1252)) { $result = $result.Substring(3) }
            $result = $result | ConvertFrom-Json
        }
        if (-not $result -or -not $result.PSObject.Properties["apps"]) { throw "invalid manifest" }
        return $result
    } catch {
        Write-UcLog "WARN" "Get-RemoteManifest: fetch failed for $Url : $_"
        return $LocalManifest
    }
}

function Get-UpdatePlan {
    # Compares the manifest (local or remote versions.json) against the local
    # ledger.  Returns one object per manifest app with a State of:
    #   current | update | manual | notinstalled | unknown | unresolved
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ScriptsDir
    )
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($prop in $Manifest.apps.PSObject.Properties) {
        $appName = $prop.Name
        $entry   = $prop.Value
        $target  = if ($entry.PSObject.Properties["version"]) { $entry.version } else { "" }

        $installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $appName

        $scriptPath = Join-Path $ScriptsDir "update_$($appName.ToLower()).ps1"
        $hasScript  = Test-Path $scriptPath

        $state = ""
        if (-not $target -or $target -ieq "latest" -or $target -ieq "unknown") {
            $state = "unresolved"
        } elseif ($null -eq $installed) {
            $state = "notinstalled"
        } elseif ($installed -ieq "unknown") {
            $state = "unknown"
        } else {
            $cmp = Compare-Versions -A $installed -B $target
            if ($cmp -eq 0) { $state = "current" }
            elseif ($cmp -eq 2) { $state = "unknown" }
            elseif ($hasScript) { $state = "update" }
            else { $state = "manual" }
        }

        $security = ($entry.PSObject.Properties["security"] -and $entry.security -eq $true)
        $securityNote = if ($entry.PSObject.Properties["securityNote"]) { $entry.securityNote } else { "" }

        $plan.Add([PSCustomObject]@{
            App          = $appName
            Installed    = $installed
            Target       = $target
            State        = $state
            Source       = if ($entry.PSObject.Properties["source"]) { $entry.source } else { "" }
            Repo         = if ($entry.PSObject.Properties["repo"]) { $entry.repo } else { "" }
            Asset        = if ($entry.PSObject.Properties["asset"]) { $entry.asset } else { "" }
            Package      = if ($entry.PSObject.Properties["package"]) { $entry.package } else { "" }
            Security     = $security
            SecurityNote = $securityNote
            HasScript    = $hasScript
            ScriptPath   = if ($hasScript) { $scriptPath } else { $null }
            Entry        = $entry
        })
    }
    return $plan
}

# -- Apply helpers -------------------------------------------------------------

function Invoke-GitHubReleaseDownload {
    # Downloads the release asset matching AssetPattern for a pinned tag.
    # Reuses the cached zip unless -Force is given.
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [switch]$Force
    )
    if (-not $Force -and (Test-Path $ZipPath)) {
        Write-UcLog "INFO" "Using cached zip: $ZipPath"
        return
    }
    $headers = @{ "User-Agent" = "win-seedbox-installer" }
    $apiUri  = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    Write-UcLog "INFO" "Fetching $apiUri"
    $release = Invoke-RestMethod -Uri $apiUri -Headers $headers -UseBasicParsing -ErrorAction Stop
    $asset = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$AssetPattern' in release $Tag of $Repo" }
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        # Never leave a partial file in the cache: a later run would treat it
        # as a valid cached zip.
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    Write-UcLog "INFO" "Downloaded $($asset.name) ($Tag) -> $ZipPath"
}

function Invoke-ChocoUpgrade {
    # Upgrades a Chocolatey package to an exact version and refreshes PATH.
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$Version
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        if ($Version) {
            Write-UcLog "INFO" "choco upgrade $Package --version $Version -y --no-progress"
            choco upgrade $Package --version $Version -y --no-progress | Out-Null
        } else {
            Write-UcLog "INFO" "choco upgrade $Package -y --no-progress"
            choco upgrade $Package -y --no-progress | Out-Null
        }
        $code = $global:LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($code -ne 0) { throw "choco upgrade $Package exited with code $code" }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Swap-AppDirectoryWithRollback {
    # Stops services, swaps the app binary directory with the contents of a zip,
    # restarts services, and health-checks them.  Rolls back on any failure.
    # Returns [PSCustomObject]@{ Ok = <bool>; Detail = <string> }.
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [string[]]$ServiceNames,
        [int]$HealthSeconds = 10
    )
    $appBinDir = Join-Path $InstallDir $AppName
    $appBinBak = "$appBinDir.bak"
    $result = [PSCustomObject]@{ Ok = $true; Detail = "" }
    $didBackup = $false

    try {
        foreach ($svcName in $ServiceNames) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Write-UcLog "INFO" "Stopping service $svcName"
                Stop-Service -Name $svcName -Force -ErrorAction Stop
            }
        }
        Start-Sleep -Seconds 2

        if (Test-Path $appBinBak) { Remove-Item $appBinBak -Recurse -Force }
        $hadExisting = Test-Path $appBinDir
        if ($hadExisting) {
            Rename-Item -Path $appBinDir -NewName "$AppName.bak" -Force -ErrorAction Stop
            $didBackup = $true
            Write-UcLog "INFO" "Backed up $appBinDir -> $appBinBak"
        }

        New-Item -Path $appBinDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $ZipPath -DestinationPath $appBinDir -Force -ErrorAction Stop

        # Flatten single-directory zips.
        $children = Get-ChildItem $appBinDir
        if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
            $inner = $children[0].FullName
            Get-ChildItem $inner | ForEach-Object { Move-Item $_.FullName $appBinDir -Force }
            Remove-Item $inner -Recurse -Force
        }

        foreach ($svcName in $ServiceNames) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds $HealthSeconds

        $healthy = $true
        foreach ($svcName in $ServiceNames) {
            $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svcAfter -or $svcAfter.Status -ne "Running") { $healthy = $false }
        }
        if (-not $healthy) { throw "health check failed: one or more services not Running" }

        if ($hadExisting -and (Test-Path $appBinBak)) { Remove-Item $appBinBak -Recurse -Force }
        $result.Detail = "binary swap complete"
        Write-UcLog "INFO" "$AppName binary swap complete"
        return $result
    } catch {
        $err = $_.Exception.Message
        Write-UcLog "WARN" "$AppName swap failed: $err. Rolling back."
        foreach ($svcName in $ServiceNames) {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
        # Only destroy the new content when the previous version was actually
        # backed up.  If the failure happened before the backup (e.g. the
        # service could not be stopped), the live directory must stay untouched.
        if ($didBackup) {
            if (Test-Path $appBinDir) { Remove-Item $appBinDir -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $appBinBak) {
                Rename-Item -Path $appBinBak -NewName $AppName -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($svcName in $ServiceNames) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
        $result.Ok = $false
        $result.Detail = $err
        return $result
    }
}

# -- Orchestration helpers -----------------------------------------------------

function Invoke-UpdateScriptForPlanItem {
    # Runs the per-app update script for a plan item and returns its result
    # object.  Update scripts must emit one result object:
    #   @{ App; Status = OK|ROLLBACK|FAILED|SKIPPED; Installed; Target; Detail }
    param(
        [Parameter(Mandatory = $true)]$PlanItem,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$BinDir,
        [object]$Config,
        [switch]$WhatIf
    )
    if (-not $PlanItem.ScriptPath -or -not (Test-Path $PlanItem.ScriptPath)) {
        return [PSCustomObject]@{
            App       = $PlanItem.App
            Status    = "SKIPPED"
            Installed = $PlanItem.Installed
            Target    = $PlanItem.Target
            Detail    = "no update script available"
        }
    }
    $argsList = @{
        Version    = $PlanItem.Target
        InstallDir = $InstallDir
        BinDir     = $BinDir
        Config     = $Config
        WhatIf     = [bool]$WhatIf
    }
    $out = & $PlanItem.ScriptPath @argsList
    if ($out) {
        return ($out | Select-Object -Last 1)
    }
    return [PSCustomObject]@{
        App       = $PlanItem.App
        Status    = "FAILED"
        Installed = $PlanItem.Installed
        Target    = $PlanItem.Target
        Detail    = "update script produced no result"
    }
}

function Write-SummaryTable {
    param(
        [object[]]$Results,
        [string]$Title = "Update Summary"
    )
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    foreach ($r in $Results) {
        $status = $r.Status
        $color  = switch -Wildcard ($status) {
            "OK"       { "Green" }
            "ROLLBACK" { "Red" }
            "FAILED*"  { "Red" }
            default    { "DarkYellow" }
        }
        $detail = if ($r.Detail) { "  ($($r.Detail))" } else { "" }
        Write-Host ("  {0,-15} {1}{2}" -f $r.App, $status, $detail) -ForegroundColor $color
    }
    Write-Host "=============================================" -ForegroundColor Cyan
}

# -- Per-app update script support ----------------------------------------------

function Initialize-UpdateScript {
    # Common bootstrapping for per-app update scripts.  Loads config.json and
    # versions.json when not supplied by the orchestrator, and wires up debug
    # logging.  Returns the config object.
    param([object]$Config)
    if (-not $Config) {
        $cfgPath = Join-Path $PSScriptRoot "..\config.json"
        if (Test-Path $cfgPath) { $Config = Get-Content -Raw -Path $cfgPath | ConvertFrom-Json }
    }
    if (-not (Get-Command Write-DebugLog -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "debug_logger.ps1")
    }
    if ($Config) {
        Initialize-DebugLog -Config $Config
        if (-not $Config.PSObject.Properties["_Versions"]) {
            $vPath = Join-Path $PSScriptRoot "..\versions.json"
            if (Test-Path $vPath) {
                $Config | Add-Member -MemberType NoteProperty -Name "_Versions" `
                    -Value (Get-Content -Raw -Path $vPath | ConvertFrom-Json) -Force
            }
        }
    }
    return $Config
}

function Swap-SingleExeWithRollback {
    # Replaces a single executable with a backup/rollback safety net.  Unlike
    # Swap-AppDirectoryWithRollback, surrounding files (configs, logs) are
    # preserved.  Optional PostHealthCheck scriptblock must return $true to
    # pass (invoked with & after the service health check).
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string]$NewExePath,
        [string[]]$ServiceNames,
        [int]$HealthSeconds = 10,
        [scriptblock]$PostHealthCheck
    )
    $bakPath = "$ExePath.bak"
    $result  = [PSCustomObject]@{ Ok = $true; Detail = "" }
    $didBackup = $false

    try {
        foreach ($svcName in $ServiceNames) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Write-UcLog "INFO" "Stopping service $svcName"
                Stop-Service -Name $svcName -Force -ErrorAction Stop
            }
        }
        Start-Sleep -Seconds 2

        if (Test-Path $bakPath) { Remove-Item $bakPath -Force }
        if (Test-Path $ExePath) {
            Copy-Item $ExePath $bakPath -Force -ErrorAction Stop
            $didBackup = $true
        }
        Copy-Item $NewExePath $ExePath -Force -ErrorAction Stop
        Write-UcLog "INFO" "Replaced $ExePath"

        foreach ($svcName in $ServiceNames) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds $HealthSeconds

        $healthy = $true
        foreach ($svcName in $ServiceNames) {
            $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svcAfter -or $svcAfter.Status -ne "Running") { $healthy = $false }
        }
        if ($healthy -and $PostHealthCheck) {
            try { $healthy = (& $PostHealthCheck) } catch { $healthy = $false }
        }
        if (-not $healthy) { throw "health check failed" }

        if (Test-Path $bakPath) { Remove-Item $bakPath -Force }
        $result.Detail = "exe swap complete"
        Write-UcLog "INFO" "$AppName exe swap complete"
        return $result
    } catch {
        $err = $_.Exception.Message
        Write-UcLog "WARN" "$AppName exe swap failed: $err. Rolling back."
        foreach ($svcName in $ServiceNames) {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
        # Only touch the live exe when a backup copy exists.
        if ($didBackup) {
            if (Test-Path $ExePath) { Remove-Item $ExePath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $bakPath) { Copy-Item $bakPath $ExePath -Force }
        }
        foreach ($svcName in $ServiceNames) {
            Start-Service -Name $svcName -ErrorAction SilentlyContinue
        }
        $result.Ok = $false
        $result.Detail = $err
        return $result
    }
}

