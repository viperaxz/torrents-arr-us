# Layer 2: Application Integration Guide

## Overview

**Layer 2** wires all installed applications together via their REST APIs. It runs automatically at the end of `master_install.ps1`, but can also be re-run standalone at any time.

```
Layer 1 (install + auth)      Layer 2 (integration)
──────────────────────────    ──────────────────────────────────
Install Sonarr            →   Add Deluge as download client
Install Radarr            →   Add root folders
Install Prowlarr          →   Connect to Sonarr + Radarr, add indexers
Install Jellyfin          →   Create media libraries, configure GPU transcoding
Install Bazarr            →   Connect to Sonarr/Radarr, enable subtitle providers
Install Recyclarr         →   Sync TRaSH quality profiles to Sonarr/Radarr
```

## Running Layer 2

Layer 2 runs automatically as part of `master_install.ps1`. To re-run it independently (e.g., after editing `config.json`):

```powershell
.\master_configure_layer2.ps1
```

### Running individual scripts

```powershell
$cfg = Get-Content .\config.json | ConvertFrom-Json

.\scripts\configure_layer2_sonarr.ps1    -Config $cfg
.\scripts\configure_layer2_radarr.ps1    -Config $cfg
.\scripts\configure_layer2_recyclarr.ps1 -Config $cfg
.\scripts\configure_layer2_prowlarr.ps1  -Config $cfg
.\scripts\configure_layer2_jellyfin_libraries.ps1    -Config $cfg
.\scripts\configure_layer2_jellyfin_transcoding.ps1  -Config $cfg
.\scripts\configure_layer2_bazarr.ps1    -Config $cfg
```

Each script is idempotent — it checks for existing configuration and only adds what's missing.

## What Each Script Does

### `configure_layer2_sonarr.ps1` / `configure_layer2_radarr.ps1`
- Adds the configured root folder (TV / Movies) via the API.
- Adds Deluge as a download client (reads the password from `secrets\deluge_auth.txt`).
- Applies seed criteria to the synced indexers: `Layer2.PublicTrackerSeedRatio` for public trackers, unlimited for private ones, leaving `SeedRules` indexers to the values `configure_layer2_prowlarr.ps1` already pushed.
- Applies TRaSH-recommended naming formats and media management settings.
- Registers the Jellyfin (MediaBrowser) notification so Jellyfin refreshes its library on import (Sonarr additionally registers the post-import series-refresh hook).

### `configure_layer2_recyclarr.ps1`
- Downloads `recyclarr.exe` from GitHub if not present.
- Writes `%APPDATA%\recyclarr\secrets.yml` with Sonarr/Radarr API keys and base URLs.
- Writes a per-run `%APPDATA%\recyclarr\win-seedbox.yml` holding only the sections whose keys were actually read, and syncs with `-c` against it. Recyclarr aborts on an undefined `!secret`, so a service without credentials must not appear in the config at all.
- Runs `recyclarr sync` to push TRaSH quality profiles and custom format scoring. Recyclarr exits 0 even when it cannot parse the config, so the script treats `Config parsing failed` / `Exiting due to fatal error` in its debug log as the real failure signal.

### `configure_layer2_prowlarr.ps1`
- Registers Sonarr and Radarr as applications in Prowlarr (`syncLevel=fullSync`).
- Adds indexers from `config.json → Layer2.Prowlarr.Indexers` that are not explicitly `"Enabled": false` (a missing `Enabled` property counts as enabled). FlareSolverr-protected indexers are added disabled with the `flaresolverr` tag and enabled afterwards via a direct SQLite update; indexers that time out are skipped (non-fatal).

### `configure_layer2_jellyfin_libraries.ps1`
- Creates Movies and TV Shows libraries at the configured paths.
- Triggers a full library scan.

### `configure_layer2_jellyfin_transcoding.ps1`
- Applies a pre-tuned transcoding profile for `nvidia` or `intel` GPUs.
- Skipped if `Layer2.Jellyfin.GPU` is empty.

### `configure_layer2_bazarr.ps1`
- Connects Bazarr to Sonarr and Radarr using their API keys.
- Enables subtitle providers: opensubtitlescom, yifysubtitles, embeddedsubtitles, gestdown — plus titlovi and subdl, which are only enabled when their credentials/API key are configured. subsource is discontinued and is never enabled.
- Creates three language profiles: **English** (1), **Romanian** (2), **English + Romanian** (3).
- Sets auto-download defaults for both movies and series (profile 3).
- Enables subtitle synchronisation (alass/ffsubsync).

## Configuration Reference

All Layer 2 settings live under `"Layer2"` in `config.json`.

### Jellyfin

```json
"Jellyfin": {
  "GPU": "nvidia",
  "MediaLibraries": [
    { "Name": "Movies",   "Path": "E:\\MediaServer\\Media\\Movies", "Type": "movies"  },
    { "Name": "TV Shows", "Path": "E:\\MediaServer\\Media\\TV",     "Type": "tvshows" }
  ]
}
```

| Field | Values | Description |
|---|---|---|
| `GPU` | `"nvidia"` / `"intel"` / `""` | Hardware transcoding profile to apply. Leave empty to skip. |
| `MediaLibraries` | array | Libraries to create. `Type` is `movies`, `tvshows`, `music`, or `musicvideos`. |

### Prowlarr Indexers

```json
"Prowlarr": {
  "Indexers": [
    { "definitionName": "nyaasi",         "Name": "Nyaa.si" },
    { "definitionName": "thepiratebay",   "Name": "The Pirate Bay" },
    { "definitionName": "limetorrents",   "Name": "LimeTorrents" }
  ]
}
```

`definitionName` must match Prowlarr's internal indexer identifier (visible in Prowlarr's indexer schema). Each entry also takes an `Enabled` flag; only an explicit `false` skips it, so an entry with no `Enabled` property is added. FlareSolverr-protected indexers are handled automatically.

### Bazarr

```json
"OpenSubtitles": { "Username": "myuser", "Password": "mypass" },  // consumed by Bazarr
"Bazarr": {
  "TitloviUsername": "",
  "TitloviPassword": "",
  "SubdlApiKey": ""
}
```

Credentials are optional. opensubtitlescom, yifysubtitles, embeddedsubtitles and gestdown are always enabled; if OpenSubtitles.com credentials are omitted they simply use the anonymous quota. **titlovi and subdl are only enabled when their credentials are present** (enabling them without an API key makes Bazarr throttle them with `ConfigurationError` and retry every 12 hours), and subsource is never enabled because it is discontinued. Titlovi is required for Romanian subtitles.

## Workflow After First Install

1. **Prowlarr**: add any additional indexers in the Prowlarr UI — they sync automatically to Sonarr/Radarr.
2. **Bazarr**: add OpenSubtitles.com and/or Titlovi credentials in Settings if you want full subtitle quotas.
3. **Sonarr/Radarr**: add your first show/movie — Deluge will handle the download and Bazarr will fetch subtitles automatically.
4. **Jellyfin**: media appears in your libraries once Sonarr/Radarr moves the completed download.

## Troubleshooting

### Deluge not appearing in Sonarr/Radarr

- Verify Deluge services are running: `Get-Service DelugeDaemon` and `Get-Service DelugeWeb`
- Verify the password file exists: `<InstallDir>\secrets\deluge_auth.txt`
- Re-run: `.\scripts\configure_layer2_sonarr.ps1` / `configure_layer2_radarr.ps1`

### Prowlarr not connecting to Sonarr/Radarr

- Verify both services are running.
- Verify API keys are present in `C:\ProgramData\Sonarr\config.xml` and `C:\ProgramData\Radarr\config.xml`.
- In DuckDNS mode, Prowlarr registers Sonarr at `http://127.0.0.1:8989/sonarr` — if you changed UrlBase manually this may differ.

### Bazarr shows 500 on the providers page

- Check `C:\ProgramData\Bazarr\log\bazarr.log` for `KeyError` or similar.
- Re-run `configure_layer2_bazarr.ps1` to re-push the language profiles.

### Recyclarr sync fails

- Check that Sonarr and Radarr are running and their API keys are readable.
- Check `%APPDATA%\recyclarr\logs\cli\` for the latest debug log.
- In DuckDNS mode, the base URLs in `secrets.yml` include the path prefix (e.g., `http://127.0.0.1:8989/sonarr`). If you manually changed UrlBase, re-run `configure_layer2_recyclarr.ps1`.

### Jellyfin libraries not showing media

- Trigger a manual scan: Jellyfin UI → Dashboard → Libraries → Scan All Libraries.
- Verify the service account (`seedbox-svc`) has read access to the media paths.
- Check Jellyfin logs in `C:\ProgramData\Jellyfin\Server\log\`.

## FAQ

**Q: Can I run Layer 2 multiple times?**
A: Yes. Every script checks for existing configuration and only adds what is missing. Running it again is safe.

**Q: Can I skip a specific application in Layer 2?**
A: Set `Config.Apps.<AppName>` to `false` — all Layer 2 scripts check this flag and skip automatically.

**Q: Do services need to be restarted after Layer 2?**
A: No. All changes are applied via the apps' REST APIs while they are running. Authentication-related changes (set in Layer 1) trigger a service restart automatically.

**Q: Can I add more root folders or download clients?**
A: Yes — edit `config.json` (for paths defined there) or add them directly in the app UI. Re-running Layer 2 will add any newly configured paths; it will not remove manually added ones.
