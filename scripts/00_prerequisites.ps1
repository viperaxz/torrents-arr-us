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
$chocoExists = Get-Command choco -ErrorAction SilentlyContinue
Write-DebugLog "VAR choco in PATH: $($null -ne $chocoExists)"
if (-not $chocoExists) {
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
    $chocoVersion = choco -v
    Write-Host "[Prerequisites] Chocolatey is already installed (Version: $chocoVersion)." -ForegroundColor Green
    Write-DebugLog "VAR Chocolatey version found: $chocoVersion"

    $meetsMin = Test-MinimumVersion -CurrentVersion $chocoVersion -RequiredVersion $MinChocoVersion
    Write-DebugLog "VAR choco meetsMin=$meetsMin for minVersion=$MinChocoVersion"
    if (-not $meetsMin) {
        Write-Host "[Prerequisites] Chocolatey version is behind minimum required ($MinChocoVersion). Upgrading..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Upgrading Chocolatey from $chocoVersion to >= $MinChocoVersion"
        choco upgrade chocolatey -y --no-progress | Out-Null
        $newVersion = choco -v
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

    # Check if package is installed
    $listOutput = choco list --exact $PackageName -r 2>$null
    Write-DebugLog "VAR choco list $PackageName output: $listOutput"
    if ([string]::IsNullOrWhiteSpace($listOutput)) {
        $isInstalled = $false
        $installedVersion = $null
    } else {
        $isInstalled = $true
        $parts = $listOutput -split '\|'
        $installedVersion = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $null }
    }

    Write-DebugLog "VAR $PackageName installed=$isInstalled version=$installedVersion"

    if (-not $isInstalled) {
        Write-Host "  -> Installing $PackageName..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Installing $PackageName via choco..."
        # EAP is "Stop" here (inherited from master_install.ps1) and choco writes
        # warnings (pending reboot, deprecation notices) to stderr on otherwise
        # successful installs -- which would abort this FATAL script. The explicit
        # verification below is what actually decides success.
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            choco install $PackageName -y --no-progress 2>&1 | Out-Null
        } finally {
            $ErrorActionPreference = $savedEAP
        }

        # Verify installation
        $verifyOutput = choco list --exact $PackageName -r 2>$null
        Write-DebugLog "VAR choco verify [$PackageName] output=$verifyOutput"
        if ([string]::IsNullOrWhiteSpace($verifyOutput)) {
            Write-Warning "  -> Failed to install $PackageName. Continuing..."
            Write-DebugLog "ERROR" "$PackageName install FAILED (not found after install)"
        } else {
            $installedVer = ($verifyOutput -split '\|')[1].Trim()
            Write-Host "  -> $PackageName installed successfully." -ForegroundColor Green
            Write-DebugLog "INFO" "$PackageName installed successfully. Version: $installedVer"
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($MinimumVersion)) {
            $meetsMin = Test-MinimumVersion -CurrentVersion $installedVersion -RequiredVersion $MinimumVersion
            Write-DebugLog "VAR $PackageName installed=$installedVersion meetsMin=$meetsMin (required >= $MinimumVersion)"
            if ($installedVersion -and -not $meetsMin) {
                Write-Host "  -> Upgrading $PackageName from $installedVersion to at least $MinimumVersion..." -ForegroundColor Yellow
                Write-DebugLog "INFO" "Upgrading $PackageName from $installedVersion..."
                $savedEAP = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    choco upgrade $PackageName -y --no-progress 2>&1 | Out-Null
                } finally {
                    $ErrorActionPreference = $savedEAP
                }
                $newVer = (choco list --exact $PackageName -r 2>$null -split '\|')[1]
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
$Packages = @(
    @{ Name = "nssm"; MinVersion = "2.24" },
    @{ Name = "vcredist140"; MinVersion = "" }
)

Write-Host "[Prerequisites] Checking base packages..." -ForegroundColor Cyan
Write-DebugLog "INFO" "Checking $($Packages.Count) base packages..."
foreach ($pkg in $Packages) {
    Write-DebugLog "INFO" "--- Checking package: $($pkg.Name) (min: $($pkg.MinVersion)) ---"
    Install-ChocoPackage -PackageName $pkg.Name -MinimumVersion $pkg.MinVersion
}

# Refresh Environment Variables again after installing packages
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
Write-DebugLog "INFO" "PATH refreshed after package installs"

Write-Host "[Prerequisites] Prerequisites installation completed." -ForegroundColor Cyan
Write-DebugLog "INFO" "00_prerequisites.ps1 complete"
