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
    # A single quote inside a single-quoted YAML scalar must be doubled,
    # otherwise the value terminates the scalar early and breaks the whole file.
    $quotedValue = if (Test-YamlNeedsQuoting $Value) { "'" + ($Value -replace "'", "''") + "'" } else { $Value }
    # -Encoding UTF8: PowerShell 5.1's default (ANSI) decoder mangles every
    # non-ASCII character, and the mangled text would be written back as UTF-8.
    $lines     = Get-Content -Path $Path -Encoding UTF8
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
    if (-not $found) {
        Write-Warning "  -> Section '$Section' not found in $(Split-Path $Path -Leaf); '$Key' was NOT written."
        Write-DebugLog "ERROR" "Set-YamlKey: section '$Section' not found in $Path -- '$Key' not written"
    }
    return $found
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

    # The interpreter must be readable by the account the Bazarr service runs as
    # ($SvcUser), not merely by the operator running this installer. A Python
    # installed per-user -- python.org's default when not elevated, winget, or
    # the Microsoft Store alias -- lives under C:\Users\<name>\ and grants no
    # access to any other account. NSSM then fails the service instantly with a
    # 0-byte stderr log and Win32 exit code 1066, which is extremely hard to
    # diagnose from the installer output. Reject these so Step 4 installs the
    # machine-wide python312 package (C:\Python312) instead.
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if ($Path -like "$usersRoot\*" -or $Path -like '*\WindowsApps\*') {
        Write-DebugLog "WARN" "Python candidate rejected -- not readable by service account '$SvcUser': $Path"
        return $null
    }

    try {
        $verOut = & $Path --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($verOut -match 'Python (\d+)\.(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            $patch = [int]$Matches[3]
            if ($major -eq 3 -and $minor -ge 9) {
                # Bazarr installs its dependencies with pip, so an interpreter
                # without a working pip is not usable even though "python
                # --version" succeeds. A half-finished python.org install leaves
                # exactly that behind: on this machine `choco install python312`
                # exited 1603 and left C:\Python312\python.exe with no standard
                # library and no pip at all, so accepting it bound the service to
                # an interpreter that could never run. Verify pip really works.
                $pipOk = $false
                $savedEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $null = & $Path -m pip --version 2>&1
                    $pipOk = ($LASTEXITCODE -eq 0)
                } catch {
                    $pipOk = $false
                } finally {
                    $ErrorActionPreference = $savedEap
                }
                if (-not $pipOk) {
                    Write-DebugLog "WARN" "Python candidate rejected -- no working pip (incomplete install?): $Path"
                    return $null
                }
                return [PSCustomObject]@{ Path=$Path; Major=$major; Minor=$minor; Patch=$patch; VersionStr="$major.$minor.$patch" }
            }
        }
    } catch {}
    return $null
}

# Enumerate Python interpreters that already EXIST on this machine, so Step 4 can
# refuse to install over them. Deliberately includes interpreters
# Test-PythonCandidate rejects: an existing-but-unusable Python is precisely the
# case where running an install would destroy something.
function Find-ExistingPython {
    $found = New-Object System.Collections.Generic.List[string]

    # Per-user installs -- python.org's default when not elevated, winget, etc.
    # These live under a user profile and are what `choco install python312`
    # removes.
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pyRoot = Join-Path $_.FullName 'AppData\Local\Programs\Python'
        if (Test-Path $pyRoot) {
            Get-ChildItem $pyRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path $exe) { $found.Add($exe) }
            }
        }
    }

    # Machine-wide installs other than our own Chocolatey target C:\Python312,
    # which is ours to repair or replace.
    Get-ChildItem (Join-Path $env:SystemDrive 'Python3*') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -ne 'Python312') {
            $exe = Join-Path $_.FullName 'python.exe'
            if (Test-Path $exe) { $found.Add($exe) }
        }
    }

    # Whatever `python` resolves to. The Microsoft Store alias is an App
    # Execution Alias, not an interpreter, so it must not count as "a Python
    # exists" -- otherwise it would block every install on a clean machine.
    $gc = Get-Command python -ErrorAction SilentlyContinue
    if ($gc -and $gc.Source -notlike '*\WindowsApps\*' -and $gc.Source -notlike '*\Python312\*') {
        $found.Add($gc.Source)
    }

    return ($found | Select-Object -Unique)
}

# 3.12 is the pinned version: pre-built wheels exist for every Bazarr dependency
# on cp312. A newer 3.x elsewhere on the machine must not win merely for being
# newer -- it is only a fallback when no 3.12 is installed.
function Test-PythonPreferred {
    param($Candidate, $Current)
    if (-not $Current) { return $true }
    $candPinned = ($Candidate.Minor -eq 12)
    $currPinned = ($Current.Minor -eq 12)
    if ($candPinned -ne $currPinned) { return $candPinned }
    if ($Candidate.Minor -ne $Current.Minor) { return ($Candidate.Minor -gt $Current.Minor) }
    return ($Candidate.Patch -gt $Current.Patch)
}

# Step 1: Check C:\Python312 (Chocolatey default)
$candidate = Test-PythonCandidate "C:\Python312\python.exe"
if ($candidate) { $PythonExe = $candidate.Path; Write-DebugLog "INFO" "Found Python $($candidate.VersionStr) at $PythonExe (Chocolatey default)" }

# Step 2: Scan C:\Python3* directories (user-installed, winget, etc.)
# Compare parsed versions (minor/patch) rather than directory names: a plain
# descending name sort puts "Python39" ahead of "Python310"/"Python312" and
# would silently select an older interpreter. 3.12 outranks any other version.
if (-not $PythonExe) {
    $bestCandidate = $null
    Get-ChildItem "C:\Python3*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Test-PythonCandidate (Join-Path $_.FullName "python.exe")
        if ($candidate) {
            if (Test-PythonPreferred $candidate $bestCandidate) {
                $bestCandidate = $candidate
            }
        }
    }
    if ($bestCandidate) {
        $PythonExe = $bestCandidate.Path
        Write-DebugLog "INFO" "Found Python $($bestCandidate.VersionStr) at $PythonExe (C:\Python3* scan, 3.12 preferred)"
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
    # Nothing USABLE was found -- but a Python may still be PRESENT, typically a
    # per-user install the service account cannot read. Never install over it:
    # `choco install python312` performs an InstallAllUsers=1 install, and where a
    # per-user Python 3.12 already exists the python.org bundle REMOVES it and can
    # leave orphaned per-user MSI state that makes every later attempt fail with
    # 1603 ("Error 0x80070643: Failed to uninstall MSI package"). On a real
    # machine that destroyed a working interpreter. Install only when there is
    # genuinely nothing to destroy.
    $existingPython = @(Find-ExistingPython)
    if ($existingPython.Count -gt 0) {
        Write-Host ""
        Write-Warning "[$AppName] A Python installation already exists but cannot be used for the service:"
        $existingPython | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        Write-Warning "  NOT installing python312 -- that package installs for all users and would REMOVE the above."
        Write-Warning "  Resolve either way, then re-run .\master_install.ps1:"
        Write-Host "    (a) reinstall Python 3.12 'for all users' so the '$SvcUser' account can read it, or" -ForegroundColor Gray
        Write-Host "    (b) uninstall that Python yourself -- this script will then install the machine-wide copy." -ForegroundColor Gray
        Write-DebugLog "ERROR" "Refusing to install python312: existing Python found at $($existingPython -join '; '). An InstallAllUsers=1 install would remove it."
        exit 1
    }

    # A Python can also be PRESENT but invisible to Find-ExistingPython: a per-user
    # install whose MSI registration survived while its files were removed, or a
    # half-uninstalled entry. `choco install python312` then fails with 1603 and the
    # choco output does not explain why, so name the products up front.
    $pyProducts = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $pyProducts += @(Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match '^Python 3\.') { $p.DisplayName }
        })
    }
    $pyProducts = @($pyProducts | Select-Object -Unique)
    if ($pyProducts.Count -gt 0) {
        Write-Warning "[$AppName] A Python 3 product is registered but no usable interpreter was found:"
        $pyProducts | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        Write-Warning "  If the install below fails with 1603 / 0x80070643, remove that Python and re-run."
        Write-DebugLog "WARN" "Registered Python products without a usable interpreter: $($pyProducts -join '; ')"
    }

    Write-Host "  -> Python 3.12 not found. Installing via Chocolatey..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Python not found on system. Installing python312 via choco..."
    $pythonInstall = Invoke-Choco -Arguments @('install', 'python312', '-y', '--no-progress')
    $pythonTail = $pythonInstall.Output
    if ($pythonTail -and $pythonTail.Length -gt 800) { $pythonTail = $pythonTail.Substring($pythonTail.Length - 800) }
    Write-DebugLog "INFO" "choco install python312 exit=$($pythonInstall.ExitCode) attempts=$($pythonInstall.Attempts)"
    if (-not $pythonInstall.Ran) {
        Write-DebugLog "ERROR" "choco install python312: choco.exe not found"
    } elseif ($pythonInstall.ExitCode -ne 0 -or $pythonInstall.Transient) {
        Write-Warning "[Bazarr] choco install python312 returned exit code $($pythonInstall.ExitCode). Trying other Python locations..."
        Write-DebugLog "WARN" "choco install python312 non-zero exit (exit $($pythonInstall.ExitCode), transient=$($pythonInstall.Transient), attempts=$($pythonInstall.Attempts)): $pythonTail"
        if ($pythonInstall.ExitCode -eq 1603) {
            # 1603 is ERROR_INSTALL_FAILURE: an MSI-level conflict or a broken
            # registration, not a transient feed problem -- retrying will not help.
            Write-Warning "[Bazarr] 1603 is a fatal MSI error, usually a broken or partial Python 3.12 registration."
            Write-Host "    Remove 'Python 3.12' (Settings > Apps), then re-run .\master_install.ps1" -ForegroundColor Gray
        }
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

# Version-specific cache check.  The pinned version must match: falling back to
# "any cached zip" would install an older release while the lock file/ledger
# record the pinned version (and update_bazarr.ps1 would then consider the
# install up to date).
$VersionNumeric = if ($PinnedVersion) { $PinnedVersion.TrimStart('v') } else { $null }
$CacheFile = if ($PinnedVersion) { Join-Path $BinDir "bazarr-$PinnedVersion.zip" } else { $null }
$CachedZip = if ($CacheFile -and (Test-Path $CacheFile)) {
    Get-Item $CacheFile
} elseif ($VersionNumeric) {
    Get-ChildItem $BinDir -Filter "bazarr*$VersionNumeric*.zip" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match "(^|[^0-9])$([regex]::Escape($VersionNumeric))([^0-9]|$)" } |
        Select-Object -First 1
} else {
    Get-ChildItem $BinDir -Filter "bazarr-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-DebugLog "VAR cached bazarr zip=$($CachedZip.Name) (found=$($null -ne $CachedZip))"

if ($CachedZip) {
    Write-Host "  -> Using cached $($CachedZip.Name)..." -ForegroundColor Gray
    $ZipPath = $CachedZip.FullName
    Write-DebugLog "INFO" "Using cached zip: $ZipPath"
    # Unpinned installs: keep the recorded version aligned with the archive we
    # actually install instead of writing "unknown" to the ledger.
    if (-not $PinnedVersion -and $CachedZip.BaseName -match '(\d+\.\d+\.\d+[0-9A-Za-z\.\-]*)$') {
        $PinnedVersion = $Matches[1]
        Write-DebugLog "VAR PinnedVersion derived from cached zip name=$PinnedVersion"
    }
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
    if (-not (Stop-ServiceBounded -Name $AppName)) {
        # The source tree is about to be deleted. Extracting over a directory that
        # a live Python process still holds would leave a half-old/half-new tree
        # that then starts and reports Running.
        Write-Warning "[$AppName] Service did not stop; its files were left untouched. Re-run once it has stopped."
        Write-DebugLog "ERROR" "$AppName did not stop within the bound before extraction; aborting"
        exit 1
    }
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
        $FilteredReq = [System.IO.Path]::GetTempFileName()
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
    nssm set $AppName AppRotateFiles 1 | Out-Null
    nssm set $AppName AppRotateBytes 5242880 | Out-Null
    nssm set $AppName ObjectName    ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service '$AppName' created under '$SvcUser'." -ForegroundColor Gray
    Write-DebugLog "INFO" "NSSM service '$AppName' created. stdoutLog=$(Join-Path $DataDir 'bazarr-stdout.log')"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists"
    # Self-heal a service bound to the wrong interpreter. Earlier versions could
    # point the service at a per-user Python the service account cannot read; a
    # re-run must repair that rather than keep the broken binary path.
    $svcParams = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$AppName\Parameters" -ErrorAction SilentlyContinue
    $svcApp = if ($svcParams) { $svcParams.Application } else { $null }
    if ($svcApp -and $svcApp.Trim('"') -ne $PythonExe) {
        Write-Host "  -> Service pointed at '$svcApp'; correcting to '$PythonExe'." -ForegroundColor Yellow
        Write-DebugLog "WARN" "$AppName service Application was '$svcApp', resetting to '$PythonExe'"
        nssm set $AppName Application "`"$PythonExe`"" | Out-Null
    }
}

# -- 7. Firewall ---------------------------------------------------------------
# LAN-scoped: Caddy proxies over loopback, so exposing this port to the internet
# would only bypass basic-auth and CrowdSec detection. See 03_sonarr.ps1.
# Remove any previous rule first: duplicates with the same DisplayName are allowed,
# so they would otherwise accumulate on every install run.
Get-NetFirewallRule -DisplayName $AppName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $AppName -Direction Inbound -LocalPort $AppPort `
    -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for $AppName port=$AppPort"

# -- 8. First-run: wait for config.yaml + API ready ---------------------------
# Bazarr performs multiple config.yaml writes during startup (initial create,
# then a defaults-fill pass). We must wait for the API to be up before stopping,
# otherwise our base_url edit gets overwritten on the next start.
Write-Host "  -> Starting Bazarr for first-run config generation (config 120s + API 90s)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName service for first-run initialization..."
$null = Start-ServiceBounded -Name $AppName
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
    $stoppedForEdit = Stop-ServiceBounded -Name $AppName
    if ($stoppedForEdit) {
        Start-Sleep -Seconds 3
    } else {
        # Bazarr rewrites config.yaml from memory while it runs, so an edit made
        # behind a live process is overwritten on the next restart.
        Write-Warning "[$AppName] Service did not stop; config.yaml was not edited."
        Write-DebugLog "ERROR" "$AppName did not stop within the bound before the config.yaml edit"
    }

    # -- 9. Set base_url for DuckDNS path routing ------------------------------
    if ($DomainMode -eq "duckdns") {
        if (-not $stoppedForEdit) {
            Write-Warning "  -> base_url NOT set. Re-run .\master_install.ps1 once Bazarr stops cleanly."
            Write-DebugLog "ERROR" "base_url edit skipped: $AppName never reached Stopped"
            exit 1
        }
        Write-DebugLog "INFO" "DuckDNS mode: setting base_url=/$AppLower in $ConfigFile"
        $placed = @(Set-YamlKey -Path $ConfigFile -Section "general" -Key "base_url" -Value "/$AppLower") -contains $true
        if ($placed) {
            Write-Host "  -> base_url set to /$AppLower (DuckDNS mode)." -ForegroundColor Green
            Write-DebugLog "INFO" "config.yaml base_url updated to '/$AppLower'"
        } else {
            Write-Warning "  -> Could not set base_url in config.yaml. Bazarr will serve at the domain root instead of /$AppLower."
            Write-DebugLog "ERROR" "Set-YamlKey did not write base_url to $ConfigFile"
        }
    } else {
        Write-DebugLog "INFO" "Cloudflare mode: base_url not set in config.yaml"
    }

    Write-DebugLog "INFO" "Restarting $AppName after config edit..."
    $null = Start-ServiceBounded -Name $AppName
}

# -- 10. Validate --------------------------------------------------------------
Start-Sleep -Seconds 3
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    # Do NOT record success for a service that never started. Writing the lock
    # file and the ledger entry here used to make a broken Bazarr permanent: the
    # next master_install.ps1 run saw "Already installed. Skipping." and never
    # repaired it. Leaving both unwritten means a re-run genuinely retries, and
    # exit 1 makes master_install.ps1 report FAILED -- it continues with the
    # other apps and skips only this app's configure step.
    Write-Host "  -> $AppName did NOT reach Running. Not recording it as installed." -ForegroundColor Red
    Write-Warning "  -> $AppName failed to start. Check $DataDir\bazarr-stderr.log"
    Write-DebugLog "ERROR" "$AppName did not reach Running (status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })); lock file and ledger NOT written so a re-run retries"
    exit 1
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, (New-Object System.Text.UTF8Encoding($false)))
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $LockVersion

Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "09_bazarr.ps1 complete"
