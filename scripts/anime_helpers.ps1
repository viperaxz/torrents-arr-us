# -- Anime split helpers ---------------------------------------------------------
#
# An absolute-numbered anime pack ("Naruto Shippuden - 137 [v2].mkv") carries no
# season information, and Jellyfin only falls back to season 1 for a show that has
# exactly one season.  Every multi-season anime therefore lands in "Season
# Unknown": no episode titles, no thumbnails, no season navigation.  The
# Real-Debrid mount is read-only, so the files cannot simply be renamed.
#
# The split is three cooperating pieces:
#   1. scripts\15_zurg.ps1 routes the configured packs to their own zurg:anime
#      tree.  Zurg assigns every torrent to the FIRST matching directory by
#      group_order, so claiming these before zurg:shows is what keeps them out of
#      the Jellyfin TV library.
#   2. scripts\16_rclone.ps1 mounts zurg:anime on Anime.MountLetter (default T:).
#   3. scripts\sync_anime_library.ps1 links each episode into
#      <LibraryPath>\<Folder>\Season NN\<Folder> - SxxEyy.mkv, which Jellyfin
#      reads as a normal multi-season show.
#
# Config shape (config.json):
#   "Anime": {
#     "Enabled": true,
#     "MountLetter": "T",
#     "LibraryPath": "D:\\MediaServer\\Anime",
#     "Sources": [
#       { "Folder": "Naruto (2002)",
#         "Torrent": "Naruto HD [1080p] (001-220) [Complete Series + Movies]",
#         "EpisodePattern": "Naruto Episode (\\d{3})",
#         "AbsoluteEpisodeNumbers": true,
#         "SeasonLengths": [52, 52, 54, 62] }
#     ],
#     "ExtraTorrents": [ "[JySzE] Naruto [v3] ... [x264]" ]
#   }
#
# SeasonLengths is the episode count of each season in air order; the numbers add
# up to the show's absolute episode count.  Leave it out to put everything in
# Season 01 (still better than "Season Unknown", but episodes past season 1 of the
# show keep generic names).
#
# AbsoluteEpisodeNumbers (default true) matches TheMovieDb's anime convention,
# where episodes are numbered continuously across seasons - "Season 2" holds
# episodes 53..104, not 1..52 - so the link for absolute 53 is Season 02\..S02E53.
# Set it to false for a show whose provider numbers episodes per season.

function Get-AnimeConfig {
    param($Config)

    $result = [PSCustomObject]@{
        Enabled       = $false
        MountLetter   = 'T'
        LibraryPath   = $null
        Sources       = @()
        ExtraTorrents = @()
    }

    if (-not $Config -or -not $Config.PSObject.Properties['Anime'] -or -not $Config.Anime) {
        return $result
    }

    $a = $Config.Anime
    if ($a.PSObject.Properties['Enabled']) { $result.Enabled = ($a.Enabled -eq $true) }

    if ($a.PSObject.Properties['MountLetter'] -and $a.MountLetter) {
        $result.MountLetter = $a.MountLetter.ToString().ToUpper().TrimEnd(':')
    }
    if ($result.MountLetter -notmatch '^[A-Y]$') { $result.MountLetter = 'T' }

    if ($a.PSObject.Properties['LibraryPath'] -and $a.LibraryPath) {
        $result.LibraryPath = [string]$a.LibraryPath
    }

    if ($a.PSObject.Properties['Sources']) {
        $result.Sources = @($a.Sources | Where-Object {
            $_ -and $_.PSObject.Properties['Torrent'] -and $_.Torrent -and $_.PSObject.Properties['Folder'] -and $_.Folder
        })
    }

    if ($a.PSObject.Properties['ExtraTorrents']) {
        $result.ExtraTorrents = @($a.ExtraTorrents | Where-Object { $_ })
    }

    return $result
}

# Every torrent that belongs in zurg:anime -- mapped sources first, then the packs
# that are only parked there (duplicate or unmappable copies kept out of Jellyfin
# but still reachable on the anime mount).
function Get-AnimeTorrentNames {
    param($Config)

    $anime = Get-AnimeConfig -Config $Config
    $names = @()
    foreach ($s in $anime.Sources)       { $names += [string]$s.Torrent }
    foreach ($t in $anime.ExtraTorrents) { $names += [string]$t }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

# Alternation for Zurg's /.../ regex filter.  Two adjustments to .NET escaping:
#   * Zurg compiles the pattern with Go's RE2, which rejects an escaped space
#     ("\ "), and a space needs no escaping anyway;
#   * '/' would terminate the /.../ literal, so it becomes '.' -- the match only
#     has to identify the torrent, not be exact.
function Get-AnimeTorrentRegex {
    param($Config)

    $names = Get-AnimeTorrentNames -Config $Config
    if (-not $names -or $names.Count -eq 0) { return $null }

    $parts = foreach ($n in $names) {
        ([regex]::Escape($n)).Replace('\ ', ' ').Replace('/', '.')
    }
    return ($parts -join '|')
}

function Get-AnimeMountPath {
    param($Config)

    $anime = Get-AnimeConfig -Config $Config
    return "$($anime.MountLetter):\"
}
