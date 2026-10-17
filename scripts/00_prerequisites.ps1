param (
    [Parameter(Mandatory=$false)]
    [object]$Config,

    [Parameter(Mandatory=$false)]
    [string]$MinChocoVersion = "2.0.0"
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
if ($Config) {
    Initialize-DebugLog -Config $Config
}
# Shared choco plumbing: PATH-safe resolution plus retry-on-transient-feed-failure
# with the output captured instead of discarded.
. (Join-Path $PSScriptRoot "choco_helpers.ps1")
Write-DebugLog "INFO" "00_prerequisites.ps1 started. MinChocoVersion=$MinChocoVersion"

Write-Host "[Prerequisites] Starting prerequisites installation..." -ForegroundColor Cyan

# Helper function to check and compare versions
function Test-MinimumVersion {
    param (
        [string]$CurrentVersion,
        [string]$RequiredVersion
    )
    Write-DebugLog "VAR Test-MinimumVersion: current=$CurrentVersion required=$RequiredVersion"
    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) { return $false }

    # Cast to [version] to properly compare
    try {
        $vCurrent = [version]$CurrentVersion
        $vRequired = [version]$RequiredVersion
        $result = $vCurrent -ge $vRequired
        Write-DebugLog "VAR version comparison: $CurrentVersion >= $RequiredVersion = $result"
        return $result
    } catch {
        # Fallback if versions are not strictly formatted (e.g. 2.1.0-beta)
        Write-Warning "Could not parse versions for comparison: $CurrentVersion vs $RequiredVersion"
        Write-DebugLog "WARN" "Version parse failed: $CurrentVersion vs $RequiredVersion : $_"
        return $false
    }
}

# 1. Install or Upgrade Chocolatey
# Resolve-ChocoExe does not trust $env:Path: a shell opened before Chocolatey was
# installed never sees chocolatey\bin even though the Machine PATH names it, so
# Get-Command alone would re-run the bootstrapper on a healthy machine (and is
# another way for the step to fail).
$chocoExe = Resolve-ChocoExe
Write-DebugLog "VAR choco resolved to: $(if ($chocoExe) { $chocoExe } else { '(not found)' })"
if (-not $chocoExe) {
    Write-Host "[Prerequisites] Installing Chocolatey package manager..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Chocolatey not found. Downloading installer..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Write-DebugLog "INFO" "Chocolatey installer executed"

    # Reload environment variables
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-DebugLog "INFO" "PATH refreshed after Chocolatey install"
} else {
    $chocoVersion = ((& $chocoExe -v) -join ' ').Trim()
    Write-Host "[Prerequisites] Chocolatey is already installed (Version: $chocoVersion)." -ForegroundColor Green
    Write-DebugLog "VAR Chocolatey version found: $chocoVersion"

    $meetsMin = Test-MinimumVersion -CurrentVersion $chocoVersion -RequiredVersion $MinChocoVersion
    Write-DebugLog "VAR choco meetsMin=$meetsMin for minVersion=$MinChocoVersion"
    if (-not $meetsMin) {
        Write-Host "[Prerequisites] Chocolatey version is behind minimum required ($MinChocoVersion). Upgrading..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Upgrading Chocolatey from $chocoVersion to >= $MinChocoVersion"
        $chocoUpgrade = Invoke-Choco -Arguments @('upgrade', 'chocolatey', '-y', '--no-progress')
        $chocoUpgradeTail = $chocoUpgrade.Output
        if ($chocoUpgradeTail -and $chocoUpgradeTail.Length -gt 800) { $chocoUpgradeTail = $chocoUpgradeTail.Substring($chocoUpgradeTail.Length - 800) }
        if (-not $chocoUpgrade.Ran) {
            Write-DebugLog "ERROR" "choco upgrade chocolatey: choco.exe could not be located"
        } elseif ($chocoUpgrade.ExitCode -ne 0 -or $chocoUpgrade.Transient) {
            Write-DebugLog "WARN" "choco upgrade chocolatey non-zero exit (exit $($chocoUpgrade.ExitCode), transient=$($chocoUpgrade.Transient), attempts=$($chocoUpgrade.Attempts)): $chocoUpgradeTail"
        }
        $newVersion = ((& $chocoExe -v) -join ' ').Trim()
        Write-DebugLog "INFO" "Chocolatey upgraded. New version: $newVersion"
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } else {
        Write-Host "[Prerequisites] Chocolatey version meets minimum requirement ($MinChocoVersion)." -ForegroundColor Green
        Write-DebugLog "INFO" "Chocolatey version OK: $chocoVersion"
    }
}

# 2. Function to handle package installation with version checks
function Install-ChocoPackage {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PackageName,

        [Parameter(Mandatory=$false)]
        [string]$MinimumVersion
    )

    Write-DebugLog "INFO" "Install-ChocoPackage: $PackageName (minVersion=$MinimumVersion)"

    # Check if package is installed. Local-only lookup: the remote feed query is
    # the part that breaks, and "is it on this machine" never needs it.
    $installedVersion = Get-ChocoInstalledVersion -Package $PackageName
    $isInstalled = -not [string]::IsNullOrWhiteSpace($installedVersion)
    Write-DebugLog "VAR choco list $PackageName output: $installedVersion"

    Write-DebugLog "VAR $PackageName installed=$isInstalled version=$installedVersion"

    if (-not $isInstalled) {
        Write-Host "  -> Installing $PackageName..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Installing $PackageName via choco..."
        # choco's exit code is not authoritative: when the feed is unreachable it
        # prints "Chocolatey installed 0/0 packages." and still returns 0, and it
        # also returns non-zero for harmless warnings (pending reboot). The
        # explicit verification below is what actually decides success, so the
        # output is logged rather than discarded -- that discarded output is why
        # a 503 from community.chocolatey.org took forensic work to diagnose.
        $install     = Invoke-Choco -Arguments @('install', $PackageName, '-y', '--no-progress')
        $installTail = $install.Output
        if ($installTail -and $installTail.Length -gt 800) { $installTail = $installTail.Substring($installTail.Length - 800) }
        if (-not $install.Ran) {
            Write-Warning "  -> choco.exe could not be located -- cannot install $PackageName."
            Write-DebugLog "ERROR" "choco install ${PackageName}: choco.exe not found"
        } elseif ($install.ExitCode -ne 0 -or $install.Transient) {
            Write-Warning "  -> choco install $PackageName exited with code $($install.ExitCode); verifying anyway..."
            Write-DebugLog "WARN" "choco install $PackageName non-zero exit (exit $($install.ExitCode), transient=$($install.Transient), attempts=$($install.Attempts)): $installTail"
        }

        # Verify installation
        $verifyVersion = Get-ChocoInstalledVersion -Package $PackageName
        Write-DebugLog "VAR choco verify [$PackageName] output=$verifyVersion"
        if ([string]::IsNullOrWhiteSpace($verifyVersion)) {
            Write-Warning "  -> Failed to install $PackageName. Continuing..."
            Write-DebugLog "ERROR" "$PackageName install FAILED (not found after install): $installTail"
        } else {
            Write-Host "  -> $PackageName installed successfully." -ForegroundColor Green
            Write-DebugLog "INFO" "$PackageName installed successfully. Version: $verifyVersion"
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) {
            $meetsMin = Test-MinimumVersion -CurrentVersion $installedVersion -RequiredVersion $MinimumVersion
            Write-DebugLog "VAR $PackageName installed=$installedVersion meetsMin=$meetsMin (required >= $MinimumVersion)"
            if ($installedVersion -and -not $meetsMin) {
                Write-Host "  -> Upgrading $PackageName from $installedVersion to at least $MinimumVersion..." -ForegroundColor Yellow
                Write-DebugLog "INFO" "Upgrading $PackageName from $installedVersion..."
                $upgrade     = Invoke-Choco -Arguments @('upgrade', $PackageName, '-y', '--no-progress')
                $upgradeTail = $upgrade.Output
                if ($upgradeTail -and $upgradeTail.Length -gt 800) { $upgradeTail = $upgradeTail.Substring($upgradeTail.Length - 800) }
                if (-not $upgrade.Ran) {
                    Write-DebugLog "ERROR" "choco upgrade ${PackageName}: choco.exe not found"
                } elseif ($upgrade.ExitCode -ne 0 -or $upgrade.Transient) {
                    Write-DebugLog "WARN" "choco upgrade $PackageName non-zero exit (exit $($upgrade.ExitCode), transient=$($upgrade.Transient), attempts=$($upgrade.Attempts)): $upgradeTail"
                }
                $newVer = Get-ChocoInstalledVersion -Package $PackageName
                Write-DebugLog "INFO" "$PackageName upgraded. New version: $newVer"
            } elseif ($installedVersion) {
                Write-Host "  -> $PackageName is installed ($installedVersion) and meets minimum version ($MinimumVersion). Skipping." -ForegroundColor Green
                Write-DebugLog "INFO" "$PackageName OK: $installedVersion >= $MinimumVersion"
            }
        } else {
            Write-Host "  -> $PackageName is already installed ($installedVersion). Skipping upgrade." -ForegroundColor Green
            Write-DebugLog "INFO" "$PackageName already installed: $installedVersion (no min version required)"
        }
    }
}

# Define required packages, optionally with minimum versions
# Format: @{ "PackageName" = "MinVersion" } or just name if no min version
# NSSM is pinned by versions.json so a bump of the manifest pin actually reaches
# an existing install (an already-present package is never upgraded otherwise).
$NssmMinVersion = "2.24"
if ($Config -and $Config.PSObject.Properties['_Versions'] -and $Config._Versions.apps) {
    $nssmEntry = $Config._Versions.apps.PSObject.Properties['NSSM']
    if ($nssmEntry -and $nssmEntry.Value.PSObject.Properties['version'] -and $nssmEntry.Value.version) {
        $pinned = [string]$nssmEntry.Value.version
        if (Test-MinimumVersion -CurrentVersion $pinned -RequiredVersion $NssmMinVersion) {
            $NssmMinVersion = $pinned
            Write-DebugLog "INFO" "NSSM minimum version raised to the versions.json pin: $NssmMinVersion"
        }
    }
}
$Packages = @(
    @{ Name = "nssm"; MinVersion = $NssmMinVersion },
    @{ Name = "vcredist140"; MinVersion = "" }
)

Write-Host "[Prerequisites] Checking base packages..." -ForegroundColor Cyan
Write-DebugLog "INFO" "Checking $($Packages.Count) base packages..."
foreach ($pkg in $Packages) {
    Write-DebugLog "INFO" "--- Checking package: $($pkg.Name) (min: $($pkg.MinVersion)) ---"
    Install-ChocoPackage -PackageName $pkg.Name -MinimumVersion $pkg.MinVersion
}

# NSSM is fatal, not merely required: every application installer creates its
# service through it, so continuing without it produces fourteen unrelated
# failures instead of one clear one. master_install.ps1 declares this phase
# fatal and runs with $ErrorActionPreference = 'Stop', so this terminates the run;
# the exit code covers a standalone invocation.
if ([string]::IsNullOrWhiteSpace((Get-ChocoInstalledVersion -Package "nssm"))) {
    # Log first: Write-Error is terminating under master_install's EAP='Stop', so
    # anything after it (including this log line) would never run.
    Write-DebugLog "ERROR" "NSSM missing after the prerequisite install phase -- aborting"
    Write-Error "[Prerequisites] NSSM is not installed and could not be installed (choco could not install or verify it). Every service-based app would fail. Aborting."
    exit 1
}

# Refresh Environment Variables again after installing packages
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
Write-DebugLog "INFO" "PATH refreshed after package installs"

Write-Host "[Prerequisites] Prerequisites installation completed." -ForegroundColor Cyan
Write-DebugLog "INFO" "00_prerequisites.ps1 complete"
