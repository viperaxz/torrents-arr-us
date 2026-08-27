#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found. Copy config.json.example and configure it first."
    exit 1
}

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$LockFile = Join-Path $Config.General.InstallDir ".locks\.grafana.lock"
if (Test-Path $LockFile) {
    Write-Host "Grafana is already installed." -ForegroundColor Green
    Write-Host "To reinstall, delete $LockFile and re-run this script." -ForegroundColor Yellow
    exit 0
}

# Update config.json on disk: Apps.Grafana = true
$raw = Get-Content $ConfigPath -Raw -Encoding UTF8
if ($raw -match '"Grafana"\s*:\s*(true|false)') {
    $raw = [regex]::Replace($raw, '"Grafana"\s*:\s*(true|false)', '"Grafana": true')
    # BOM-free: config.json is only read by PowerShell (ConvertFrom-Json handles BOM),
    # but consistent with project-wide convention of never emitting EF BB BF.
    [System.IO.File]::WriteAllText($ConfigPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "config.json: Apps.Grafana = true" -ForegroundColor Cyan
} else {
    Write-Warning "Apps.Grafana key not found in config.json. Add it manually if needed."
}

# Force Apps.Grafana = true in the in-memory object (overrides whatever was in the file)
$Config.Apps | Add-Member -MemberType NoteProperty -Name "Grafana" -Value $true -Force

# Load versions manifest
$VersionsPath = Join-Path $PSScriptRoot "versions.json"
if (Test-Path $VersionsPath) {
    $Versions = Get-Content $VersionsPath -Raw | ConvertFrom-Json
    $Config | Add-Member -MemberType NoteProperty -Name "_Versions" -Value $Versions -Force
}

Write-Host ""
Write-Host "Installing Grafana + Loki + Alloy..." -ForegroundColor Cyan
Write-Host ""

& (Join-Path $PSScriptRoot "scripts\14_grafana.ps1") -Config $Config
exit 0
