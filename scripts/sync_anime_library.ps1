param(
    [string]$ConfigPath = "",
    [switch]$Quiet
)

# -- Renamed view of absolute-numbered anime packs ------------------------------
#
# Jellyfin has no "absolute numbering" mode: a flat pack of
# "Naruto Shippuden - 137 [v2].mkv" files is only mapped into a season when the
# show has exactly one season on the metadata provider, so every multi-season
# anime degenerates into "Season Unknown" with no titles or artwork.  The
# Real-Debrid mount is read-only, so this script re-presents the same files with
# SxxEyy names as symlinks (a few KB of metadata per episode -- no media is
# copied) inside a tree Jellyfin reads as a normal show:
#
#   <LibraryPath>\<Folder>\Season NN\<Folder> - SxxEyy.mkv
#
# Which packs are involved, where they live and how their absolute numbers map to
# seasons all come from config.json's Anime block; see scripts\anime_helpers.ps1.

$ErrorActionPreference = 'Stop'

function Write-SyncLog {
    param([string]$Level, [string]$Message)
    if (-not $script:LogFile) { return }
    try {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-SyncHost {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

function New-FileSymlink {
    param([string]$LinkPath, [string]$TargetPath)

    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path -LiteralPath $LinkPath) { [System.IO.File]::Delete($LinkPath) }

    # cmd's mklink rather than New-Item -ItemType SymbolicLink: PowerShell resolves
    # -Target as a wildcard path, which fails on Real-Debrid folder names such as
    # "Naruto HD [1080p] (001-220) [Complete Series + Movies]".
    $out = & cmd.exe /c "mklink `"$LinkPath`" `"$TargetPath`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mklink failed for '$LinkPath': $out" }
}

function Get-ExistingLinkTarget {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.PSObject.Properties['LinkType'] -and $item.LinkType -eq 'SymbolicLink') { return [string]$item.Target }
    return $null
}

# -- 1. Locate and load config.json ---------------------------------------------
if (-not $ConfigPath) {
    $candidates = @(
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json')
        (Join-Path $PSScriptRoot 'config.json')
        'D:\MediaServer\config.json'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $ConfigPath = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
}

if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) {
    Write-SyncHost "  [anime] config.json not found -- nothing to sync." 'DarkGray'
    exit 1
}

$Config     = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$InstallDir = if ($Config.General -and $Config.General.InstallDir) { $Config.General.InstallDir } else { 'D:\MediaServer' }

$LogDir = Join-Path $InstallDir 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$script:LogFile = Join-Path $LogDir 'anime_sync.log'
if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 2MB) {
    Move-Item -LiteralPath $script:LogFile -Destination "$script:LogFile.1" -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot "anime_helpers.ps1")

$anime = Get-AnimeConfig -Config $Config
if (-not $anime.Enabled) {
    Write-SyncLog "INFO" "Anime split disabled in config.json -- nothing to do"
    exit 0
}
if ($anime.Sources.Count -eq 0) {
    Write-SyncLog "INFO" "Anime.Enabled is true but Anime.Sources is empty -- nothing to do"
    exit 0
}

# -- 2. Single instance ---------------------------------------------------------
# The scheduled task can overlap with a manual run; two writers on the same links
# would race. A lock left behind by a killed run goes stale after 30 minutes.
$LockDir = Join-Path $InstallDir '.locks'
if (-not (Test-Path -LiteralPath $LockDir)) { New-Item -ItemType Directory -Path $LockDir -Force | Out-Null }
$LockFile  = Join-Path $LockDir '.anime_sync.lock'
$lockStream = $null
for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
        $lockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        break
    } catch {
        $age = if (Test-Path -LiteralPath $LockFile) { (Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime } else { [TimeSpan]::MaxValue }
        if ($age.TotalMinutes -lt 30) {
            Write-SyncLog "INFO" "Another sync is running (lock age $([int]$age.TotalSeconds)s) -- skipping"
            exit 0
        }
        Write-SyncLog "WARN" "Removing stale sync lock (age $([int]$age.TotalMinutes) min)"
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
}
if (-not $lockStream) { Write-SyncLog "ERROR" "Could not acquire sync lock"; exit 1 }

$libraryPath = if ($anime.LibraryPath) { $anime.LibraryPath } else { Join-Path $InstallDir 'Anime' }
$mountRoot   = "$($anime.MountLetter):\"

$created = 0
$kept    = 0
$removed = 0
$missing = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]

try {
    if (-not (Test-Path -LiteralPath $libraryPath)) {
        New-Item -ItemType Directory -Path $libraryPath -Force | Out-Null
        Write-SyncLog "INFO" "Created anime library path $libraryPath"
    }

    Write-SyncLog "INFO" "Sync start: mount=$mountRoot library=$libraryPath sources=$($anime.Sources.Count)"

    foreach ($source in $anime.Sources) {
        $folder  = [string]$source.Folder
        $torrent = [string]$source.Torrent
        $pattern = if ($source.PSObject.Properties['EpisodePattern'] -and $source.EpisodePattern) { [string]$source.EpisodePattern } else { '(\d{1,4})' }
        $lengths = @()
        if ($source.PSObject.Properties['SeasonLengths'] -and $source.SeasonLengths) {
            $lengths = @($source.SeasonLengths | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 })
        }
        # TheMovieDb numbers anime episodes continuously across seasons ("Season 2"
        # starts at episode 53, not 1), so the file name must carry the absolute
        # number inside the season folder.  Shows the provider numbers per season
        # need this set to false.
        $absoluteNumbers = if ($source.PSObject.Properties['AbsoluteEpisodeNumbers']) { $source.AbsoluteEpisodeNumbers -eq $true } else { $true }

        $srcPath = Join-Path $mountRoot $torrent
        if (-not (Test-Path -LiteralPath $srcPath)) {
            $missing.Add($torrent)
            Write-SyncLog "WARN" "Source not mounted, skipping: $srcPath"
            Write-SyncHost "   [SKIP] $folder -- $($anime.MountLetter):\ not mounted" 'Yellow'
            continue
        }

        try {
            $files = @(Get-ChildItem -LiteralPath $srcPath -File -ErrorAction Stop)
        } catch {
            $missing.Add($torrent)
            Write-SyncLog "WARN" "Cannot list $srcPath : $_"
            Write-SyncHost "   [SKIP] $folder -- cannot list the mount" 'Yellow'
            continue
        }

        # One episode number can appear more than once in a pack (alternate
        # encodes, "Canon Cut" edits); keep the largest file and treat the rest
        # as the same episode.
        $byNumber = @{}
        foreach ($file in $files) {
            if ($file.Name -notmatch $pattern) { continue }
            $number = 0
            if (-not [int]::TryParse($Matches[1], [ref]$number) -or $number -le 0) { continue }
            if (-not $byNumber.ContainsKey($number) -or $byNumber[$number].Length -lt $file.Length) { $byNumber[$number] = $file }
        }

        if ($byNumber.Count -eq 0) {
            Write-SyncLog "WARN" "$folder : no file matched EpisodePattern '$pattern' in $srcPath"
            Write-SyncHost "   [SKIP] $folder -- EpisodePattern matched nothing" 'Yellow'
            continue
        }

        $maxNumber = ($byNumber.Keys | Measure-Object -Maximum).Maximum
        $total     = if ($lengths.Count -gt 0) { ($lengths | Measure-Object -Sum).Sum } else { $maxNumber }
        if ($lengths.Count -gt 0 -and $maxNumber -gt $total) {
            Write-SyncLog "WARN" "$folder : pack has episode $maxNumber but SeasonLengths only covers $total -- extra numbers are ignored"
        }

        # Absolute number -> (season, episode) in air order.
        $seasonIndex = @{}
        if ($lengths.Count -gt 0) {
            $absolute = 1
            for ($s = 0; $s -lt $lengths.Count -and $absolute -le $total; $s++) {
                for ($e = 1; $e -le $lengths[$s] -and $absolute -le $total; $e++) {
                    $seasonIndex[$absolute] = @{ Season = $s + 1; Episode = $e }
                    $absolute++
                }
            }
        } else {
            for ($i = 1; $i -le $total; $i++) { $seasonIndex[$i] = @{ Season = 1; Episode = $i } }
        }

        $desired = @{}
        $outOfRange = 0
        foreach ($number in ($byNumber.Keys | Sort-Object)) {
            if (-not $seasonIndex.ContainsKey($number)) { $outOfRange++; continue }
            $season = $seasonIndex[$number].Season
            $episode = if ($absoluteNumbers) { $number } else { $seasonIndex[$number].Episode }
            $seasonDir = Join-Path (Join-Path $libraryPath $folder) ('Season {0:00}' -f $season)
            $extension = [System.IO.Path]::GetExtension($byNumber[$number].Name)
            $linkName  = '{0} - S{1:00}E{2:00}{3}' -f $folder, $season, $episode, $extension
            $linkPath  = Join-Path $seasonDir $linkName
            $desired[$linkPath.ToLowerInvariant()] = @{ Path = $linkPath; Target = $byNumber[$number].FullName }
        }

        $sourceCreated = 0
        $sourceKept    = 0
        foreach ($entry in $desired.Values) {
            $existingTarget = Get-ExistingLinkTarget -Path $entry.Path
            if ($existingTarget -and $existingTarget -eq $entry.Target) {
                $kept++; $sourceKept++
                continue
            }
            try {
                New-FileSymlink -LinkPath $entry.Path -TargetPath $entry.Target
                $created++; $sourceCreated++
            } catch {
                Write-SyncLog "ERROR" "$_"
                Write-SyncHost "   [ERR ] $($entry.Path)" 'Red'
            }
        }

        # Drop links that no longer correspond to a file in the pack (re-packs,
        # removed episodes). Real files are never touched.
        $showDir = Join-Path $libraryPath $folder
        $sourceRemoved = 0
        if (Test-Path -LiteralPath $showDir) {
            foreach ($existing in @(Get-ChildItem -LiteralPath $showDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                if ($desired.ContainsKey($existing.FullName.ToLowerInvariant())) { continue }
                if ($existing.PSObject.Properties['LinkType'] -and $existing.LinkType -eq 'SymbolicLink') {
                    try {
                        [System.IO.File]::Delete($existing.FullName)
                        $removed++; $sourceRemoved++
                    } catch {
                        Write-SyncLog "WARN" "Could not remove stale link $($existing.FullName): $_"
                    }
                } else {
                    Write-SyncLog "WARN" "Leaving non-link file in the way: $($existing.FullName)"
                }
            }
            foreach ($dir in @(Get-ChildItem -LiteralPath $showDir -Directory -Force -ErrorAction SilentlyContinue)) {
                if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $seasonLabel = if ($lengths.Count -gt 0) { "$($lengths.Count) season(s)" } else { 'single season' }
        $results.Add([PSCustomObject]@{
            Folder  = $folder
            Episodes = $desired.Count
            Seasons = $seasonLabel
            Created = $sourceCreated
            Kept    = $sourceKept
            Removed = $sourceRemoved
            Extra   = $outOfRange
        })
        Write-SyncHost ("   [OK  ] {0}: {1} episode(s) in {2} (new {3}, kept {4}, pruned {5})" -f $folder, $desired.Count, $seasonLabel, $sourceCreated, $sourceKept, $sourceRemoved) 'Green'
        Write-SyncLog "INFO" "$folder : episodes=$($desired.Count) seasons=$seasonLabel created=$sourceCreated kept=$sourceKept removed=$sourceRemoved outOfRange=$outOfRange"
    }
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

Write-SyncLog "INFO" "Sync done: created=$created kept=$kept removed=$removed missing=$($missing.Count)"
if ($missing.Count -gt 0) {
    Write-SyncLog "WARN" "Sources not available this run: $($missing -join '; ')"
    Write-SyncHost "   [WARN] $($missing.Count) source(s) not mounted -- run again once $($anime.MountLetter): is available." 'Yellow'
}

if (-not $Quiet) {
    Write-Host ""
    if ($results.Count -gt 0) { $results | Format-Table -AutoSize | Out-String | Write-Host }
    Write-Host ("  Anime library: {0}  (created {1}, kept {2}, pruned {3})" -f $libraryPath, $created, $kept, $removed) -ForegroundColor Cyan
}

exit 0
