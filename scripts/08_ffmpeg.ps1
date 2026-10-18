param (
    [Parameter(Mandatory=$true)]
    [object]$Config,
    # scripts\update_ffmpeg.ps1 dot-sources this file with -FunctionsOnly to reuse
    # the helpers below (release resolution, download, verification, binary swap,
    # Machine PATH handling) without running the install flow: the installer and
    # the updater must not be able to drift apart.  Dot-sourcing puts the helpers
    # in the caller's scope, which is why they are declared "global:".
    [switch]$FunctionsOnly
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
# Shared choco plumbing: PATH-safe resolution plus retry-on-transient-feed-failure.
. (Join-Path $PSScriptRoot "choco_helpers.ps1")

# -- Shared helpers (also used by scripts\update_ffmpeg.ps1) -------------------
# ffmpeg comes from jellyfin-ffmpeg, not from the Chocolatey "ffmpeg" package:
# that package ships gyan.dev's "essentials" build, which omits OpenCL and
# libplacebo, so tonemap_opencl cannot work and every profiles\gpu\*.json profile
# (EnableTonemapping: true) silently falls back to software tone-mapping.
# NVENC/AMF/QSV/D3D11VA are present in both builds -- the gap is tone-mapping.

function global:Get-FfmpegRelease {
    # Resolves the release to install: the pinned tag, or the latest stable
    # release when no tag is given.  A pin that upstream no longer serves falls
    # back to the latest release instead of failing the step (the manifest
    # documents the same behaviour for Alloy).
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [string]$Tag
    )
    $headers = @{ "User-Agent" = "win-seedbox-installer" }
    $release = $null
    if ($Tag) {
        $uri = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
        Write-DebugLog "INFO" "Querying GitHub API: $uri"
        try {
            $release = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-DebugLog "WARN" "GitHub release tag '$Tag' not available for $Repo : $_"
        }
    }
    if (-not $release) {
        $uri = "https://api.github.com/repos/$Repo/releases/latest"
        Write-DebugLog "INFO" "Querying GitHub API: $uri"
        $release = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -ErrorAction Stop
    }
    if (-not $release -or -not $release.tag_name) { throw "No usable release found for $Repo" }
    return $release
}

function global:Get-FfmpegTagVersion {
    # "v8.1.3-1" -> "8.1.3": the trailing "-N" is jellyfin's own build number and
    # does not appear in the binary's version banner.
    param([string]$Tag)
    if (-not $Tag) { return $null }
    $m = [regex]::Match($Tag.Trim().TrimStart('v'), '^(\d+(?:\.\d+)*)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function global:Select-FfmpegAsset {
    # Picks the Windows x64 portable archive.  The arm64 asset shares most of the
    # file name, so it is excluded explicitly; the second pattern covers releases
    # whose asset name has no "-clang-gpl" suffix.
    param(
        [Parameter(Mandatory=$true)]$Release,
        [string]$AssetPattern
    )
    $patterns = @()
    if ($AssetPattern) { $patterns += $AssetPattern }
    $patterns += "*portable_win64*.zip"
    foreach ($pattern in $patterns) {
        $asset = $Release.assets | Where-Object {
            $_.name -like $pattern -and $_.name -notlike "*arm64*"
        } | Select-Object -First 1
        if ($asset) { return $asset }
    }
    return $null
}

function global:Get-FfmpegExeInfo {
    # Runs the binary's banner and returns what the installer/updater must know
    # before it is allowed to replace the installed copy.  $null means the binary
    # could not be executed at all.
    param([Parameter(Mandatory=$true)][string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    # ffmpeg writes its banner to stderr; with the inherited EAP="Stop" that would
    # turn a purely informational version check into a failed install step.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $banner = & $ExePath -hide_banner -version 2>&1
    } catch {
        $banner = $null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    if (-not $banner) { return $null }
    $first = [string]($banner | Select-Object -First 1)
    $m = [regex]::Match($first, 'ffmpeg version\s+(\S+)')
    if (-not $m.Success) { return $null }
    $configuration = ""
    foreach ($line in $banner) {
        if ("$line" -like "configuration:*") { $configuration = "$line"; break }
    }
    return [PSCustomObject]@{
        Version       = $m.Groups[1].Value
        Banner        = $first
        Configuration = $configuration
    }
}

function global:Test-FfmpegTonemapSupport {
    # Tone-mapping needs OpenCL and libplacebo compiled in.  Checks the configure
    # line only, so it is cheap enough to run on both the staged and the installed
    # binary.  Returns @{ Ok; Missing }.
    param([Parameter(Mandatory=$true)]$Info)
    $missing = @()
    if ($Info.Configuration -notmatch '--enable-opencl')     { $missing += "--enable-opencl" }
    if ($Info.Configuration -notmatch '--enable-libplacebo') { $missing += "--enable-libplacebo" }
    return [PSCustomObject]@{ Ok = ($missing.Count -eq 0); Missing = $missing }
}

function global:Test-FfmpegRuntimeCapabilities {
    # Proves the filters and encoders the GPU profiles depend on are really
    # present (a configure flag alone does not prove a filter was compiled in).
    # tonemap_opencl and libplacebo are required; NVENC/QSV/AMF are reported but
    # not fatal, since which of them a box can use depends on its GPU.
    param([Parameter(Mandatory=$true)][string]$ExePath)
    $savedEAP = $ErrorActionPreference
    $hwaccels = @(); $filters = @(); $encoders = @()
    try {
        $ErrorActionPreference = "Continue"
        $hwaccels = @(& $ExePath -hide_banner -hwaccels 2>&1 | ForEach-Object { "$_" })
        $filters  = @(& $ExePath -hide_banner -filters  2>&1 | ForEach-Object { "$_" })
        $encoders = @(& $ExePath -hide_banner -encoders 2>&1 | ForEach-Object { "$_" })
    } catch {
        Write-DebugLog "WARN" "ffmpeg capability probe failed on $ExePath : $_"
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    $hasOpenclAccel    = [bool]($hwaccels | Select-String -Pattern 'opencl' -SimpleMatch -Quiet)
    $hasTonemapOpencl  = [bool]($filters  | Select-String -Pattern 'tonemap_opencl' -SimpleMatch -Quiet)
    $hasLibplacebo     = [bool]($filters  | Select-String -Pattern 'libplacebo' -SimpleMatch -Quiet)
    $hasNvenc          = [bool]($encoders | Select-String -Pattern 'nvenc' -SimpleMatch -Quiet)
    $hasQsv            = [bool]($encoders | Select-String -Pattern 'qsv' -SimpleMatch -Quiet)
    $hasAmf            = [bool]($encoders | Select-String -Pattern 'amf' -SimpleMatch -Quiet)
    Write-DebugLog "VAR ffmpeg hwaccels: $($hwaccels -join ' ')"
    Write-DebugLog "VAR ffmpeg capabilities: tonemap_opencl=$hasTonemapOpencl libplacebo=$hasLibplacebo opencl=$hasOpenclAccel nvenc=$hasNvenc qsv=$hasQsv amf=$hasAmf"
    $missing = @()
    if (-not $hasTonemapOpencl) { $missing += "tonemap_opencl" }
    if (-not $hasLibplacebo)    { $missing += "libplacebo" }
    if (-not $hasOpenclAccel)   { $missing += "opencl hwaccel" }
    $detail = ""
    if ($missing.Count -gt 0) {
        $detail = "build lacks " + ($missing -join ", ") + " -- hardware tone-mapping would not work"
    }
    return [PSCustomObject]@{ Ok = ($missing.Count -eq 0); Detail = $detail; Missing = $missing }
}

function global:Expand-FfmpegArchive {
    # Extracts the portable archive into $StageDir and returns the paths of the
    # binaries it carries.  The win64 archives are flat (ffmpeg.exe + ffprobe.exe
    # at the root), but that layout is not a documented contract, so both files
    # are searched recursively.
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$StageDir
    )
    if (Test-Path -LiteralPath $StageDir) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $StageDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $StageDir -Force -ErrorAction Stop
    $exe = Get-ChildItem -Path $StageDir -Filter "ffmpeg.exe" -Recurse -File | Select-Object -First 1
    if (-not $exe) { return $null }
    $probe = Get-ChildItem -Path $StageDir -Filter "ffprobe.exe" -Recurse -File | Select-Object -First 1
    return [PSCustomObject]@{
        Ffmpeg  = $exe.FullName
        Ffprobe = if ($probe) { $probe.FullName } else { $null }
    }
}

function global:Move-FfmpegBuildIntoPlace {
    # Replaces ffmpeg.exe/ffprobe.exe in $TargetDir with the staged build.
    # The previous binaries are renamed aside (never deleted) until every new file
    # has landed; a failure restores them.  A running Jellyfin transcode holds
    # ffmpeg.exe open, which makes the replace fail, hence the retry loop.
    # Returns @{ Ok; Detail; Backups } -- Backups must be released by the caller
    # once the new build is verified, or restored when it is not.
    param(
        [Parameter(Mandatory=$true)][string]$StageFfmpeg,
        [string]$StageFfprobe,
        [Parameter(Mandatory=$true)][string]$TargetDir,
        [int]$Attempts = 3
    )
    $result = [PSCustomObject]@{ Ok = $false; Detail = ""; Backups = @() }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null
    }
    $sources = @([PSCustomObject]@{ Source = $StageFfmpeg; Name = "ffmpeg.exe" })
    if ($StageFfprobe) { $sources += [PSCustomObject]@{ Source = $StageFfprobe; Name = "ffprobe.exe" } }

    $failure = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $landed   = @()
        $backedUp = @()
        $failure  = $null
        try {
            foreach ($item in $sources) {
                $target = Join-Path $TargetDir $item.Name
                if (Test-Path -LiteralPath $target) {
                    $bak = "$target.bak"
                    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $target -Destination $bak -Force -ErrorAction Stop
                    $backedUp += [PSCustomObject]@{ Target = $target; Bak = $bak }
                }
                Copy-Item -LiteralPath $item.Source -Destination $target -Force -ErrorAction Stop
                $landed += $target
            }
        } catch {
            $failure = $_
            foreach ($t in $landed) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
            foreach ($b in $backedUp) {
                if (Test-Path -LiteralPath $b.Bak) {
                    Move-Item -LiteralPath $b.Bak -Destination $b.Target -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if (-not $failure) {
            $result.Ok = $true
            $result.Backups = @($backedUp | ForEach-Object { $_.Bak })
            $result.Detail = "replaced " + (($sources | ForEach-Object { $_.Name }) -join ", ") + " in $TargetDir"
            return $result
        }
        Write-DebugLog "WARN" "ffmpeg binary replace attempt $attempt/$Attempts failed: $failure"
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    $result.Detail = "could not replace the ffmpeg binaries in $TargetDir ($failure)"
    return $result
}

function global:Restore-FfmpegSwapBackup {
    # Puts back the binaries Move-FfmpegBuildIntoPlace renamed aside.  Used when
    # the new build landed but could not be activated (PATH not writable, PATH no
    # longer resolving to it), so the box keeps a working ffmpeg.
    param([string[]]$Backups)
    foreach ($bak in $Backups) {
        if (-not (Test-Path -LiteralPath $bak)) { continue }
        $target = $bak -replace '\.bak$', ''
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $bak -Destination $target -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $target) {
            Write-DebugLog "WARN" "restored the previous $target"
        } else {
            Write-DebugLog "ERROR" "could not restore $target from $bak"
        }
    }
}

function global:Resolve-FfmpegOnMachinePath {
    # Jellyfin (and its hardware transcoding) runs as a Windows service, so it only
    # ever sees the machine-wide PATH -- never the per-user one.  Resolve
    # ffmpeg.exe exactly the way it would.
    param([string]$ExeName = "ffmpeg.exe")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not $machinePath) { return $null }
    foreach ($pathEntry in ($machinePath -split ';')) {
        $dir = $pathEntry.Trim().Trim('"')
        if ($dir -eq "") { continue }
        $dir = [Environment]::ExpandEnvironmentVariables($dir)
        if ($dir -eq "") { continue }
        $candidate = Join-Path $dir $ExeName
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function global:Add-MachinePathEntryFirst {
    # Puts $Dir at the front of the machine PATH (idempotent).  Front, not back:
    # an already-installed box can still carry a second ffmpeg.exe (the Chocolatey
    # shim) and only the first PATH entry is the one Jellyfin resolves, so the
    # ordering must not be left to chance.
    param([Parameter(Mandatory=$true)][string]$Dir)
    $wanted  = $Dir.TrimEnd('\')
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not $current) { $current = "" }
    $entries = @($current -split ';' | Where-Object { $_.Trim().Trim('"') -ne "" })
    if ($entries.Count -gt 0 -and ($entries[0].Trim().Trim('"').TrimEnd('\') -ieq $wanted)) {
        return [PSCustomObject]@{ Changed = $false; Path = $current }
    }
    $kept = @($entries | Where-Object { -not ($_.Trim().Trim('"').TrimEnd('\') -ieq $wanted) })
    $newPath = (@($wanted) + $kept) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    return [PSCustomObject]@{ Changed = $true; Path = $newPath }
}

function global:Remove-ChocolateyFfmpeg {
    # Supersede a pre-existing Chocolatey ffmpeg instead of leaving two
    # ffmpeg.exe copies to race on PATH resolution: that build cannot tone-map, so
    # if it ever wins, HDR->SDR silently regresses to software -- the exact bug
    # this installer now avoids.  Nothing else in the stack needs it (only Jellyfin
    # consumes ffmpeg, and its NVENC/QSV/AMF coverage is a subset of this build),
    # and master_uninstall.ps1 already skips packages that are not installed.
    # Best effort: a failure here must not fail the install, because the PATH
    # entry added afterwards makes this build win anyway.
    # Returns: "removed" | "absent" | "no-choco" | "failed"
    param([string]$Package = "ffmpeg")
    if (-not (Resolve-ChocoExe)) { return "no-choco" }
    $listOutput = Get-ChocoInstalledVersion -Package $Package
    Write-DebugLog "VAR choco list --exact $Package -r => $listOutput"
    if ([string]::IsNullOrWhiteSpace($listOutput)) { return "absent" }

    Write-DebugLog "INFO" "Removing the Chocolatey '$Package' package (superseded by jellyfin-ffmpeg)"
    $uninstall = Invoke-Choco -Arguments @('uninstall', $Package, '-y', '--no-progress')
    $uninstallTail = $uninstall.Output
    if ($uninstallTail -and $uninstallTail.Length -gt 800) { $uninstallTail = $uninstallTail.Substring($uninstallTail.Length - 800) }
    if ($uninstall.ExitCode -eq 0) { return "removed" }
    Write-DebugLog "WARN" "choco uninstall $Package exit=$($uninstall.ExitCode) (transient=$($uninstall.Transient), attempts=$($uninstall.Attempts)): $uninstallTail"
    return "failed"
}

function global:Install-FfmpegBuild {
    # Downloads, verifies and installs the Windows x64 jellyfin-ffmpeg portable
    # build, then makes sure the machine PATH (all a Jellyfin service sees)
    # resolves "ffmpeg" to it.  The staged binary is verified before the installed
    # copy is touched, and the previous binaries are kept until the new build has
    # been verified in place, so a failed run leaves a working ffmpeg behind.
    # Returns @{ Ok; Tag; Version; Banner; ExePath; Detail }; Ok=$false means
    # nothing may be recorded in the lock file or the ledger.
    param(
        [Parameter(Mandatory=$true)][string]$InstallDir,
        [Parameter(Mandatory=$true)][string]$BinDir,
        [Parameter(Mandatory=$true)][string]$Repo,
        [string]$AssetPattern,
        [string]$Tag,
        [string]$SvcUser = "seedbox-svc"
    )
    $result = [PSCustomObject]@{
        Ok = $false; Tag = $null; Version = $null; Banner = $null; ExePath = $null; Detail = ""
    }

    # "latest"/"unknown" are manifest sentinels, not tags.
    if ($Tag -and ($Tag -ieq "latest" -or $Tag -ieq "unknown")) {
        Write-DebugLog "WARN" "Ignoring non-version manifest pin for ffmpeg: '$Tag'"
        $Tag = $null
    }

    $targetDir = Join-Path $InstallDir "ffmpeg"
    $stageDir  = Join-Path $InstallDir ".ffmpeg-staging"
    if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

    # Cache first. The asset name encodes the upstream tag, so an archive already in
    # bin\ needs no API call at all. GitHub's unauthenticated API allows 60 requests
    # per hour, shared by every machine behind one NAT, and exhausting it used to
    # fail a fully-cached reinstall for no reason.
    $zipPath = $null
    $asset   = $null
    # Get-ChildItem -Filter $null matches *every* file in bin\, which also holds the
    # cached archives of the other apps (an ffmpeg install without versions.json, or
    # with a manifest entry that has no "asset" key, passes $null here).  The newest
    # of those would be mistaken for the ffmpeg archive and then deleted by the
    # refetch below, so fall back to the same default Select-FfmpegAsset uses and
    # never consider an arm64 build.
    $cachePattern = if ($AssetPattern) { $AssetPattern } else { "*portable_win64*.zip" }
    $patternFiles = @(Get-ChildItem -Path $BinDir -Filter $cachePattern -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notlike "*arm64*" })
    if ($Tag) {
        $tagNumeric = $Tag.TrimStart('v')
        # Exact tag match, not a substring: a plain -like "*8.1.3-1*" also matches
        # the 8.1.3-10 archive, and that archive would then be recorded under the
        # pin.  The lookahead keeps a build number from matching a longer one.
        $tagPattern = [regex]::Escape($tagNumeric) + '(?!\d)'
        $cachedZip  = @($patternFiles | Where-Object { [regex]::IsMatch($_.Name, $tagPattern) } |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    } else {
        $cachedZip  = @($patternFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    }

    $release = $null
    $cacheMatchedPin = $false
    if ($cachedZip.Count -gt 0) {
        $zipPath = $cachedZip[0].FullName
        $asset   = [PSCustomObject]@{ name = $cachedZip[0].Name; size = $cachedZip[0].Length; browser_download_url = $null }
        # Only a pin-matched archive may be recorded under the pin. The selection
        # above already filtered on the pin when $Tag was set, so a non-empty $Tag
        # here means the archive really is that release; without $Tag it is whatever
        # was newest in bin\ and must not be recorded as the pin.
        $cacheMatchedPin = [bool]$Tag
        Write-DebugLog "INFO" "Cached archive matches the pin -- skipping the GitHub API: $zipPath"
    } else {
        try {
            $release = Get-FfmpegRelease -Repo $Repo -Tag $Tag
        } catch {
            # Nothing matched the pin and the API refused. An older cached archive is
            # still better than a failed install, and the warning says which one ran.
            $fallback = @($patternFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($fallback.Count -eq 0) {
                $result.Detail = "cannot resolve a release for $($Repo): $_"
                Write-DebugLog "ERROR" $result.Detail
                return $result
            }
            $zipPath = $fallback[0].FullName
            $asset   = [PSCustomObject]@{ name = $fallback[0].Name; size = $fallback[0].Length; browser_download_url = $null }
            Write-Warning "  -> GitHub API unavailable; using the cached archive $($asset.name) instead of the pinned $Tag."
            Write-DebugLog "WARN" "GitHub API failed ($_); falling back to cached archive $zipPath"
        }
    }

    if (-not $zipPath) {
        if ($Tag -and $release.tag_name -ine $Tag) {
            Write-Host "  -> Pinned release $Tag is not available upstream; using $($release.tag_name)." -ForegroundColor Yellow
            Write-DebugLog "WARN" "Pinned ffmpeg release $Tag missing; fell back to $($release.tag_name)"
        }
        $asset = Select-FfmpegAsset -Release $release -AssetPattern $AssetPattern
        if (-not $asset) {
            $result.Detail = "no Windows x64 portable asset in release $($release.tag_name) of $Repo"
            Write-DebugLog "ERROR" $result.Detail
            return $result
        }
        $zipPath = Join-Path $BinDir $asset.name
    }
    Write-DebugLog "VAR asset=$($asset.name) bytes=$($asset.size) zipPath=$zipPath"

    # The tag of the archive that is about to be installed. The cache branch
    # skips the GitHub API, so $release is null there; without this fallback the
    # lock file and the ledger got the non-version sentinel 'installed' and the
    # updater could never tell whether ffmpeg was current.
    $resolvedTag = if ($release -and $release.tag_name) {
        $release.tag_name
    } elseif ($cacheMatchedPin -and $Tag) {
        $Tag
    } elseif ($asset -and $asset.name -match '(\d+\.\d+\.\d+(?:-\d+)?)') {
        "v" + $Matches[1]
    } else {
        $null
    }
    Write-DebugLog "VAR resolvedTag=$resolvedTag"
    $staged  = $null
    $extractError = ""
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -gt 1 -and (Test-Path -LiteralPath $zipPath)) {
            # The cached copy did not extract: assume it is truncated and refetch.
            Write-DebugLog "WARN" "Discarding cached zip $zipPath and downloading again"
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $zipPath) -and -not $asset.browser_download_url) {
            # A cached archive carries no download URL, so the refetch above would
            # call Invoke-WebRequest with a null -Uri and fail with a misleading
            # "download failed" while the real problem is a corrupt cache entry.
            # Resolve the release now so the retry can really download it.
            Write-DebugLog "WARN" "Cached archive $($asset.name) is unusable and has no download URL; resolving the release again"
            try {
                $release = Get-FfmpegRelease -Repo $Repo -Tag $Tag
                $freshAsset = Select-FfmpegAsset -Release $release -AssetPattern $AssetPattern
                if ($freshAsset) {
                    $asset      = $freshAsset
                    $zipPath    = Join-Path $BinDir $asset.name
                    $resolvedTag = $release.tag_name
                    Write-DebugLog "INFO" "Re-resolved $($asset.name) for the refetch (tag=$resolvedTag)"
                }
            } catch {
                Write-DebugLog "WARN" "could not re-resolve a download URL for the discarded cached archive: $_"
            }
        }
        if (-not (Test-Path -LiteralPath $zipPath) -and -not $asset.browser_download_url) {
            $result.Detail = "the cached archive $($asset.name) could not be extracted and no download URL is available ($extractError)"
            Write-DebugLog "ERROR" $result.Detail
            return $result
        }
        if (Test-Path -LiteralPath $zipPath) {
            Write-Host "  -> Using cached $($asset.name)." -ForegroundColor Gray
            Write-DebugLog "INFO" "Using cached zip: $zipPath"
        } else {
            Write-Host ("  -> Downloading {0} ({1:N1} MB)..." -f $asset.name, ($asset.size / 1MB)) -ForegroundColor Gray
            Write-DebugLog "INFO" "Downloading $($asset.browser_download_url) -> $zipPath"
            try {
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            } catch {
                # Never leave a partial file in the cache: a later run would treat
                # it as a valid cached zip.
                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
                $result.Detail = "download of $($asset.name) failed: $_"
                Write-DebugLog "ERROR" $result.Detail
                return $result
            }
            Write-DebugLog "INFO" "Download complete: $((Get-Item -LiteralPath $zipPath).Length) bytes"
        }
        try {
            $extractError = ""
            $staged = Expand-FfmpegArchive -ZipPath $zipPath -StageDir $stageDir
        } catch {
            $extractError = "$_"
            Write-DebugLog "WARN" "extracting $zipPath failed (attempt $attempt): $_"
            $staged = $null
        }
        if ($staged) { break }
        if (-not $extractError) { $extractError = "no ffmpeg.exe in $($asset.name)" }
    }
    if (-not $staged) {
        # Explicit "tool missing" guard: nothing may be recorded as installed.
        $result.Detail = "ffmpeg.exe is missing from $zipPath (extraction failed)"
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }
    if (-not $staged.Ffprobe) {
        Write-DebugLog "WARN" "the archive carries no ffprobe.exe; only ffmpeg.exe will be installed"
    }

    # -- verify the downloaded build before touching the installed copy ---------
    $info = Get-FfmpegExeInfo -ExePath $staged.Ffmpeg
    if (-not $info) {
        $result.Detail = "the downloaded ffmpeg.exe did not run"
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }
    $expectedVersion = Get-FfmpegTagVersion -Tag $resolvedTag
    if ($expectedVersion -and ($info.Version -notlike "$expectedVersion*")) {
        $result.Detail = "binary reports '$($info.Version)' but release $resolvedTag should be '$expectedVersion'"
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }
    $tonemap = Test-FfmpegTonemapSupport -Info $info
    if (-not $tonemap.Ok) {
        $result.Detail = "build lacks " + ($tonemap.Missing -join ", ") + "; hardware tone-mapping would not work"
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }
    $caps = Test-FfmpegRuntimeCapabilities -ExePath $staged.Ffmpeg
    if (-not $caps.Ok) {
        $result.Detail = $caps.Detail
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }

    $swap = Move-FfmpegBuildIntoPlace -StageFfmpeg $staged.Ffmpeg -StageFfprobe $staged.Ffprobe -TargetDir $targetDir
    if (-not $swap.Ok) {
        $result.Detail = $swap.Detail
        Write-DebugLog "ERROR" $result.Detail
        return $result
    }
    Write-DebugLog "INFO" $swap.Detail

    try {
        # The service account executes ffmpeg.exe from the machine PATH, so grant
        # it explicitly instead of relying on the install-tree ACL inheritance
        # that 00_service_account.ps1 set up (that helper is only loaded when this
        # script runs as part of master_install.ps1).
        if (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue) {
            try {
                Grant-SeedboxDirAccess -Path $targetDir -Username $SvcUser -Rights "ReadAndExecute"
            } catch {
                Write-DebugLog "WARN" "ACL grant on $targetDir failed: $_"
            }
        } else {
            Write-DebugLog "INFO" "Grant-SeedboxDirAccess not loaded; relying on the install-tree ACL for $targetDir"
        }

        switch (Remove-ChocolateyFfmpeg) {
            "removed"   {
                Write-Host "  -> Removed the Chocolatey ffmpeg package (that build cannot tone-map)." -ForegroundColor Gray
                Write-DebugLog "INFO" "Chocolatey ffmpeg package removed"
            }
            "failed"    {
                Write-Warning "  -> Could not remove the Chocolatey ffmpeg package; jellyfin-ffmpeg is first on the machine PATH regardless."
                Write-DebugLog "WARN" "Chocolatey ffmpeg package removal failed"
            }
            "absent"    { Write-DebugLog "INFO" "No Chocolatey ffmpeg package installed" }
            default     { Write-DebugLog "INFO" "Chocolatey not available; no Chocolatey ffmpeg package to supersede" }
        }

        $pathChange = Add-MachinePathEntryFirst -Dir $targetDir
        if ($pathChange.Changed) {
            # Keep this process consistent with what a new process will see.
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "  -> $targetDir added to the machine PATH (first entry)." -ForegroundColor Gray
            Write-DebugLog "INFO" "Machine PATH updated: $targetDir is now the first entry"
        } else {
            Write-DebugLog "INFO" "Machine PATH already resolves $targetDir first"
        }

        $resolved = Resolve-FfmpegOnMachinePath -ExeName "ffmpeg.exe"
        $expected = Join-Path $targetDir "ffmpeg.exe"
        if (-not $resolved -or ([System.IO.Path]::GetFullPath($resolved) -ine [System.IO.Path]::GetFullPath($expected))) {
            throw "the machine PATH resolves ffmpeg.exe to '$resolved' instead of '$expected'"
        }
        $installedInfo = Get-FfmpegExeInfo -ExePath $resolved
        if (-not $installedInfo) {
            throw "the installed ffmpeg.exe at $resolved did not run"
        }
        $installedTonemap = Test-FfmpegTonemapSupport -Info $installedInfo
        if (-not $installedTonemap.Ok) {
            throw "the installed build lacks " + ($installedTonemap.Missing -join ", ")
        }
    } catch {
        $result.Detail = "activating the new build failed: $_"
        Write-DebugLog "ERROR" $result.Detail
        Restore-FfmpegSwapBackup -Backups $swap.Backups
        return $result
    }

    foreach ($bak in $swap.Backups) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue }

    $result.Ok = $true
    $result.Tag = $resolvedTag
    $result.Version = $info.Version
    $result.Banner = $info.Banner
    $result.ExePath = $resolved
    $result.Detail = "installed $resolvedTag ($($info.Version)) at $resolved"
    return $result
}

# update_ffmpeg.ps1 reuses the helpers above without running the install flow.
if ($FunctionsOnly) { return }

# -- Install -------------------------------------------------------------------
Write-DebugLog "INFO" "08_ffmpeg.ps1 started"

$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir "ffmpeg"
$LockFile   = Join-Path $InstallDir ".locks\.ffmpeg.lock"
$BinDir     = Join-Path $PSScriptRoot "..\bin"
$Repo       = "jellyfin/jellyfin-ffmpeg"

$ManifestEntry = if ($Config._Versions -and $Config._Versions.Apps.ffmpeg) { $Config._Versions.Apps.ffmpeg } else { $null }
$PinnedVersion = if ($ManifestEntry) { $ManifestEntry.version } else { $null }
$AssetPattern  = if ($ManifestEntry) { $ManifestEntry.asset } else { $null }
if ($ManifestEntry -and $ManifestEntry.repo) { $Repo = $ManifestEntry.repo }
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir LockFile=$LockFile Repo=$Repo"
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetPattern=$AssetPattern BinDir=$BinDir"

if ($Config.Apps.Ffmpeg -ne $true) {
    Write-Host "[ffmpeg] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "ffmpeg skipped (Apps.Ffmpeg != true)"
    return
}

# The lock file alone is not proof that *this* installer's build is in place: a
# box upgraded from the Chocolatey-based installer still carries one while the
# binary lives somewhere else.  In that case migrate instead of skipping.
$installedExe = Join-Path $AppBinDir "ffmpeg.exe"
if ((Test-Path $LockFile) -and (Test-Path -LiteralPath $installedExe)) {
    # The skip must still hold the contract the install path enforces: Jellyfin is
    # a service and only sees the machine PATH, so a lock file plus a binary on disk
    # does not prove it can execute *this* build.  A restored install tree, or any
    # tool that rewrites the machine PATH, leaves both behind without the PATH
    # entry, and the skip would then report a healthy install forever while Jellyfin
    # transcodes with a stale build or none at all.
    $skipResolved = Resolve-FfmpegOnMachinePath -ExeName "ffmpeg.exe"
    if (-not $skipResolved -or ([System.IO.Path]::GetFullPath($skipResolved) -ine [System.IO.Path]::GetFullPath($installedExe))) {
        try {
            $repaired = Add-MachinePathEntryFirst -Dir $AppBinDir
            if ($repaired.Changed) {
                Write-Host "  -> Restored the machine PATH entry for $AppBinDir (it had been lost)." -ForegroundColor Yellow
                Write-DebugLog "WARN" "ffmpeg was installed but not resolvable first on the machine PATH; entry re-added"
            }
            $skipResolved = Resolve-FfmpegOnMachinePath -ExeName "ffmpeg.exe"
        } catch {
            Write-DebugLog "WARN" "could not repair the machine PATH for $AppBinDir : $_"
        }
    }
    if (-not $skipResolved -or ([System.IO.Path]::GetFullPath($skipResolved) -ine [System.IO.Path]::GetFullPath($installedExe))) {
        $skipText = if ($skipResolved) { $skipResolved } else { "(nothing)" }
        Write-Warning "  -> Jellyfin resolves ffmpeg.exe to $skipText instead of '$installedExe'. Re-run with -Force ffmpeg to reinstall it."
        Write-DebugLog "ERROR" "ffmpeg skip check: machine PATH resolves ffmpeg.exe to $skipText, expected '$installedExe'"
    }
    Write-Host "[ffmpeg] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "ffmpeg already installed (lock file present)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[ffmpeg] Replacing the existing non-jellyfin-ffmpeg install..." -ForegroundColor Yellow
    Write-DebugLog "WARN" "lock file present but $installedExe is missing; migrating to jellyfin-ffmpeg"
}

Write-Host "[ffmpeg] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing ffmpeg (jellyfin-ffmpeg) ==="

$install = Install-FfmpegBuild -InstallDir $InstallDir -BinDir $BinDir -Repo $Repo `
              -AssetPattern $AssetPattern -Tag $PinnedVersion
if (-not $install.Ok) {
    # Writing the lock file and the ledger entry after a failed install would make
    # every later run report "Already installed. Skipping." and would tell the
    # updater that the pinned version is installed, so a transient download or
    # verification failure could never be retried.  Leave both untouched and fail
    # the step so master_install.ps1 logs ffmpeg as failed and a re-run installs it.
    Write-Warning "[ffmpeg] $($install.Detail). Not writing the lock file so a re-run retries."
    Write-DebugLog "ERROR" "ffmpeg install failed: $($install.Detail); lock file and ledger left untouched"
    exit 1
}

# -- Verify what Jellyfin will actually execute --------------------------------
# Jellyfin runs as a Windows service, so it only sees the machine-wide PATH.
# Report the version it will find there and refuse to record the install when the
# service would pick up something else (or nothing).
$resolvedExe = Resolve-FfmpegOnMachinePath -ExeName "ffmpeg.exe"
if (-not $resolvedExe) {
    Write-Warning "  -> ffmpeg.exe is not on the machine PATH. Jellyfin transcoding will not find it - set the FFmpeg path in Jellyfin's dashboard or add its directory to the system PATH."
    Write-DebugLog "ERROR" "ffmpeg.exe not found on the machine PATH after install; lock file and ledger left untouched"
    exit 1
}
if ([System.IO.Path]::GetFullPath($resolvedExe) -ine [System.IO.Path]::GetFullPath($installedExe)) {
    Write-Warning "  -> the machine PATH resolves ffmpeg.exe to $resolvedExe instead of $installedExe. Not recording the install."
    Write-DebugLog "ERROR" "machine PATH resolves ffmpeg.exe to $resolvedExe, expected $installedExe; lock file and ledger left untouched"
    exit 1
}
Write-Host "  -> $($install.Banner)" -ForegroundColor Green
Write-DebugLog "VAR ffmpeg on machine PATH: $resolvedExe"
Write-DebugLog "INFO" "hardware tone-mapping support verified (opencl + libplacebo)"

# Record the release that is actually installed (verified against the binary
# above), not the manifest pin: a box that already carried a different ffmpeg
# build must show up as "update available" in the updater instead of being
# reported as current.
$LockVersion = if ($install.Tag) { $install.Tag } else { 'installed' }
if (-not $install.Tag) {
    Write-DebugLog "WARN" "ffmpeg release tag unknown (resolved from cache?); writing '$LockVersion' to the lock so it is never zero-byte"
}
[System.IO.File]::WriteAllText($LockFile, $LockVersion, (New-Object System.Text.UTF8Encoding($false)))
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName "ffmpeg" -Version $LockVersion

Write-Host "[ffmpeg] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "08_ffmpeg.ps1 complete"