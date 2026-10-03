# Win-Seedbox

A fully automated, Swizzin-inspired **Windows media server installer** written in PowerShell. One `config.json` and one `master_install.ps1` install, wire together, and secure a complete self-hosted media stack behind a Caddy reverse proxy.

## Application Stack

| Application | Role | Port |
|---|---|---|
| **Caddy** | Reverse proxy + TLS termination | 80 / 443 |
| **Jellyfin** | Media server / streaming | 8096 |
| **Jellyseerr** | Media request portal (Jellyfin-native) | 5055 |
| **Sonarr** | TV show automation | 8989 |
| **Radarr** | Movie automation | 7878 |
| **Prowlarr** | Indexer manager | 9696 |
| **Deluge** | Download daemon + web UI | 58846 (daemon), 8112 (web) |
| **Bazarr** | Subtitle manager | 6767 |
| **Flaresolverr** | Cloudflare/DDoS-Guard CAPTCHA bypass | 8191 (internal) |
| **ffmpeg** | Transcoding (Jellyfin dependency) | — |
| **Recyclarr** | TRaSH Guides quality profile sync | — |
| **Grafana** | Observability dashboard (optional) | 3000 |
| **Loki** | Log aggregation backend (bundled with Grafana) | 3100 (internal) |
| **Alloy** | Log shipper to Loki (bundled with Grafana) | — |
| **CrowdSec** | Intrusion detection (log parsing + ban decisions) | 8080 (LAPI, internal) |
| **CrowdSec FW bouncer** | Intrusion prevention (Windows Firewall enforcement) | — |
| **Zurg** | Real-Debrid WebDAV bridge (optional) | — (internal) |
| **rclone** | Mounts Zurg as local drive letters (optional) | — |

## Domain Modes

| Mode | Routing | DNS |
|---|---|---|
| **Cloudflare** | Each app on its own subdomain (`sonarr.yourdomain.com`) | Cloudflare API |
| **DuckDNS** | All apps on path prefixes (`yourdomain.duckdns.org/sonarr`) | DuckDNS API |

## Features

- **Zero-touch install**: bootstraps Chocolatey if absent, installs NSSM and all dependencies automatically — no manual prerequisite setup required.
- **Idempotent**: lock files prevent re-running installers; `master_install.ps1` is safe to run again.
- **Two-phase configuration**: Layer 1 sets up each app's authentication; Layer 2 wires apps together (download clients, root folders, indexers, media libraries, subtitle providers, quality profiles).
- **Service isolation**: dedicated `seedbox-svc` Windows account with no admin rights; each app only accesses its own data directory.
- **TLS**: Let's Encrypt production/staging or Caddy internal CA for LAN-only setups.
- **Cert cache**: Caddy's certificate store is AES-256 encrypted on uninstall and restored on reinstall — no unnecessary certificate reissuance.
- **Reinstall-safe app data**: the Deluge torrent state and the Sonarr/Radarr databases (monitored shows/movies, history, settings) are backed up on uninstall and restored automatically on reinstall.
- **Hardware transcoding**: NVIDIA (NVENC/CUDA), AMD (AMF), and Intel (QSV) profiles automatically applied to Jellyfin based on detected GPU family (18 profiles covering the last 10 years of GPU generations).
- **Quality automation**: Recyclarr syncs TRaSH Guides custom formats and quality profiles to Sonarr and Radarr on every install.
- **Subtitle automation**: Bazarr pre-configured with subtitle providers and language profiles (English + Romanian out of the box, easily adjusted).
- **Dynamic DNS**: a scheduled task under `seedbox-svc` updates your public IP every 5 minutes.
- **Cloudflare bypass**: Flaresolverr runs as a local Windows service and is registered with Prowlarr automatically — unlocks CF-protected trackers with no per-indexer setup.
- **Public indexers**: 18+ free public trackers (1337x, Nyaa.si, TPB, and more) are added to Prowlarr during Layer 2.
- **Media request portal**: Jellyseerr is installed and fully wired to Jellyfin, Sonarr, and Radarr — users request movies/shows through a Netflix-style UI without ever touching the *arr apps directly.
- **Shared user provisioning**: users defined once in `config.json` are created in both Jellyfin and Jellyseerr automatically; no duplicate admin work across apps.
- **Debug logging**: opt-in structured log file (`General.DebugLogging: true`) capturing every phase, variable, and API call for post-install diagnosis.
- **End-to-end sanity check**: `scripts/sanity_check.py` drives the full Prowlarr → Radarr/Sonarr → Deluge → Jellyfin → Bazarr pipeline and reports pass/fail for each stage.
- **Security layer**: CrowdSec parses the Caddy access log and the Windows Security event log to detect HTTP attacks and RDP/SMB brute force, and its Windows Firewall bouncer enforces the resulting bans; Spamhaus + Firehol abuse blocklists refreshed every 6 hours.
- **Jellyfin season repair**: `scripts/sonarr_jellyfin_refresh.py` is a Sonarr Custom Script hook that auto-fixes the Jellyfin season hierarchy bug that occurs when metadata is still loading at import time.
- **Real-Debrid integration** (optional): Zurg exposes your RD library as a local WebDAV server; rclone mounts it on a drive letter for movies; Jellyfin lean libraries are provisioned pointing at that drive with video extraction disabled to avoid bandwidth thrashing. TV shows cannot be reliably separated from movies via the Zurg WebDAV layer, so only a Movies library is provisioned.
- **Observability stack** (optional): Grafana + Loki + Alloy installed as Windows services; Alloy ships structured logs from every seedbox service to Loki; Grafana is pre-provisioned with the Loki data source and bundled dashboards. Enable with `Apps.Grafana: true` or run `grafana_enable.ps1` on an existing install.
- **LLM reverse proxy** (optional): publish an externally managed LLM backend (Strata, Ollama, LM Studio, or any OpenAI-compatible server) through Caddy — the project never installs or updates the LLM itself. `LLM.Enabled: true` adds a `llm.<domain>` subdomain (Cloudflare mode) or a `/llm/v1` API path (DuckDNS mode), an optional Bearer-key gate on the API (`LLM.ApiKey`), and a basicauth-gated UI when `LLM.ExposeUi: true`.
- **Server status monitoring**: a `Seedbox_Status_Collector` scheduled task runs every 5 minutes to collect uptime, memory, drive usage, service states, and download stats into `dashboard/current_status.json` for the dashboard UI.
- **Prowlarr private tracker support**: each indexer in `Layer2.Prowlarr.Indexers` has an `Enabled` flag; private trackers (FileList, IPTorrents, RuTracker, TorrentLeech) accept per-indexer `Credentials` and `SeedRules`.

## Quick Start

> [!WARNING]
> `config.json` contains API tokens, passwords, and private tracker credentials. **Never commit it to git.** The repository `.gitignore` excludes `config.json` by default, but double-check before any `git add`.

1. Clone the repository.
2. Copy `config.json.example` to `config.json`.
3. Fill in your domain, credentials, and API tokens (see **Configuration** below).
4. Open an **elevated (Administrator) PowerShell** prompt and run:

```powershell
.\master_install.ps1
```

This runs the full pipeline — prerequisites, all application installers, Layer 1 (authentication), and Layer 2 (application integration) — and prints a summary URL list when done.

### Re-running Layer 2 only

Layer 2 can be re-run independently after the initial install:

```powershell
.\master_configure_layer2.ps1
```

### Uninstalling

```powershell
.\master_uninstall.ps1        # prompts for confirmation
.\master_uninstall.ps1 -Force # skips confirmation
```

Preserves media files (downloads, movies, TV) and Chocolatey/NSSM. Encrypts and saves the Caddy cert store so it can be restored on reinstall. Backs up the Deluge torrent state and the Sonarr/Radarr databases, which are restored automatically on reinstall.

### Updating

Updates are **notify-then-apply**: a daily scheduled task checks for new versions and shows a notification, and you apply them yourself with one command.

```powershell
box check    # compare installed versions against the recommended manifest (read-only)
box update   # apply all available updates (auto-elevates, per-app rollback on failure)
```

How it works:

- `versions.json` in this repository is the **single source of truth** for recommended versions. It is refreshed weekly by an automated GitHub Actions workflow (maintainer side) that opens a pull request with upstream bumps.
- The daily `win-seedbox Update Check` task compares the remote manifest against the local ledger `<InstallDir>\.locks\installed_versions.json` and notifies via toast + dashboard.
- `box update` runs one dedicated update script per app (`scripts\update_<App>.ps1`): GitHub binary swaps with rollback, Chocolatey upgrades, a source rebuild for Jellyseerr, and single-exe swaps for Zurg/rclone/Loki/Alloy.
- Infrastructure packages (NSSM, Python) are never auto-updated; when their pin changes, `box check` lists them as manual updates (`.\master_install.ps1 -Force <AppName>`).
- `box update -WhatIf` (or `.\master_update.ps1 -WhatIf`) prints the plan without changing anything.

## Configuration

Copy `config.json.example` → `config.json` and fill in these key fields:

```json
{
  "General": {
    "DomainMode":             "cloudflare",
    "TlsMode":                "letsencrypt",
    "TlsEmail":               "your@email.com",
    "DebugLogging":           false,

    // Cloudflare mode:
    "Domain":                 "example.com",
    "CloudflareApiToken":     "...",

    // DuckDNS mode:
    "DuckDnsDomain":          "myhome.duckdns.org",
    "DuckDnsToken":           "...",

    "AdminUsername":          "admin",
    "AdminPassword":          "...",
    "ServiceAccountPassword": "...",
    "DefaultUserPassword":    "Welcome1!",
    "InstallDir":             "E:\\MediaServer"
  },
  "Apps": {
    "Jellyfin": true, "Sonarr": true, "Radarr": true,
    "Prowlarr": true, "Deluge": true, "Bazarr": true,
    "Ffmpeg": true, "Flaresolverr": true, "Jellyseerr": true,
    "Grafana": false,     // set true to install Grafana + Loki + Alloy
    "RealDebrid": false   // set true to install Zurg + rclone
  },
  "RealDebrid": {
    "ApiKey": "",         // your Real-Debrid API key
    "MountLetter": "R"    // movies on R:\, shows on S:\
  },
  "LLM": {
    "Enabled": false,     // publish an externally managed LLM through Caddy
    "Subdomain": "llm",
    "BackendHost": "127.0.0.1",
    "BackendPort": 8081,  // NOT 8080 (CrowdSec LAPI)
    "ApiKey": "",         // optional Bearer gate on /v1/*
    "ExposeUi": true       // also proxy the backend UI (Caddy basicauth)
  },
  "Ports": {
    "Jellyfin": 8096, "Sonarr": 8989, "Radarr": 7878,
    "Prowlarr": 9696, "Deluge": 58846, "DelugeWeb": 8112, "Bazarr": 6767,
    "Flaresolverr": 8191, "Jellyseerr": 5055
  },
  "Users": [
    { "Username": "alice" },
    { "Username": "bob" }
  ],
  "Paths": {
    "Downloads": "E:\\MediaServer\\Downloads",
    "Movies":    "E:\\MediaServer\\Media\\Movies",
    "TV":        "E:\\MediaServer\\Media\\TV"
  },
  "Security": {
    "CrowdSecEnrollKey": "",   // optional: enroll in the CrowdSec Console
    "BanDurationHours":  4,
    "ExtraWhitelistIps": [],   // never ban these (e.g. a VPN exit IP)
    "AbuseBlocklists":   true
  },
  "Layer2": {
    "Jellyfin": { "GPU": "nvidia_ada" },
    "PublicTrackerSeedRatio": 1.0,
    "OpenSubtitles": { "Username": "", "Password": "" },
    "Bazarr": { "TitloviUsername": "", "TitloviPassword": "" }
  }
}
```

Set `DomainMode` to `"cloudflare"` or `"duckdns"` and fill in only the matching DNS fields. `TlsMode` can be `"letsencrypt"`, `"letsencrypt-staging"`, or `"internal"` (LAN-only, self-signed).

For `Layer2.Jellyfin.GPU` use a GPU family slug such as `"nvidia_ada"`, `"nvidia_ampere"`, `"intel_uhd_12th"`, `"intel_arc"`, `"amd_rdna3"`, etc. — or `""` to skip hardware transcoding. Run `scripts/detect_gpu.ps1` to auto-detect the correct slug for this machine. Legacy vendor names (`"nvidia"`, `"intel"`, `"amd"`) are still accepted and will trigger auto-detection at install time.

`Layer2.PublicTrackerSeedRatio` sets the seed ratio applied to all public indexers in Sonarr/Radarr (default `1.0`). Private trackers keep their per-indexer `SeedRules` from `Layer2.Prowlarr.Indexers` instead.

Set `"Flaresolverr": false` in `Apps` if you want to skip it (all indexers will still work, but Cloudflare-protected ones will fail).

Set `"Grafana": true` in `Apps` to install the Grafana + Loki + Alloy observability stack. You can also run `grafana_enable.ps1` on an existing install to add it without reinstalling everything.

Set `"RealDebrid": true` in `Apps` and fill in `RealDebrid.ApiKey` to mount your Real-Debrid library as local drives. `MountLetter` is the base letter — movies land on `R:\` and shows on `S:\` by default.

Set `"LLM": { "Enabled": true }` to publish an externally managed LLM backend through Caddy. The project installs nothing: run the LLM yourself (e.g. Strata with `--port 8081`, keep `--host 127.0.0.1`, set its own `--api-key` or use `LLM.ApiKey`) and point Caddy at `BackendHost:BackendPort`. In Cloudflare mode the backend is published as `<Subdomain>.<Domain>` — `/v1` API behind the optional Bearer gate, UI behind Caddy basicauth when `ExposeUi: true`. In DuckDNS mode only the API is exposed, at `https://<host>/llm/v1`. Never use port 8080 — it belongs to CrowdSec's LAPI.

Set `"DebugLogging": true` to capture a detailed log of every install step to `<InstallDir>\logs\seedbox_debug_<timestamp>.log`.

### Security

CrowdSec is installed automatically — there is no on/off flag, it is part of the base install. The `Security` block tunes it:

| Field | Default | Description |
|---|---|---|
| `CrowdSecEnrollKey` | `""` | Optional. Enrollment key from [app.crowdsec.net](https://app.crowdsec.net) — enrolls this machine in the CrowdSec Console for a hosted dashboard and the community blocklist. Leave empty to run fully local. |
| `BanDurationHours` | `4` | How long a banned IP stays blocked. |
| `ExtraWhitelistIps` | `[]` | Additional IPs or CIDRs that must never be banned. Loopback, all RFC1918 LAN ranges, and this machine's detected public IP are already whitelisted. |
| `AbuseBlocklists` | `true` | Set `false` to skip the Spamhaus + Firehol firewall blocklists. |

Two Windows services are installed: `crowdsec` (detection — parses logs, decides who to ban) and `cs-windows-firewall-bouncer` (enforcement — writes the Windows Firewall rules). **Both must be running**; the engine alone detects but never blocks. Inspect the live state with:

```powershell
& 'C:\Program Files\CrowdSec\cscli.exe' metrics          # lines parsed per source, buckets poured
& 'C:\Program Files\CrowdSec\cscli.exe' alerts list      # what fired
& 'C:\Program Files\CrowdSec\cscli.exe' decisions list   # who is banned right now
```

### Not locking yourself out

Three layers protect against self-lockout, and `scripts/security_unban.ps1` is the recovery tool if you manage it anyway:

- **Whitelisting happens at CrowdSec's enrich stage**, before any scenario sees the event — a whitelisted source can't fill a bucket, so it can never be banned. Covered by default: loopback, every IPv4 address bound to a local interface, all RFC1918 ranges, link-local, **`100.64.0.0/10` (Tailscale)**, and the machine's public IP as detected at install time.
- **The abuse blocklists exclude your own addresses.** Residential IPs do appear in Spamhaus/Firehol (a previous tenant of a dynamic lease, a compromised neighbour in the same `/24`). `update_blocklists.ps1` drops any range that would cover this host's WAN or local addresses.
- **App ports are LAN-scoped**, so a ban on the public path never costs you local admin access.

```powershell
.\scripts\security_unban.ps1                      # show everything currently blocked
.\scripts\security_unban.ps1 -Ip 1.2.3.4          # unban one address
.\scripts\security_unban.ps1 -Ip 1.2.3.4 -Whitelist  # unban + never ban again (persists to config.json)
.\scripts\security_unban.ps1 -All                 # clear every CrowdSec ban
```

Run it from the console, from the LAN, or over Tailscale — all three stay reachable when the public path is blocked. If your WAN IP changes (dynamic DNS), re-run the security installer to refresh the whitelist.

### Port exposure

Only what must be public is public. App ports are bound to `LocalSubnet`, because Caddy proxies them over loopback (which bypasses the firewall entirely) — a world-open rule would just expose each app's own login page on its raw port, **bypassing Caddy's basic-auth and CrowdSec detection at the same time** (CrowdSec only sees what appears in the Caddy access log).

| Port | Exposure | Why |
|---|---|---|
| 80, 443 | **Public** | Caddy — the only intended entry point |
| `Ports.DelugeBT` (default 56881) TCP/UDP | **Public** | BitTorrent peer connections — **forward this on your router** |
| 8989, 7878, 9696, 6767, 5055, 8096 | LAN only | Reached via Caddy on loopback |
| 8191 (Flaresolverr) | **No rule at all** | Binds `127.0.0.1`; loopback needs no rule |
| 58846 (Deluge daemon) | No rule | Localhost-only, not proxied |
| 8112 (Deluge Web UI) | No rule | Proxied by Caddy at `/deluge` (DuckDNS) or `deluge.<domain>` (Cloudflare) |
| 8080 (CrowdSec LAPI) | No rule | Localhost only |

Forward **80, 443, and your `Ports.DelugeBT` port** (default `56881`) on your router.
Set `Ports.DelugeBT` to a random port between 50000–60000 in `config.json` to avoid ISP throttling of well-known BitTorrent ports.

## Warning

**Do not commit `config.json`** to any public repository — it contains credentials and API tokens. It is listed in `.gitignore`.

## Documentation

- [TECHNICAL_OVERVIEW.md](TECHNICAL_OVERVIEW.md) — detailed architecture, script reference, security model, networking
- [LAYER2_GUIDE.md](LAYER2_GUIDE.md) — Layer 2 configuration reference and troubleshooting
