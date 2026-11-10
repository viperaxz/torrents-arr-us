param(
    [string]$ConfigPath = "",
    [int]$AgeHours = 6,
    [int]$GenericAgeHours = 72,
    [switch]$Quiet
)

# -- Temp housekeeping ----------------------------------------------------------
#
# FlareSolverr drives a bundled Chrome through undetected-chromedriver, which gives
# every launch a fresh profile created with Python's tempfile.mkdtemp() under the
# SERVICE ACCOUNT's temp directory and never deletes it.  Prowlarr's FlareSolverr
# integration is stateless (no `session` parameter), so the solver launches a
# browser per request: measured 720 orphaned profiles at ~189 MB each = 66.8 GB
# after three weeks, which filled C: to 0.5 GB free.
#
# That is not merely untidy.  Jellyfin 12.3 refuses to start when the volume
# holding its data directory has less than 2 GiB free:
#
#   [FTL] Main: Unhandled Exception
#   System.InvalidOperationException: The path `C:\ProgramData\Jellyfin\Server\data`
#   has insufficient free space. Available: 1.8GiB, Required: 2GiB.
#
# so the server was down until the temp litter was cleared.  This script is the
# recurring countermeasure: it prunes the disposable directories (aggressively, at
# $AgeHours) and stale leftover files (at $GenericAgeHours), skips anything locked
# by a live process, and never follows a reparse point.

function Write-CleanLog {
    param([string]$Level, [string]$Message)
    if (-not $script:LogFile) { return }
    try {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-CleanHost {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# Delete one entry.  A directory symlink or junction is removed as a LINK: a plain
# Remove-Item -Recurse on a reparse point has historically followed it and deleted
# the target's contents instead of the link.
function Remove-TempEntry {
    param([System.IO.FileSystemInfo]$Item)

    $isReparse = [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    if ($isReparse) {
        if ($Item.PSIsContainer) { [System.IO.Directory]::Delete($Item.FullName, $false) }
        else { [System.IO.File]::Delete($Item.FullName) }
        return
    }
    Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
}

function Get-DirSizeBytes {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if ($sum) { return $sum }
    return 0
}

# -- 1. Locate config.json (optional: the script works standalone) --------------
if (-not $ConfigPath) {
    foreach ($candidate in @(
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json')
        (Join-Path $PSScriptRoot 'config.json')
        'D:\MediaServer\config.json')) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $ConfigPath = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
}

$Config     = $null
$InstallDir = 'D:\MediaServer'
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    try {
        $Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        if ($Config.General -and $Config.General.InstallDir) { $InstallDir = $Config.General.InstallDir }
    } catch {
        Write-CleanHost "  [warn] Could not parse ${ConfigPath}: $($_.Exception.Message)" 'Yellow'
    }
}

$LogDir = Join-Path $InstallDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$script:LogFile = Join-Path $LogDir 'temp_cleanup.log'
if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
    Move-Item -LiteralPath $script:LogFile -Destination "$script:LogFile.1" -Force -ErrorAction SilentlyContinue
}

# -- 2. Resolve the service account's profile ----------------------------------
# Same account name 00_service_account.ps1 creates.  The profile folder can carry a
# suffix ("seedbox-svc.DESKTOP-XXXX") once Windows has appended the computer name,
# so resolve it through Win32_UserProfile instead of string concatenation.
$SvcUser = 'seedbox-svc'
if ($Config -and $Config.General -and $Config.General.PSObject.Properties['ServiceAccountUser'] -and $Config.General.ServiceAccountUser) {
    $SvcUser = [string]$Config.General.ServiceAccountUser
}

$profilePath = $null
try {
    $account = New-Object System.Security.Principal.NTAccount($SvcUser)
    $sid     = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    $up      = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
    if ($up -and $up.LocalPath) { $profilePath = $up.LocalPath }
} catch { }
if (-not $profilePath) {
    $match = Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq $SvcUser -or $_.Name -like "$SvcUser.*" } |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($match) { $profilePath = $match.FullName }
}

$targets = @()
if ($profilePath -and (Test-Path -LiteralPath (Join-Path $profilePath 'AppData\Local\Temp'))) {
    $targets += (Join-Path $profilePath 'AppData\Local\Temp')
}
if (Test-Path -LiteralPath 'C:\Windows\Temp') { $targets += 'C:\Windows\Temp' }

Write-CleanLog "INFO" "Cleanup start: user=$SvcUser profile=$profilePath targets=$($targets -join ';') ages=${AgeHours}h/${GenericAgeHours}h"

if ($targets.Count -eq 0) {
    Write-CleanLog "WARN" "No temp directory found for '$SvcUser' -- nothing to do"
    Write-CleanHost "  [skip] No temp directory found for '$SvcUser'." 'DarkGray'
    exit 0
}

# -- 3. Prune ------------------------------------------------------------------
# Names created per launch by Chrome/FlareSolverr, plus Jellyfin's transcode
# scratch.  These carry no state worth keeping, so they age out quickly.
$pattern = '^(tmp[a-z0-9_]{8}|chromium_chrome_Unpacker_|scoped_dir|Crashpad|chrome_|jellyfin|pip-|pu-|.com.google.Chrome)'

$now        = Get-Date
$fastCutoff = $now.AddHours(-$AgeHours)
$ageCutoff  = $now.AddHours(-$GenericAgeHours)
$fastCount = 0; $fastBytes = 0
$slowCount = 0; $slowBytes = 0
$locked    = 0

foreach ($root in $targets) {
    $entries = Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
        $isFast = $entry.Name -match $pattern
        $cutoff = if ($isFast) { $fastCutoff } else { $ageCutoff }
        if ($entry.LastWriteTime -ge $cutoff) { continue }

        $size = if ($entry.PSIsContainer) { Get-DirSizeBytes -Path $entry.FullName } else { $entry.Length }
        try {
            Remove-TempEntry -Item $entry
            if ($isFast) { $fastCount++; $fastBytes += $size }
            else         { $slowCount++; $slowBytes += $size }
        } catch {
            $locked++
        }
    }
}

$freedGb = [math]::Round(($fastBytes + $slowBytes) / 1GB, 2)
Write-CleanLog "INFO" ("Cleanup done: browser=$fastCount (${AgeHours}h), stale=$slowCount (${GenericAgeHours}h), locked=$locked, freed=${freedGb}GB")

# -- 4. Report free space ------------------------------------------------------
$report = @()
foreach ($root in $targets) {
    $drive = (Get-Item -LiteralPath $root).PSDrive
    if ($drive -and $drive.Free -ne $null) {
        $report += [PSCustomObject]@{
            Target  = $root
            FreeGB  = [math]::Round($drive.Free / 1GB, 2)
            TotalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 1)
        }
    }
}

$lowest = ($report | Sort-Object FreeGB | Select-Object -First 1)
if ($lowest -and $lowest.FreeGB -lt 5) {
    Write-CleanLog "WARN" "Low free space after cleanup: $($lowest.FreeGB) GB on $($lowest.Target)"
    Write-CleanHost "  [warn] Only $($lowest.FreeGB) GB free after cleanup." 'Yellow'
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host ("  Temp cleanup: {0} browser profile(s) + {1} stale entr(ies) removed, {2} locked, {3} GB freed." -f $fastCount, $slowCount, $locked, $freedGb) -ForegroundColor Cyan
    $report | Format-Table -AutoSize | Out-String | Write-Host
}

exit 0
