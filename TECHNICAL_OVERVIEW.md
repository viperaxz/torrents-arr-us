# Win-Seedbox — Technical Overview

A fully automated, Swizzin-inspired **Windows media server installer** written entirely in PowerShell.  
It installs, wires together, and secures a complete self-hosted media stack behind a Caddy reverse proxy, all driven by a single `config.json` file and a single `master_install.ps1` entry point.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Feature Summary](#2-feature-summary)
3. [Configuration Schema (`config.json`)](#3-configuration-schema)
4. [Installation Lifecycle](#4-installation-lifecycle)
5. [Script Reference](#5-script-reference)
   - [Entry Points](#entry-points)
   - [Prerequisites & Bootstrap](#prerequisites--bootstrap)
   - [Application Installers](#application-installers)
   - [Layer 1 — Auth Configuration](#layer-1--auth-configuration)
   - [Layer 2 — Application Integration](#layer-2--application-integration)
   - [Helpers & Utilities](#helpers--utilities)
6. [Networking & TLS](#6-networking--tls)
7. [Security Model](#7-security-model)
8. [Dynamic DNS](#8-dynamic-dns)
9. [Quality Automation (Recyclarr)](#9-quality-automation-recyclarr)
10. [Test Suite](#10-test-suite)
11. [End-to-End Sanity Check](#11-end-to-end-sanity-check)

---

## 1. System Architecture

```
Internet
  │
  ▼  :80 / :443
┌──────────────────────────┐
│  Caddy (reverse proxy)   │  ← Windows Service (NSSM), runs as seedbox-svc
│  TLS: Let's Encrypt / ACME│
│  Auth: bcrypt basic-auth │
└────────────┬─────────────┘
             │  localhost only
     ┌───────┴────────────────────────────────┐
     │                                         │
  Subdomain routing (Cloudflare mode)      Path routing (DuckDNS mode)
  jellyfin.domain.com    → :8096           /jellyfin    → :8096
  jellyseerr.domain.com  → :5055           /jellyseerr  → :5055
  sonarr.domain.com      → :8989           /sonarr      → :8989
  radarr.domain.com      → :7878           /radarr      → :7878
  prowlarr.domain.com    → :9696           /prowlarr    → :9696
  deluge.domain.com       → :8112 (web UI)  /deluge      → :8112
  bazarr.domain.com      → :6767           /bazarr      → :6767
  grafana.domain.com     → :3000           /grafana     → :3000  (optional)
  domain.com             → static dashboard
     │
     └── All backend services run as Windows Services under the "seedbox-svc" service account
```

### Application stack

| Application | Role | Port | Process model |
|---|---|---|---|
| **Caddy** | Reverse proxy + TLS termination | 80/443 | NSSM Windows Service |
| **Jellyfin** | Media server / streaming | 8096 | Chocolatey-installed Windows Service |
| **Jellyseerr** | Media request portal (Jellyfin-native) | 5055 | NSSM Windows Service (Node.js, built from source) |
| **Sonarr** | TV show PVR (search, grab, rename) | 8989 | NSSM Windows Service |
| **Radarr** | Movie PVR (search, grab, rename) | 7878 | NSSM Windows Service |
| **Prowlarr** | Indexer manager (syncs to Sonarr/Radarr) | 9696 | NSSM Windows Service |
| **Deluge** | Download daemon (BitTorrent) | 58846 (daemon), 8112 (web) | Two NSSM Windows Services: DelugeDaemon + DelugeWeb |
| **Bazarr** | Subtitle manager (linked to Sonarr/Radarr) | 6767 | NSSM Service (Python) |
| **Flaresolverr** | Cloudflare/DDoS-Guard CAPTCHA bypass proxy | 8191 | NSSM Windows Service |
| **ffmpeg** | Video transcoding (used by Jellyfin) | — | CLI tool, installed via Chocolatey |
| **Recyclarr** | TRaSH Guides quality profile sync | — | CLI one-shot, run during Layer 2 |
| **Grafana** | Observability dashboard (optional) | 3000 | NSSM Windows Service (runs as LocalSystem) |
| **Loki** | Log aggregation backend (bundled with Grafana) | 3100 | NSSM Windows Service (runs as LocalSystem) |
| **Alloy** | Log shipper — tails all service logs and pushes to Loki (bundled with Grafana) | — | NSSM Windows Service (runs as LocalSystem) |
| **CrowdSec** | Intrusion detection — parses logs, issues ban decisions | 8080 (LAPI, localhost only) | MSI Windows Service (LocalSystem) |
| **CrowdSec FW bouncer** | Intrusion prevention — applies decisions to Windows Firewall | — | MSI Windows Service (LocalSystem) |
| **Zurg** | Real-Debrid WebDAV bridge (optional) | — | NSSM Windows Service (runs as seedbox-svc) |
| **rclone** | Mounts Zurg WebDAV as a drive letter via WinFsp (optional) | — | One NSSM Windows Service: `rclone-rd-movies` |

---

## 2. Feature Summary

### Automated Dependency Management
- Bootstraps **Chocolatey** (package manager) if not present, or upgrades it to meet a minimum version.
- Installs and version-checks **NSSM** (Non-Sucking Service Manager) and **vcredist140** as prerequisites.
- Each application installer checks Chocolatey for already-installed packages and skips if present.

### Modular, Skip-safe Installation
- Each application has its own numbered installer script (`02_*.ps1` – `09_*.ps1`).
- A `.locks/` directory tracks which apps are already installed — re-running `master_install.ps1` is idempotent and safe.
- Individual app failures are caught per-app; a broken Bazarr install does not abort Sonarr or Radarr.

### Centralized Configuration
- All runtime values — domain, credentials, ports, paths, media libraries — live in a single `config.json`.
- No hardcoded values in scripts; everything is interpolated from the config at install time.

### Dual DNS / Domain Modes
- **Cloudflare mode**: Each app gets its own `app.yourdomain.com` subdomain. DNS A records are managed via the Cloudflare API.
- **DuckDNS mode**: All apps share a single `*.duckdns.org` domain using URL path routing (`/sonarr`, `/radarr`, etc.). DuckDNS is updated via API.

### Dynamic DNS Updater
- A PowerShell script (`Update-CloudflareDNS.ps1` or `Update-DuckDNS.ps1`) is installed as a **Windows Scheduled Task** that runs every 5 minutes under the `seedbox-svc` account.
- Detects the current public IP via `api.ipify.org` and updates only records that have changed.
- The API token is stored in an ACL-restricted file (`InstallDir\secrets\`), not embedded in the script.

### Caddy Reverse Proxy
- Generated from templates at install time using token substitution.
- Supports three TLS modes: `letsencrypt` (production ACME), `letsencrypt-staging` (staging ACME), and `internal` (Caddy local CA, for LAN-only use).
- Admin credentials are hashed with bcrypt via `caddy hash-password` and embedded in the Caddyfile.
- **Cert cache**: On uninstall the Caddy cert store (`caddy-data/`) is AES-256-CBC encrypted and saved to `cert-cache/caddy-data.enc`. On reinstall, this is decrypted and restored, avoiding unnecessary Let's Encrypt certificate reissuance.

### Reinstall-Safe Data
- **Deluge torrent state**: on uninstall, `Deluge-data\state` is copied to `%LOCALAPPDATA%\win-seedbox\deluge-state-backup`; `07_deluge.ps1` restores it before the service first starts on reinstall.
- **Sonarr / Radarr libraries**: on uninstall, each app's database (`sonarr.db` / `radarr.db`, including WAL sidecars) and `config.xml` are copied to `%LOCALAPPDATA%\win-seedbox\arr-backup\<app>` before `C:\ProgramData` is wiped. `03_sonarr.ps1` / `04_radarr.ps1` restore them before first service start and re-align the restored `config.xml` port and URL base to the current `config.json`, so monitored shows/movies, download history, and settings survive a full reinstall. MediaCover caches and logs are skipped -- they regenerate automatically. Media paths are not auto-migrated: if you change `Paths.TV` / `Paths.Movies`, move existing items to the new root folder via the Series/Movie Editor.

### Service Account Isolation
- Creates a dedicated local Windows user `seedbox-svc` (no admin group, no interactive logon).
- Grants it `SeServiceLogonRight` + `SeBatchLogonRight` via `secedit`.
- All NSSM services run under this account (`ObjectName = .\seedbox-svc`).
- ACLs are applied per-directory: each app only gets access to its own data and media paths.
- The `secrets/` directory has inheritance broken — only `Administrators`, `SYSTEM`, and `seedbox-svc (Read)` can access it.

### Security Layer

Three-phase protection applied by `scripts/12_security.ps1` during the app install phase.

CrowdSec splits into two independent components, and **both are required** — this separation is the single most important thing to understand about this layer:

**Phase 1 — CrowdSec Security Engine** (*detection*). Installed via Chocolatey (`choco install crowdsec`), falling back to the GitHub MSI. It parses logs, runs scenarios, and writes ban *decisions* into a local SQLite database exposed over a Local API (LAPI) on `127.0.0.1:8080`. It never touches the firewall itself.

- **Acquisition** (`C:\ProgramData\CrowdSec\config\acquis.yaml`) declares two datasources: the Caddy JSON access log (`<InstallDir>\logs\caddy-access.log`) and the Windows Security event log filtered to event ID 4625 (failed logon). The Caddy log covers every proxied service in one source — Jellyfin, all *Arr apps, Deluge Web UI, Jellyseerr, dashboard — because everything is behind the reverse proxy.
- **Collections**: `crowdsecurity/caddy` (parses Caddy's default JSON keys, pulls in `base-http-scenarios` for path traversal, CVE probing, bad user agents, HTTP brute force) and `crowdsecurity/windows` (parses the event log, scenario `windows-bf` for RDP/SMB brute force).
- **Whitelist** (`config\parsers\s02-enrich\seedbox-whitelist.yaml`) is the anti-lockout guarantee. It runs at **enrichment stage — before any scenario sees the event** — so a whitelisted source can never fill a leaky bucket and therefore can never be banned, regardless of what it does. It covers loopback, every IPv4 address currently bound to a local interface (guards against hairpin NAT banning the host itself), all RFC1918 ranges, link-local, `100.64.0.0/10` (CGNAT — this is the Tailscale range, the out-of-band way back in), the machine's detected public IP, and anything in `Security.ExtraWhitelistIps`. Entries are split between the `ip:` and `cidr:` lists by whether they contain a `/`, because CrowdSec rejects a CIDR in `ip:` and silently ignores a bare address in `cidr:`.
- **Ban duration** is set by rewriting `config\profiles.yaml` from `Security.BanDurationHours` (default 4h).
- **Console enrollment** is optional via `Security.CrowdSecEnrollKey`.

**Phase 2 — Windows Firewall Remediation Component** (*enforcement*). Installed via `choco install crowdsec-windows-firewall-bouncer` (MSI fallback), registered against the LAPI with `cscli bouncers add`, and configured at `C:\ProgramData\CrowdSec\bouncers\cs-windows-firewall-bouncer\cs-windows-firewall-bouncer.yaml`. It polls the LAPI every 10 seconds and materialises decisions as Windows Firewall BLOCK rules named `crowdsec-blocklist*` (one rule per 1000 IPs, which is why the rule count is not the ban count). Without this component the engine detects attacks and blocks nothing — the installer reports detection and enforcement as separate PASS/FAIL lines for exactly this reason.

> Why this replaced IPBan: IPBan matched a hand-written regex (`"remote_ip":"..."` + `"status":401`) against the Caddy log, which only ever caught HTTP 401s and nothing else — no path traversal, no CVE scanning, no credential stuffing that returns 200/403, and no shared threat intelligence. CrowdSec parses the same log with a maintained parser and a scenario library, and the detect/enforce split means a failure in either half is visible instead of silent.

**Phase 3 — Abuse blocklists** — `update_blocklists.ps1` fetches Spamhaus DROP and EDROP (BGP hijack / bulletproof-hosting ranges) and Firehol Level 1 (mass-scanner / exploit-source CIDRs) and translates them into Windows Firewall BLOCK rules. The initial fetch runs during install; a `Seedbox_Blocklist_Update` scheduled task repeats every 6 hours under SYSTEM to keep the lists current.

> Geoblocking (per-country Windows Firewall BLOCK rules) was removed: enforcing it locally meant loading hundreds of thousands of CIDR ranges into Windows Filtering Platform, which degraded firewall throughput enough to cause connection failures for legitimate traffic from the whitelisted home country itself. If country-level restriction is needed, enforce it at the Cloudflare edge instead.

---

### Two-Phase Configuration ("Layer 1" and "Layer 2")
- **Layer 1** (runs during installation): configures each app's own authentication and base URL.
- **Layer 2** (runs after Layer 1): wires apps together via their REST APIs — connects Prowlarr to Sonarr/Radarr, sets download clients, root folders, naming conventions, media libraries, transcoding, and subtitle settings.

### Quality Automation via Recyclarr + TRaSH Guides
- A bundled `recyclarr.yml` defines curated quality profiles and custom format scoring for Sonarr and Radarr based on the [TRaSH Guides](https://trash-guides.info).
- Recyclarr is downloaded at Layer 2 time and run to push these profiles into Sonarr/Radarr via their APIs.

### Public Indexer Configuration
- Layer 2 auto-adds a curated set of 18+ free public indexers to Prowlarr via its API (1337x, Nyaa.si, The Pirate Bay, and others).
- Indexers are declared in `config.json.example` under `Layer2.Prowlarr.Indexers` as `{Name, DefinitionName}` pairs — the list is fully customizable.
- A `Layer2.MinimumSeeders` threshold (default 1) is applied globally to all indexers.

### Cloudflare CAPTCHA Bypass (Flaresolverr)
- Flaresolverr is installed as an NSSM Windows service running a headless Chromium locally on port 8191.
- Layer 2 registers it with Prowlarr as an indexer proxy via `/api/v1/indexerproxy`, enabling automatic routing of Cloudflare-protected trackers.
- Flaresolverr binds to `127.0.0.1` only — it is never publicly exposed.

### Structured Debug Logging
- `scripts/debug_logger.ps1` provides a shared `Write-DebugLog`/`Initialize-DebugLog` pair dot-sourced by every installer and configure script.
- Controlled by `General.DebugLogging = true` in `config.json`; disabled by default (zero performance impact when off).
- When enabled, writes a timestamped log file to `<InstallDir>\logs\seedbox_debug_<timestamp>.log`.
- Every script logs phase transitions, key variable values (with secrets redacted as `[REDACTED]`), service states, and API call outcomes.

### Media Request Portal (Jellyseerr)
- Jellyseerr is installed as an NSSM service (built from source — Node.js v22 + pnpm) and fully wired to Jellyfin, Sonarr, and Radarr during Layer 1.
- Users browse a Netflix-style catalogue and request movies/TV shows; approved requests are forwarded directly to Radarr/Sonarr for download with no *arr UI access required.
- In DuckDNS mode, the application URL is set to `https://<host>/jellyseerr` automatically; in Cloudflare mode it is `https://jellyseerr.<domain>`.

### Shared User Provisioning
- A `Users` array in `config.json` is the single source of truth. Users are created in **Jellyfin** during Layer 1 and imported into **Jellyseerr** during Layer 2 — no duplicate admin work across apps.
- A `General.DefaultUserPassword` field sets a shared default; per-user `Password` fields override it when present.

### Sonarr → Jellyfin Auto-Repair Hook
- `scripts/sonarr_jellyfin_refresh.py` is a Sonarr Custom Script connection that fires on `OnDownload` events.
- Detects the broken-season-hierarchy bug (Jellyfin scans before TVDB metadata is ready, leaving `Shows/Seasons` returning 0 and the web player crashing) and fixes it by triggering a targeted `Items/{id}/Refresh`.
- Configured in Sonarr `Settings → Connect → Custom Script` pointing at this file.

### Hardware-Accelerated Transcoding (Jellyfin)
- Layer 2 configures Jellyfin's encoding settings for **NVIDIA (NVENC/NVDEC)**, **AMD (AMF)**, or **Intel (QSV)** GPUs via their REST API.
- GPU is declared as a **family slug** in `config.json` under `Layer2.Jellyfin.GPU` (e.g. `"nvidia_ada"`, `"intel_uhd_12th"`, `"amd_rdna3"`).
- `scripts/detect_gpu.ps1` auto-detects the correct family slug from `Win32_VideoController`; prefers dedicated over integrated, highest VRAM wins on ties.
- Legacy vendor names (`"nvidia"`, `"intel"`, `"amd"`) trigger auto-detection at apply time for backward compatibility.
- Each family has a JSON profile in `profiles/gpu/` that maps directly to Jellyfin's encoding API fields.
- 18 GPU family profiles are provided covering the last 10 years across NVIDIA (Maxwell through Blackwell), AMD (GCN4 through RDNA4), and Intel (HD 5xx through Arc), plus a `cpu` software-only fallback.
- Capabilities vary by family: codec support (H.264, HEVC, AV1 encode/decode), HDR tone mapping (CUDA for NVIDIA, VPP for Intel, OpenCL for AMD RDNA2+), 10/12-bit color depth decode, and deinterlacing.

### Automated Subtitle Management (Bazarr)
- Layer 2 connects Bazarr to Sonarr and Radarr via their respective API keys.
- Configures subtitle providers (OpenSubtitles.com, YIFY, Titlovi, gestdown, embedded subtitles; subdl enabled only with a configured API key).
- Creates language profiles: English, Romanian, English + Romanian.
- Enables automatic subtitle download and synchronisation (alass / ffsubsync).

### Observability Stack (Grafana + Loki + Alloy)
- Installed when `Apps.Grafana = true` (off by default). Can also be added post-install via `grafana_enable.ps1`.
- **Loki** — log aggregation backend on port 3100 (localhost only); 30-day retention, TSDB schema, embedded compactor; runs as a NSSM service under LocalSystem.
- **Alloy** — official successor to Promtail; tails structured logs from all seedbox services and pushes them to Loki. Per-service pipelines handle different log formats: JSON/zap (Caddy), NLog pipe-delimited (Sonarr/Radarr/Prowlarr), logrus logfmt (CrowdSec engine), pipe-delimited (firewall bouncer), Serilog with timezone offset (Jellyfin), Python logging (Bazarr/Flaresolverr), Winston with ANSI codes (Jellyseerr), Deluge log format. Jellyfin is forced to a fixed log filename (`jellyfin.log`) so Alloy can tail it reliably on Windows.
- **Grafana** — resolves the latest stable version from `grafana.com/api/grafana/versions/stable` at install time; pre-provisioned with a Loki data source and seedbox dashboard JSON files from `scripts/grafana-dashboards/`; admin credentials match `General.AdminUsername/Password`; analytics and update checks disabled; Caddy route added and DNS updater patched automatically.

### Real-Debrid Integration (Zurg + rclone)
- Enabled when `Apps.RealDebrid = true` and `RealDebrid.ApiKey` is set.
- **Zurg** (`scripts/15_zurg.ps1`) — downloads the latest release from `debridmediamanager/zurg-public`; generates `config.yml` pointing at the RD API; creates an NSSM service under `seedbox-svc`. The rclone mount uses `zurg:__all__` to expose all torrents at the drive root — Jellyfin classifies movies vs shows by filename pattern.
- **rclone** (`scripts/16_rclone.ps1`) — installs WinFsp (required for FUSE-style mounts on Windows) via Chocolatey; downloads rclone from GitHub; creates one NSSM service: `rclone-rd-movies` mounts `zurg:__all__` at `<MountLetter>:\` (default `R:\`). TV shows are not provisioned as a separate mount because Zurg's WebDAV layer cannot reliably separate shows from movies — Jellyfin classifies the mounted content by filename pattern instead.
- **Lean library flags** — `Layer2.Jellyfin.MediaLibraries` entries accept an optional `Lean` object with three independent booleans: `DisableVideoExtraction` (skips chapter image extraction and trickplay, always recommended for remote content), `DisableMetadata` (skips TMDb fetchers), `DisableImages` (skips poster/backdrop downloads).
- **Config additions** — `RealDebrid.ApiKey`, `RealDebrid.MountLetter` (default `"R"`).

### Optional LLM Reverse Proxy (bring-your-own backend)
- Enabled by `LLM.Enabled = true` in `config.json`; the project **never installs or manages the LLM itself** — the user runs the backend (Strata, Ollama, LM Studio, or any OpenAI-compatible server) separately, bound to loopback.
- `01_webserver.ps1` renders a `llm.<domain>` server block (Cloudflare mode) or a `/llm/v1` API path (DuckDNS mode) pointing at `LLM.BackendHost:LLM.BackendPort` (default `127.0.0.1:8081` — port 8080 is CrowdSec LAPI's).
- When `LLM.ApiKey` is set, Caddy requires `Authorization: Bearer <key>` on the API path (phone apps don't speak basic auth). When `LLM.ExposeUi = true` (Cloudflare mode), the backend UI is proxied behind Caddy `basicauth` using the admin credentials.
- **Strata note**: if the backend is Strata and its UI is exposed, add the published URL to the Strata config's `cors_origins` (e.g. `https://llm.example.com`) — otherwise the server refuses the browser page's chat requests. Caddy forwards the browser's `Origin`, so the UI path is only usable once that origin is trusted.
- The LLM subdomain is added to the Cloudflare DNS updater and the cert-cache domain list, and the dashboard gets a card (Cloudflare mode). `collect_status.ps1` probes `<BackendHost>:<BackendPort>/health` and reports the LLM in the service list.

### Server Status Monitoring
- `scripts/13_status.ps1` registers `Seedbox_Status_Collector` as a SYSTEM scheduled task that repeats every 5 minutes.
- `scripts/collect_status.ps1` collects: system uptime and memory usage, per-drive free/used/total space, service running states for all seedbox services, active and waiting Deluge download counts, and security event counts.
- Output is written as `dashboard/current_status.json` — served statically by Caddy and consumed by the dashboard front-end UI.

### Prowlarr Private Tracker Support
- Each entry in `Layer2.Prowlarr.Indexers` now supports an `Enabled: bool` field (defaults to `false`); indexers where `Enabled = false` are silently skipped during Layer 2 — the list in `config.json.example` includes 20+ public and private trackers, all disabled by default.
- Private trackers with authentication accept a per-indexer `Credentials` object: FileList (Username + Passkey), IPTorrents (Cookie + UserAgent), RuTracker (Username + Password), TorrentLeech (Username + Password + Alt2FAToken).
- Each indexer can also declare `SeedRules: {Ratio, SeedTimeMinutes}` which is applied to Prowlarr's per-indexer seed criteria.

### Static Dashboard
- A static HTML dashboard (`dashboard/index.html`) is generated from `templates/dashboard.html.template` at install time.
- Displays clickable app cards for each enabled application, with URLs dynamically generated for the active domain mode.
- Served by Caddy at the root domain (Cloudflare mode: `domain.com`; DuckDNS mode: `domain.duckdns.org/`) behind `basicauth`.
- The dashboard JavaScript polls `current_status.json` to display live service states, drive usage, and download activity.

### Complete Uninstaller
- `master_uninstall.ps1` reverses every installation step:
  1. Kills stray Python (Bazarr) processes.
  2. Backs up the Caddy cert store to `cert-cache/caddy-data.enc` (AES-256 encrypted) and the Deluge torrent state to `%LOCALAPPDATA%\win-seedbox\deluge-state-backup`.
  3. Removes all NSSM services (including Grafana, Loki, Alloy, Zurg, rclone mounts if installed).
  4. Unregisters scheduled tasks (DNS updater, blocklist refresh, status collector, update checker).
  5. Removes Windows Firewall rules.
  6. Backs up the Sonarr/Radarr databases + `config.xml` to `%LOCALAPPDATA%\win-seedbox\arr-backup` (restored automatically by `03_sonarr.ps1` / `04_radarr.ps1` on reinstall), then deletes app data (`C:\ProgramData\*`).
  7. Removes installation binaries from `InstallDir`.
  8. Uninstalls Chocolatey packages (`caddy`, `jellyfin`, `deluge`, `ffmpeg`, `python312`, `winfsp` if present).
  9. Removes the `seedbox-svc` local account.
  - Preserves media files (downloads, movies, TV) and Chocolatey/NSSM themselves.
  - Preserves Deluge torrent state and Sonarr/Radarr libraries via automatic backup/restore.

---

## 3. Configuration Schema

**`config.json`** (based on `config.json.example`):

```json
{
  "General": {
    "DomainMode":             "cloudflare" | "duckdns",
    "TlsMode":                "letsencrypt" | "letsencrypt-staging" | "internal",
    "TlsEmail":               "your@email.com",
    "DebugLogging":           false,                  // set true to enable structured debug log
    "Domain":                 "example.com",          // Cloudflare mode
    "CloudflareApiToken":     "...",                  // Cloudflare mode
    "DuckDnsDomain":          "myhome.duckdns.org",  // DuckDNS mode
    "DuckDnsToken":           "...",                  // DuckDNS mode
    "AdminUsername":          "admin",
    "AdminPassword":          "...",                  // Caddy bcrypt + app forms auth
    "ServiceAccountPassword": "...",                  // seedbox-svc Windows account
    "DefaultUserPassword":    "Welcome1!",            // shared default password for Users list
    "InstallDir":             "C:\\MediaServer"
  },
  "Apps": {
    "Jellyfin": true, "Sonarr": true, "Radarr": true, "Prowlarr": true,
    "Deluge": true, "Ffmpeg": true, "Bazarr": true, "Flaresolverr": true,
    "Jellyseerr": true,
    "Grafana": false,     // Grafana + Loki + Alloy observability stack
    "RealDebrid": false   // Zurg + rclone Real-Debrid mount
  },
  "RealDebrid": {
    "ApiKey":      "...",  // Real-Debrid API key
    "MountLetter": "R"     // movies on R:\, shows on S:\
  },
  "LLM": {
    "Enabled":      false,       // publish an externally managed LLM via Caddy
    "Subdomain":    "llm",       // Cloudflare-mode subdomain
    "BackendHost":  "127.0.0.1",  // LLM stays loopback-bound; Caddy is the only exposure
    "BackendPort":  8081,         // NOT 8080 (CrowdSec LAPI)
    "ApiKey":       "",          // optional Bearer gate on /v1/*
    "ExposeUi":     true          // also proxy the UI (Caddy basicauth)
  },
  "Ports": {
    "Jellyfin": 8096, "Sonarr": 8989, "Radarr": 7878,
    "Prowlarr": 9696, "Deluge": 58846, "DelugeWeb": 8112, "Bazarr": 6767,
    "Flaresolverr": 8191, "Jellyseerr": 5055
  },
  "Users": [
    { "Username": "alice" },             // per-user Password overrides DefaultUserPassword
    { "Username": "bob", "Password": "..." }
  ],
  "Paths": {
    "Downloads": "C:\\MediaServer\\Downloads",
    "Movies":    "C:\\MediaServer\\Media\\Movies",
    "TV":        "C:\\MediaServer\\Media\\TV"
  },
  "Layer2": {
    "MinimumSeeders": 1,
    "PublicTrackerSeedRatio": 1.0,
    "Sonarr":  { "DownloadClients": [...], "RootFolders": [...] },
    "Radarr":  { "DownloadClients": [...], "RootFolders": [...] },
    "Prowlarr": {
      "Indexers": [
        // Public trackers — set Enabled: true to add to Prowlarr
        { "Name": "1337x",          "DefinitionName": "1337x",        "Enabled": false },
        { "Name": "Knaben",         "DefinitionName": "knaben",       "Enabled": true  },
        { "Name": "Nyaa.si",        "DefinitionName": "nyaasi",       "Enabled": false },
        { "Name": "The Pirate Bay", "DefinitionName": "thepiratebay", "Enabled": false },
        // ... 20+ total; full list in config.json.example
        // Private trackers — requires Credentials
        {
          "Name": "FileList", "DefinitionName": "FileList.io", "Enabled": false,
          "Credentials": { "Username": "", "Passkey": "" },
          "SeedRules": { "Ratio": 1.0, "SeedTimeMinutes": 4320 }
        },
        {
          "Name": "TorrentLeech", "DefinitionName": "torrentleech", "Enabled": false,
          "Credentials": { "Username": "", "Password": "", "Alt2FAToken": "" },
          "SeedRules": { "Ratio": 1.0, "SeedTimeMinutes": 1440 }
        }
      ]
    },
    "OpenSubtitles": { "Username": "", "Password": "" },
    "Bazarr":  { "TitloviUsername": "", "TitloviPassword": "" },
    "Jellyfin": {
      "GPU": "nvidia_ada" | "nvidia_ampere" | "intel_uhd_12th" | "intel_arc" | "amd_rdna3" | ... | "",
      "MediaLibraries": [
        { "Name": "Movies",    "Path": "...", "Type": "movies"  },
        { "Name": "TV Shows",  "Path": "...", "Type": "tvshows" },
        // Real-Debrid lean libraries (optional)
        {
          "Name": "RD Movies", "Path": "R:\\", "Type": "movies",
          "Lean": {
            "DisableVideoExtraction": true,  // skip chapter images + trickplay
            "DisableMetadata":        false, // set true to skip TMDb fetchers
            "DisableImages":          false  // set true to skip posters/backdrops
          }
        }
      ]
    }
  }
}
```

---

## 4. Installation Lifecycle

```
master_install.ps1
│
├── [FATAL] 00_prerequisites.ps1       Bootstrap Chocolatey, install NSSM + vcredist140
├── [FATAL] 00_service_account.ps1     Create seedbox-svc, grant service logon rights
├── [FATAL] 01_webserver.ps1           Install Caddy, generate Caddyfile, configure DNS updater, start service
│
├── [per-app, non-fatal]
│   ├── 02_jellyfin.ps1                Install Jellyfin, write network.xml, start service
│   ├── 03_sonarr.ps1                  Download from GitHub, extract, create NSSM service
│   ├── 04_radarr.ps1                  Download from GitHub, extract, create NSSM service
│   ├── 05_prowlarr.ps1                Download from GitHub, extract, create NSSM service
|   |- 07_deluge.ps1                  Install via Choco, write auth + core.conf, create DelugeDaemon + DelugeWeb services
│   ├── 08_ffmpeg.ps1                  Install via Choco (Jellyfin transcoding dependency)
│   ├── 09_bazarr.ps1                  Install Python 3.12, download Bazarr, pip install, create service
│   ├── 10_flaresolverr.ps1            Download from GitHub, extract, create NSSM service (HOST=127.0.0.1)
│   ├── 11_jellyseerr.ps1              Build from source (Node 22 + pnpm 10), create NSSM service, port 5055
│   ├── 12_security.ps1               CrowdSec engine + Windows Firewall bouncer, abuse blocklists fetch
│   ├── 13_status.ps1                 Register Seedbox_Status_Collector scheduled task, run initial collection
│   ├── 14_grafana.ps1                [if Apps.Grafana] Download + install Grafana, Loki, Alloy; provision data source + dashboards; patch Caddyfile
│   ├── 15_zurg.ps1                   [if Apps.RealDebrid] Download Zurg, generate zurg.yml, create NSSM service
│   └── 16_rclone.ps1                 [if Apps.RealDebrid] Install WinFsp, download rclone, create mount service (movies)
│
├── [Layer 1 — Auth, per-app]
│   ├── configure_layer1_jellyfin.ps1       Run startup wizard via API, create admin + Users list, add media libraries
│   ├── configure_layer1_sonarr.ps1         Set Forms auth + credentials via API (with rollback on failure)
│   ├── configure_layer1_radarr.ps1         Set Forms auth + credentials via API (with rollback on failure)
│   ├── configure_layer1_prowlarr.ps1       Set Forms auth + credentials via API (with rollback on failure)
|   |- configure_layer1_deluge.ps1         Verify daemon RPC + Web UI, print download client settings
│   ├── configure_layer1_bazarr.ps1         Set Forms auth via Bazarr settings API
│   └── configure_layer1_jellyseerr.ps1     Jellyfin auth, initialize flag, applicationUrl, Sonarr/Radarr connections, defaultPermissions
│
└── master_configure_layer2.ps1
    ├── configure_layer2_jellyfin_libraries.ps1    Create media libraries, trigger scan
    ├── configure_layer2_jellyfin_transcoding.ps1  Apply GPU transcoding profile (NVIDIA/Intel)
    |- configure_layer2_sonarr.ps1         Root folders, Deluge download client, naming scheme (TRaSH)
    |- configure_layer2_radarr.ps1         Root folders, Deluge download client, naming scheme (TRaSH)
    ├── configure_layer2_recyclarr.ps1      Download recyclarr.exe, write secrets.yml, run sync
    ├── configure_layer2_flaresolverr.ps1   Register FlareSolverr proxy with Prowlarr via API
    ├── configure_layer2_prowlarr.ps1       Connect Sonarr + Radarr, add configured indexers
    ├── configure_layer2_bazarr.ps1         Connect Sonarr/Radarr, enable providers, create language profiles
    └── configure_layer2_jellyseerr.ps1     Import Jellyfin users into Jellyseerr via POST /api/v1/user/import-from-jellyfin
```

---

## 5. Script Reference

### Entry Points

#### `master_install.ps1`
The top-level installer. Requires elevation (Administrator). Reads `config.json`, validates `DomainMode`, creates required directories, then runs the full installation pipeline in order. App installers are wrapped in `try/catch` so a single failure is logged but does not halt the run. At the end it prints a summary of failed installs and configs. Accepts `-SkipLayer2` to stop after Layer 1.

#### `master_configure_layer2.ps1`
Standalone Layer 2 runner. Can be invoked independently after Layer 1 to reconfigure application integration without reinstalling. Iterates a list of Layer 2 scripts, checks the `Enabled` condition from config, and reports a pass/fail summary.

#### `master_uninstall.ps1`
Full uninstaller with 8 numbered stages (see Feature Summary above). Accepts `-Force` to skip the confirmation prompt. Encrypts and saves the Caddy cert cache before removing services.

#### `test-suite.ps1`
Post-install smoke test. Checks all services are running, all expected ports are listening, Caddy HTTP redirects to HTTPS, API health endpoints respond with correct status codes, and DNS records resolve to the current public IP. Outputs PASS/FAIL/WARN per check with a final count.

---

### Prerequisites & Bootstrap

#### `scripts/00_prerequisites.ps1`
Bootstraps the system before any application is installed.
- If Chocolatey is absent, downloads and runs the official installer.
- If Chocolatey is present but below the minimum required version (`2.0.0`), upgrades it.
- Installs **NSSM** (≥2.24) and **vcredist140** via Chocolatey with version-check logic.
- Refreshes the `$env:Path` after installation so subsequent scripts can find new binaries.

#### `scripts/00_service_account.ps1`
Creates and configures the **`seedbox-svc`** dedicated service account.
- Creates the local user if absent; updates the password if it already exists.
- Removes it from `Administrators` and `Users` groups.
- Grants `SeServiceLogonRight` and `SeBatchLogonRight` by exporting the local security policy via `secedit`, patching the INF file, and reimporting it — handles both updating existing rights entries and injecting missing `[Privilege Rights]` sections.
- Exports two ACL helper functions (`Grant-SeedboxDirAccess`, `Set-SecretsDirAcl`) into the global scope for use by all subsequent scripts.

---

### Application Installers

#### `scripts/01_webserver.ps1`
The most complex installer — sets up the entire public-facing layer.
1. **Cert cache restore**: If `cert-cache/caddy-data.enc` exists and `caddy-data/` is empty, decrypts and restores the Caddy certificate store using `cert_cache_helpers.ps1`.
2. **Caddy install**: Installs via Chocolatey.
3. **DNS updater**: Generates either `Update-CloudflareDNS.ps1` or `Update-DuckDNS.ps1` into `InstallDir`, storing the API token in an ACL-restricted `secrets/` subdirectory. Registers a Windows Scheduled Task (runs every 5 min under `seedbox-svc`) and runs it immediately.
4. **Bcrypt hash**: Runs `caddy hash-password` to generate a bcrypt hash of `AdminPassword` for embedding in the Caddyfile.
5. **Dashboard**: renders `templates/dashboard.html.template` with per-app card HTML and writes `dashboard/index.html`. URLs are generated for the active domain mode; only enabled apps get a card.
6. **Caddyfile**: Renders `templates/Caddyfile_cloudflare.template` or `templates/Caddyfile_duckdns.template` by substituting all `{$TOKEN}` placeholders with real values (ports, domain, bcrypt hash, TLS block, data directory paths).
7. **Caddy service**: Creates an NSSM service running under `seedbox-svc`, opens firewall rules for ports 80 and 443, starts the service, and waits to confirm it is running.
8. **Optional LLM proxy**: when `LLM.Enabled` is true, renders a `llm.<domain>` server block (Cloudflare mode) or `/llm/v1` API path (DuckDNS mode) pointing at `LLM.BackendHost:LLM.BackendPort`, with an optional Bearer-key gate on the API and a basicauth-gated UI; adds the LLM subdomain to the DNS updater, cert-cache domain list, and dashboard cards. The LLM itself is never installed or managed.

#### `scripts/02_jellyfin.ps1`
- Installs Jellyfin via Chocolatey; if the package is already present but the service is missing, forces a reinstall.
- Writes `network.xml` into `C:\ProgramData\Jellyfin\Server\config\` to pre-configure the HTTP port and `BaseUrl` (`""` for subdomain mode, `/jellyfin` for DuckDNS path mode) before first run.
- Switches the Windows service `ObjectName` to `seedbox-svc` after the data directory is created.
- Uses a lock file (`.locks/.jellyfin.lock`) to skip reinstall on subsequent runs.

#### `scripts/03_sonarr.ps1`
- Queries the **GitHub releases API** for the latest `win-x64.zip` asset.
- Caches the zip in `bin/` (keyed by filename — old versions are pruned); avoids re-downloading the same build.
- Extracts to `InstallDir\Sonarr\`, creates an NSSM service with `-nobrowser -data=...` arguments.
- Starts the service and waits up to 90 seconds for `config.xml` to appear (first-run config generation).
- If in DuckDNS mode, stops the service, edits `config.xml` to set `UrlBase=/sonarr`, and restarts.

#### `scripts/04_radarr.ps1`
Identical pattern to `03_sonarr.ps1` but for Radarr. Fetches from `github.com/Radarr/Radarr`, filters for `windows-core-x64` zip, sets `UrlBase=/radarr` in DuckDNS mode.

#### `scripts/05_prowlarr.ps1`
Identical pattern to Sonarr/Radarr. Fetches from `github.com/Prowlarr/Prowlarr`, sets `UrlBase=/prowlarr` in DuckDNS mode.

#### `scripts/07_deluge.ps1`
- Installs `deluge` via Chocolatey, locates `deluged.exe` and `deluge-web.exe`.
- Generates a **cryptographically random 32-char base64 password** (`secrets/deluge_auth.txt`) on first install. Subsequent runs read the existing password.
- Writes Deluge config files (`auth`, `core.conf`, `web.conf`) in the data directory (`Deluge-data/`).
- Creates two NSSM services: `DelugeDaemon` (daemon on port 58846, 127.0.0.1 only) and `DelugeWeb` (web UI on port 8112, 127.0.0.1 only).
- Caddy proxies the Web UI over HTTPS; the daemon port is never directly exposed.
- Opens firewall rules for BitTorrent ports (6881 TCP+UDP), not for the daemon or web ports.

#### `scripts/08_ffmpeg.ps1`
Minimal script. Installs ffmpeg via Chocolatey if not already present. Verifies the installation by running `ffmpeg -version` and printing the output. ffmpeg is required by Jellyfin for software transcoding.

#### `scripts/10_flaresolverr.ps1`
- Downloads the latest `flaresolverr_windows_x64.zip` from GitHub releases into `bin/` (cached by version tag).
- Extracts to `InstallDir\Flaresolverr\`, flattening single-directory zips.
- Creates an NSSM service with `HOST=127.0.0.1` and `PORT=8191` as environment variables — binds only to localhost; never publicly exposed.
- Opens a Windows Firewall rule for port 8191 (TCP inbound), though only Prowlarr accesses it locally.
- Waits up to 60 seconds for the API to respond (Flaresolverr initialises a headless Chromium instance on first start, which takes ~20–30 seconds).
- Uses the standard lock file (`.locks/.flaresolverr.lock`) for idempotency.

#### `scripts/13_status.ps1`
Registers the `Seedbox_Status_Collector` Windows Scheduled Task (every 5 minutes, SYSTEM, hidden) that runs `collect_status.ps1`. Immediately performs an initial collection on install so the dashboard has data on first load. Uses the standard lock file (`.locks/.status.lock`) for idempotency.

#### `scripts/14_grafana.ps1`
Installs the full observability stack in nine phases. Enabled when `Apps.Grafana = true`; skipped otherwise.
1. **Grafana**: resolves the latest stable version from `grafana.com/api/grafana/versions/stable`, probes candidate download URLs (zip and tar.gz, both naming schemes), extracts and flattens the archive.
2. **Loki**: downloads `loki-windows-amd64.exe.zip` from GitHub releases; generates `loki-config.yml` with 30-day retention, TSDB v13 schema, and embedded compactor.
3. **Alloy**: downloads `alloy-windows-amd64.exe.zip` from GitHub releases; generates `alloy-config.alloy` with per-service log pipelines for all seedbox services (Caddy access/server, CrowdSec engine, CrowdSec firewall bouncer, Deluge, Sonarr, Radarr, Prowlarr, Jellyfin, Bazarr, Flaresolverr, Jellyseerr). Overrides Jellyfin's logging config to a fixed-filename `jellyfin.log` (Windows cannot glob-tail date-rolled filenames).
4. **Grafana provisioning**: writes `loki.yaml` data source and `default.yaml` dashboard provider into `Grafana-data/provisioning/`; copies bundled dashboard JSON files from `scripts/grafana-dashboards/` to `Grafana-data/dashboards/`.
5. **NSSM services**: creates and starts `Loki`, `Alloy`, and `Grafana` services (all under LocalSystem). Grafana environment variables injected via `nssm set AppEnvironmentExtra` to set root URL, data paths, admin credentials, and disable analytics/update checks.
6. **Caddyfile patch**: appends a `grafana.domain.com` server block (Cloudflare mode) or injects a `handle /grafana*` rule (DuckDNS mode); reloads Caddy.
7. **DNS updater patch**: adds `"grafana"` to the `$Subdomains` array in `Update-CloudflareDNS.ps1` (Cloudflare mode only).

Also exposed as `grafana_enable.ps1` (root-level) — sets `Apps.Grafana = true` in `config.json` and runs `14_grafana.ps1` directly for post-install addition.

#### `scripts/15_zurg.ps1`
Installs Zurg, the Real-Debrid WebDAV bridge. Enabled when `Apps.RealDebrid = true` and `RealDebrid.ApiKey` is non-empty.
- Downloads the latest Windows amd64 binary from `debridmediamanager/zurg-public` GitHub releases; caches in `bin/`.
- Generates `zurg.yml` from a template with `__all__` mount path (no regex filters — workaround for the `compilePattern()` panic in v0.9.3-final; see memory entry `project_zurg_bug.md`).
- Creates an NSSM service under `seedbox-svc`; waits up to 30 seconds for the WebDAV endpoint to respond.

#### `scripts/16_rclone.ps1`
Installs rclone and creates two NSSM mount services. Enabled when `Apps.RealDebrid = true`.
- Installs **WinFsp** via Chocolatey (required for FUSE-style drive mounts on Windows).
- Downloads rclone from GitHub releases; creates a minimal `rclone.conf` pointing at the Zurg WebDAV endpoint (`http://127.0.0.1:9999`).
- Creates `rclone-rd-movies` service: mounts `zurg:__all__` at `<MountLetter>:\` (default `R:\`).
- The service depends on `Zurg` (via NSSM `DependOnService`) so it starts after Zurg is ready; this dependency is skipped if Zurg is not installed.

#### `scripts/12_security.ps1`
Two-phase security installer (see [Security Layer](#security-layer) in Feature Summary for full design rationale).
- **Phase 1 — CrowdSec engine**: installs via Chocolatey with a GitHub MSI fallback, resolves the Windows service name at runtime (rather than hardcoding it), installs the `crowdsecurity/caddy` and `crowdsecurity/windows` hub collections, then writes three config files: `acquis.yaml` (Caddy access log + Security event log 4625), `parsers/s02-enrich/seedbox-whitelist.yaml` (loopback, RFC1918, public IP, config extras), and `profiles.yaml` (ban duration). Optionally enrolls in the CrowdSec Console. Restarts the service so all three take effect.
- **Phase 2 — Windows Firewall bouncer**: registers a bouncer named `seedbox-windows-firewall` via `cscli bouncers add -o raw` (deleting any stale registration first, so re-runs stay idempotent), installs the component, writes its yaml pointing at `http://127.0.0.1:8080/` with that key, and starts the service. Skipped entirely if Phase 1 did not come up healthy.
- **Phase 3 — Abuse blocklists**: Runs `update_blocklists.ps1` immediately, then registers `Seedbox_Blocklist_Update` as a SYSTEM scheduled task repeating every 6 hours. Skippable via `Security.AbuseBlocklists: false`.

All YAML is written with `[System.IO.File]::WriteAllText` and `UTF8Encoding($false)` — CrowdSec parses YAML with Go's yaml library, which rejects a UTF-8 BOM, and PowerShell 5.1's `Set-Content -Encoding UTF8` emits one. This is the same failure mode documented for Bazarr's `config.yaml`.

The lock file is written **only if the engine came up**, so a failed run retries on the next `master_install.ps1` instead of being skipped as already-installed.

#### `scripts/09_bazarr.ps1`
The most involved installer due to Python dependencies.
- Pins Python to **3.12** (via `python312` Chocolatey package) because pre-built wheels for all Bazarr dependencies exist for `cp312`.
- Downloads `bazarr.zip` from GitHub releases (cached in `bin/`), flattens single-directory zips.
- Runs `pip install webrtcvad-wheels` first; if that fails (no MSVC build tools), it falls back to installing requirements without `webrtcvad` (subtitle sync via `alass` instead of `ffsubsync`).
- Creates an NSSM service running `python.exe bazarr.py --no-update -c <DataDir>`.
- Starts Bazarr and waits up to 120 seconds for `config.yaml` to appear, then waits for the Bazarr API to respond (up to 90 more seconds) before stopping the service. This two-phase wait is required because Bazarr performs multiple `config.yaml` write passes during startup initialization; stopping before the API is up causes the subsequent edit to be overwritten on the next start.
- In DuckDNS mode, stops the service, edits `config.yaml` using `[System.IO.File]::WriteAllText` with `UTF8Encoding($false)` (BOM-free) to set `base_url: /bazarr`, then restarts. `Set-Content -Encoding UTF8` must not be used here — PowerShell 5.1 writes a UTF-8 BOM, which causes Python's YAML parser to reset all settings to defaults on load.

---

### Layer 1 — Auth Configuration

These scripts configure authentication on each application using its own REST API after first run. They run while the application is already running.

#### `scripts/configure_layer1_jellyfin.ps1`
- Waits for Jellyfin's `/System/Info/Public` endpoint (up to 300 seconds).
- If the startup wizard is not yet complete, drives it via API: sets language/region, creates the admin user, marks the wizard complete.
- Authenticates and obtains a token, then sets the server name and adds Movies + TV Shows libraries.

#### `scripts/configure_layer1_sonarr.ps1` / `configure_layer1_radarr.ps1` / `configure_layer1_prowlarr.ps1`
All three follow the same robust pattern:
1. Read the API key from the app's `config.xml`.
2. Wait for the API to respond. In DuckDNS mode the URL prefix (`/sonarr`, `/radarr`, `/prowlarr`) is included in all API calls, because the apps have `UrlBase` set in `config.xml` during installation and only respond to prefixed paths.
3. `GET /api/v3/config/host` (v1 for Prowlarr) to retrieve the current config.
4. Backup `config.xml`.
5. Deep-clone the config, set `authenticationMethod=forms`, `username`, `password`.
6. `PUT` the new config.
7. Restart the service.
8. Verify the change took effect by polling the API.
9. **Rollback** on failure: attempt API-level restore first, fall back to restoring `config.xml` from the backup.

#### `scripts/configure_layer1_deluge.ps1`
- Reads the daemon password from `secrets/deluge_auth.txt`.
- Verifies the daemon RPC endpoint responds (login + method list).
- Waits for the Web UI on port 8112.
- Prints the Sonarr/Radarr download client settings (host, port, password location).

#### `scripts/configure_layer1_bazarr.ps1`
- Reads the API key from Bazarr's `config.yaml` (polls up to 60 seconds).
- Waits for the `/api/system/ping` endpoint.
- Posts form-encoded settings to `/api/system/settings` to set `auth-type=form`, username, and password.

---

### Layer 2 — Application Integration

#### `scripts/configure_layer2_sonarr.ps1`
Connects Sonarr to the rest of the stack:
- **Root folders**: adds configured paths via `/api/v3/rootFolder`, skipping if already present.
- **Download clients**: fetches the Deluge schema from Sonarr's `/api/v3/downloadclient/schema`, deep-clones it, and fills in host/port/password/category. Creates or updates the download client via POST/PUT.
- **Indexer proxies**: attempts to configure Prowlarr as an indexer proxy via `/api/v3/indexerproxy`; gracefully skips if the endpoint is not available (removed in Sonarr v4 — Prowlarr sync is handled by `configure_layer2_prowlarr.ps1` instead).
- **Naming scheme**: applies TRaSH-recommended episode and season folder format strings.
- **Media management**: sets `downloadPropersAndRepacks=doNotPrefer`.

#### `scripts/configure_layer2_radarr.ps1`
Same as Sonarr's Layer 2, adapted for Radarr: `/api/v3/rootFolder`, download client, naming scheme, media management.


#### `scripts/configure_layer2_recyclarr.ps1`
- Downloads `recyclarr.exe` from GitHub if not present in the `recyclarr/` directory.
- Reads Sonarr and Radarr API keys and writes `%APPDATA%\recyclarr\secrets.yml` with base URLs that include the path prefix in DuckDNS mode (e.g., `http://127.0.0.1:8989/sonarr`). In Cloudflare mode the prefix is empty.
- Launches Recyclarr in a hidden process window (required because Recyclarr uses Spectre.Console which calls `SetConsoleMode()` on its stdout handle — this fails when stdout is a pipe).
- After sync completes, finds and tails the newly created debug log, filtering to INFO/WARN/ERROR lines.

#### `scripts/configure_layer2_jellyfin_libraries.ps1`
- Authenticates against the Jellyfin API using admin credentials.
- For each library in `Layer2.Jellyfin.MediaLibraries`: if the library exists, checks that the configured path is present (adds it if missing); if it doesn't exist, creates it with the correct `collectionType`.
- Triggers a full library scan via `/Library/Refresh`.

#### `scripts/configure_layer2_jellyfin_transcoding.ps1`
- Reads the GPU family slug from `Layer2.Jellyfin.GPU` (e.g. `nvidia_ada`, `intel_arc`, `amd_rdna3`). Legacy vendor names (`nvidia`, `intel`, `amd`) trigger `detect_gpu.ps1` auto-detection at apply time.
- Loads the matching profile from `profiles/gpu/<slug>.json`. Falls back to `cpu.json` if the slug is unrecognised or GPU is absent.
- Fetches the current Jellyfin encoding configuration, merges the profile fields into it (preserving unrelated settings), and POSTs the result back.
- 18 profiles ship with the project: NVIDIA (Maxwell through Blackwell), AMD (GCN4 through RDNA4), Intel (HD 5xx through Arc), and a CPU software-only fallback.

#### `scripts/configure_layer2_flaresolverr.ps1`
- Reads the Prowlarr API key from `C:\ProgramData\Prowlarr\config.xml`.
- Fetches Prowlarr's indexer proxy schema (`/api/v1/indexerproxy/schema`) and locates the `FlareSolverr` implementation entry.
- If a FlareSolverr proxy already exists, updates it via PUT; otherwise creates it via POST.
- Sets the `host` field to `http://127.0.0.1:8191` and `requestTimeout` to 60 seconds.
- Performs a final health check against `http://127.0.0.1:8191/` and reports a warning (not a fatal error) if the service is still starting up.

#### `scripts/configure_layer2_prowlarr.ps1`
Connects Prowlarr to Sonarr and Radarr:
- Reads both apps' API keys from their `config.xml` files.
- Uses Prowlarr's `/api/v1/applications` endpoint to register Sonarr and Radarr with `syncLevel=fullSync`.
- If `Layer2.Prowlarr.Indexers` is configured, fetches the indexer schema and adds each indexer by `definitionName`. Applies `Layer2.MinimumSeeders` globally. Handles known error cases gracefully: FlareSolverr-protected indexers (logged as warning, not error), timeouts (logged, not fatal).

#### `scripts/configure_layer2_bazarr.ps1`
Full integration configuration:
- Reads Sonarr and Radarr API keys from their `config.xml` files.
- Connects Bazarr to both via its settings API (form-encoded POST to `$ApiBase/api/system/settings`). In DuckDNS mode `$ApiBase` includes the `/bazarr` prefix; in Cloudflare mode it does not.
- Sets the Sonarr/Radarr base URLs to `/sonarr` and `/radarr` in DuckDNS mode (empty string in Cloudflare mode) so Bazarr's internal HTTP client reaches the correct paths.
- Enables subtitle providers: `opensubtitlescom`, `yifysubtitles`, `embeddedsubtitles`, `gestdown`, plus `titlovi` (with credentials) and `subdl` (with API key). `subsource` is discontinued and never enabled.
- Reads OpenSubtitles.com credentials from `Layer2.OpenSubtitles.Username/Password`; reads Titlovi credentials from `Layer2.Bazarr.TitloviUsername/Password`.
- Creates three language profiles via `/api/system/settings`: English (id=1), Romanian (id=2), English + Romanian (id=3). Each profile item includes the `audio_only_include` field (required since Bazarr v1.5.6 — omitting it causes a `KeyError` 500 on every providers request).
- Sets auto-download defaults: both movies and series use profile 3 (English + Romanian).
- Enables subtitle synchronisation (alass/ffsubsync) without minimum score threshold.

#### `scripts/configure_layer2_jellyseerr.ps1`
Imports Jellyfin users into Jellyseerr so they can log in with their existing credentials:
- Authenticates to Jellyseerr using the admin account (without resending `hostname` — Jellyfin is already registered from Layer 1).
- Calls `GET /api/v1/settings/jellyfin/users` to retrieve Jellyfin user IDs for all usernames in `Config.Users`.
- Skips users that are already imported (checks existing Jellyseerr users first).
- Calls `POST /api/v1/user/import-from-jellyfin` with the list of Jellyfin user IDs — creates matching Jellyseerr accounts in one request. Users log in with their Jellyfin password; no separate Jellyseerr password is needed.

---

### Jellyseerr Installers

#### `scripts/11_jellyseerr.ps1`
Jellyseerr v3.3.0 ships no pre-built Windows binary, so the installer builds from source:
- Downloads Node.js v22 portable zip and pnpm into `bin/` (cached by version).
- Downloads the Jellyseerr source zip from GitHub (also cached).
- Extracts to `InstallDir\Jellyseerr\app\`, installs dependencies with `pnpm install --frozen-lockfile`, then runs `pnpm build` to produce the Next.js production bundle.
- The pnpm/Next.js build writes to stderr; stderr is intentionally not treated as errors (the build succeeds if `exit 0`).
- Creates an NSSM service running `node server.js` with `CONFIG_DIRECTORY`, `PORT`, and `NODE_ENV=production` environment variables set.
- Opens a firewall rule for port 5055. Uses the standard `.locks/.jellyseerr.lock` for idempotency.

#### `scripts/configure_layer1_jellyseerr.ps1`
Drives the full Jellyseerr first-run setup via its REST API (no browser interaction):
1. **Auth**: `POST /api/v1/auth/jellyfin` with `serverType=2` (JELLYFIN) — simultaneously creates the Jellyseerr admin and registers the Jellyfin server connection.
2. **Initialize**: `POST /api/v1/settings/initialize` — sets `public.initialized=true`. Without this, the Next.js app redirects every page to `/setup`.
3. **Application URL**: `POST /api/v1/settings/main` with `applicationUrl` (DuckDNS: `https://<host>/jellyseerr`; Cloudflare: `https://jellyseerr.<domain>`).
4. **Sonarr connection**: `POST /api/v1/settings/sonarr` — fetches the first quality profile from Sonarr's own API to populate the required `activeProfileId` + `activeProfileName` fields; also requires `is4k`, `activeDirectory`, and `enableSeasonFolders`.
5. **Radarr connection**: same pattern; also requires `minimumAvailability` (`"released"`).
6. **Default permissions**: `POST /api/v1/settings/main` with `defaultPermissions=32` (REQUEST only).

---

### Helpers & Utilities

#### `scripts/debug_logger.ps1`
Provides structured, timestamp-stamped debug logging shared by every installer and configure script.
- **`Initialize-DebugLog`**: dot-sourced at the top of each script; reads `General.DebugLogging` from config, creates a single `<InstallDir>\logs\seedbox_debug_<timestamp>.log` file for the session, and prints the log path to the console.
- **`Write-DebugLog`**: two calling conventions — `Write-DebugLog "LEVEL" "message"` (explicit INFO/WARN/ERROR) or `Write-DebugLog "VAR x=$x"` (implicit DEBUG). Identifies the caller from the PowerShell call stack for the log prefix.
- Outputs coloured lines to the console and writes plain-text lines to the log file simultaneously.
- No-ops when `DebugLogging = false`; zero performance overhead when disabled.
- Sensitive values (passwords, tokens) are **never** logged automatically; scripts use `[REDACTED]` when referencing secret fields by name.

#### `scripts/cert_cache_helpers.ps1`
Two functions for encrypting/decrypting the Caddy `caddy-data/` directory tree.
- **`Protect-CaddyData`**: Zips the source directory in memory, generates a 16-byte random PBKDF2-SHA256 salt (100,000 iterations), derives a 256-bit AES key and 128-bit IV, encrypts with AES-256-CBC, and writes `[16-byte salt][ciphertext]` to the destination file.
- **`Restore-CaddyData`**: Reads the salt prefix, re-derives the same key/IV, decrypts, and extracts the zip to the destination directory.
- Used by `01_webserver.ps1` (restore on reinstall) and `master_uninstall.ps1` (backup on uninstall).

#### `scripts/update_blocklists.ps1`
Fetches abuse IP lists and creates Windows Firewall BLOCK rules:
- Downloads Spamhaus DROP and EDROP (BGP hijack / bulletproof-hosting ranges) and Firehol Level 1 (mass-scanner / known-bad CIDRs).
- Parses each list into CIDR ranges, deduplicates, and creates Windows Firewall BLOCK rules (`Seedbox-Abuse-Blocklist*`, batched at 5000 CIDRs per rule) covering all ranges. Current real-world total after dedup is roughly 4,700 — one rule.
- **Bogon filter**: firehol level-1 intentionally ships RFC1918, loopback, CGNAT and link-local because it targets edge routers, where a private source address is bogus. On a host those entries block the local LAN and Tailscale's `100.64/10`, silently killing SMB, discovery, and on-link traffic. They are stripped.
- **Self-exclusion**: any range covering this host's detected public IP or a locally-bound address is dropped. Residential IPs genuinely do appear in these lists, and a blocklist containing your own WAN address locks you out of the entire seedbox.
- **Fail-safe ordering**: the empty-result check runs *before* old rules are removed, so a transient network failure leaves existing protection in place rather than tearing it down and replacing it with nothing.
- **Verified reporting**: the final count is re-queried from the firewall rather than trusted from the creation loop, and the script exits non-zero if no rule is present afterwards. `$ErrorActionPreference` is deliberately `Stop`, not `SilentlyContinue` — a blanket suppression previously hid rule-creation failures behind a green success message.
- Idempotent: removes the old rules before recreating them so they stay current on each run.
- Called directly by `12_security.ps1` at install time and scheduled to run every 6 hours by `Seedbox_Blocklist_Update`.

#### `scripts/security_unban.ps1`
The recovery tool for a self-inflicted ban. Three independent mechanisms can block an inbound IP on this box — CrowdSec decisions (enforced as `crowdsec-blocklist*` rules), the abuse blocklists (`Seedbox-Abuse-Blocklist*`), and legacy `IPBan_*` rules on pre-migration installs — and they are cleared in different ways. The script reports all three, then:
- `-Ip <addr>` removes the CrowdSec decision **and** rebuilds any abuse-blocklist rule that covers the address without it (a plain `cscli decisions delete` would not touch the static lists).
- `-Ip <addr> -Whitelist` additionally persists the address to `Security.ExtraWhitelistIps` in `config.json`, writing it back BOM-free.
- `-All` clears every CrowdSec decision; the bouncer reconciles the firewall within ~10 seconds.

Intended to be run locally — console, LAN, or Tailscale — all of which stay reachable by design when the public path is blocked.

#### Firewall exposure model
Only Caddy (80/443) and the BitTorrent peer port (6881) are open to the internet. Application ports (`8989`, `7878`, `9696`, `6767`, `5055`) are created with `-RemoteAddress LocalSubnet`: Caddy reaches them over loopback, which is exempt from Windows Firewall, so a world-open rule buys nothing and costs two things at once — it exposes each app's own login page on its raw port, **bypassing Caddy's basic-auth**, and it bypasses CrowdSec, whose only HTTP datasource is the Caddy access log. Flaresolverr gets **no rule at all**: it is started with `HOST=127.0.0.1`, so an inbound rule would only expose a headless Chromium that performs arbitrary fetches on request; `10_flaresolverr.ps1` actively removes the rule left behind by older installs.

#### `scripts/collect_status.ps1`
Collects server health metrics and writes them as `dashboard/current_status.json`:
- **System**: uptime (hours), memory used/total (GB), memory percent.
- **Drives**: per-drive letter free/used/total GB and percent used.
- **Services**: running state for all seedbox services (Caddy, Sonarr, Radarr, Prowlarr, Jellyfin, Deluge, Bazarr, Flaresolverr, Jellyseerr, Zurg, rclone-rd-movies, Grafana, Loki, Alloy).
- **Downloads**: active and waiting Deluge download counts via RPC.
- **Security**: Windows Firewall rule count for the abuse blocklist.
Runs every 5 minutes via `Seedbox_Status_Collector` (SYSTEM scheduled task registered by `13_status.ps1`). No credentials or secrets are written to the output JSON.

#### The update system

Updates follow a **notify-then-apply** model with a single source of truth per side:

- **Remote truth**: `versions.json` at the repo root (published via GitHub raw). It pins the recommended version, source, and asset pattern per app, plus optional `security` / `securityNote` flags. A maintainer tool (`scripts\bump_versions.ps1`) refreshes it from upstream releases, and a weekly GitHub Actions workflow opens a PR with the bumps.
- **Local truth**: `<InstallDir>\.locks\installed_versions.json` (the "ledger"), written by every installer via `Set-InstalledVersion` and maintained by the update scripts. Legacy `.locks\*.lock` files still exist for install idempotency and are kept in sync on successful updates.

Building blocks:

- `scripts\update_common.ps1` — shared helpers: `Read-InstalledLedger` / `Set-InstalledVersion`, tolerant `Compare-Versions`, data-driven `Get-UpdatePlan` (states: `current`, `update`, `manual`, `notinstalled`, `unknown`, `unresolved`), `Invoke-GitHubReleaseDownload`, `Invoke-ChocoUpgrade`, `Swap-AppDirectoryWithRollback`, `Swap-SingleExeWithRollback`, `Detect-InstalledVersion` (self-heals legacy lock values like timestamps or `installed`).
- `scripts\update_<App>.ps1` — one script per app (18 total). Contract: `-Version -InstallDir -BinDir -Config [-WhatIf]`, returns one result object (`App/Status/Installed/Target/Detail`), writes the ledger only after a verified success. Dir swaps for Sonarr/Radarr/Prowlarr/Flaresolverr/Grafana; exe-only swaps for Zurg/rclone/Loki/Alloy (config files live next to the binary); Bazarr re-runs `pip install -r requirements.txt` after the swap; Jellyseerr rebuilds from source via pnpm; choco upgrades for Jellyfin (re-applies the `seedbox-svc` service account), Deluge, ffmpeg, Caddy (reloads the Caddyfile), CrowdSec + bouncer; Recyclarr replaces the CLI exe. NSSM and Python312 are deliberately manual.
- `master_update.ps1` — thin data-driven orchestrator: self-update via git pull, remote manifest fetch, ledger migration, `Get-UpdatePlan`, then per-app script invocation with the summary table. Supports `-AutoApprove`, `-App <Name>`, `-WhatIf`.
- `box.ps1` — `box check` (read-only plan) and `box update` (auto-elevates) both consume the same plan; no hardcoded app list exists anywhere.

#### `scripts/check_updates.ps1`
Daily background update checker registered as the `win-seedbox Update Check` scheduled task (runs at 10:00 AM under the interactive user).
- Fetches the remote `versions.json` from the GitHub raw URL defined in the local `versions.json`.
- Builds the same `Get-UpdatePlan` as `box check` and `master_update.ps1` (all apps, not a hardcoded subset), self-healing unknown ledger entries via `Detect-InstalledVersion`.
- If the project itself is a git repository, fetches `origin/main` and compares HEAD SHA to detect script-level updates.
- Shows a Windows toast notification (with `msg.exe` fallback) and always writes `dashboard\update_notification.json`; never applies updates automatically.

#### `scripts/sonarr_jellyfin_refresh.py`
A Sonarr Custom Script connection that fires on `OnDownload` events to fix a timing-dependent hierarchy bug in Jellyfin.
- **Problem**: Sonarr fires its Jellyfin update notification immediately at import. Jellyfin scans the file instantly, but TVDB metadata for a brand-new series is still downloading — the season ends up detached from the series and `Shows/Seasons` returns 0, crashing the web player.
- **Fix**: after a 45-second delay (allowing the initial scan to settle), authenticates against Jellyfin, checks `Shows/{seriesId}/Seasons`, and triggers `Items/{id}/Refresh` with `MetadataRefreshMode=FullRefresh` if the count is 0.
- Reads connection settings from `config.json` automatically; requires no additional configuration beyond pointing Sonarr at the script file (`Settings → Connect → Custom Script`).
- Handles `Test` events cleanly; exits silently on non-Download events.
- A matching `sonarr_jellyfin_refresh.cmd` wrapper is included for Windows compatibility (Sonarr requires `.cmd`/`.bat` or `.exe` on Windows; it invokes `python sonarr_jellyfin_refresh.py %*`).

---

## 6. Networking & TLS

### Caddyfile Templates

Two templates exist depending on domain mode:

| Template | Mode | Routing |
|---|---|---|
| `Caddyfile_cloudflare.template` | Cloudflare | Each app on its own subdomain (`app.domain.com`) |
| `Caddyfile_duckdns.template` | DuckDNS | All apps on path prefixes (`domain/app`) |
| `Caddyfile.template` | Generic | Not currently used by installer |

When `LLM.Enabled` is set, an extra `{$LLM_BLOCK}` placeholder renders the LLM proxy rules: `llm.<domain>` with a `/v1` bearer gate and basicauth-gated UI in Cloudflare mode; API-only `/llm/v1` in DuckDNS mode (the backend UI is not exposed in path mode).

The Cloudflare Caddyfile illustrates the security split:
- The **dashboard** (`domain.com`) is behind `basicauth`.
- **Jellyfin** is exempt from basic auth (has its own authentication).
- **Sonarr/Radarr/Prowlarr/Bazarr** are accessible after their own forms-auth.
- **Deluge Web UI** is behind `basicauth`; Deluge handles its own daemon authentication internally.

**Caddy access logging**: Both templates include a `log { output file ... format json }` block in every server block, writing JSON-formatted request logs to `<InstallDir>/logs/caddy-access.log`. The log is consumed by CrowdSec's `crowdsecurity/caddy-logs` parser, which expects exactly these default JSON keys — changing `format json` to another formatter would silently break detection for every proxied service at once. Log rotation is handled by Caddy directly (10 MB roll size, 3 files kept).

**Jellyseerr DuckDNS routing note**: Jellyseerr v3.3.0 has no `basePath` support — Next.js server-side redirects hardcode paths like `/login`, `/setup`, `/requests` without any prefix. The DuckDNS template therefore includes two layers of Caddy rules: `handle_path /jellyseerr*` (strips the prefix for the main entry point) and explicit `handle /login*`, `handle /setup*`, etc. blocks for all page routes the server may redirect to. The static asset paths (`/_next*`, `/api*`, `/imageproxy*`, `/avatarproxy*`) are also routed directly because the browser requests them without the `/jellyseerr` prefix after the first page load.

### TLS Modes

| `TlsMode` | Caddyfile block | Use case |
|---|---|---|
| `letsencrypt` | `tls email@example.com` | Production — public ACME via HTTP-01 |
| `letsencrypt-staging` | `tls email { ca staging-url }` | Testing ACME flow without hitting rate limits |
| `internal` | `tls internal` | LAN-only — Caddy self-signed CA (requires `caddy trust`) |

---

## 7. Security Model

| Concern | Mechanism |
|---|---|
| **Service isolation** | `seedbox-svc` local account, no admin group, no interactive logon |
| **Least-privilege filesystem** | ACL grants per app data directory; media paths are `ReadAndExecute` only |
| **Secret storage** | API tokens in `InstallDir\secrets\` with inheritance broken; only `seedbox-svc (Read)` + Administrators |
| **Deluge daemon** | Binds `127.0.0.1` only; random 32-char password; only Caddy proxies the Web UI |
| **Caddy auth** | bcrypt-hashed credentials (`caddy hash-password`) embedded in Caddyfile |
| **App auth** | Forms-based authentication configured programmatically on all *arr apps and Bazarr |
| **Cert persistence** | `caddy-data.enc` is AES-256-CBC encrypted with the AdminPassword before storage in the repo |
| **Config protection** | `config.json` is in `.gitignore`; users are warned if the default `ServiceAccountPassword` is unchanged |
| **Intrusion detection (CrowdSec engine)** | Parses the Caddy JSON access log and the Windows Security event log (4625); `crowdsecurity/caddy` + `crowdsecurity/windows` collections cover HTTP attacks and RDP/SMB brute force; LAN ranges and the server's own public IP whitelisted at enrichment stage |
| **Intrusion prevention (CrowdSec firewall bouncer)** | Polls the local LAPI every 10s and materialises ban decisions as Windows Firewall BLOCK rules (`crowdsec-blocklist*`); without it the engine detects but never blocks |
| **Abuse IP blocklists** | Spamhaus DROP/EDROP and Firehol Level 1 CIDRs blocked via Windows Firewall; refreshed every 6 hours by a SYSTEM scheduled task |

---

## 8. Dynamic DNS

Two DNS updater scripts are generated at install time into `InstallDir\`:

### `Update-CloudflareDNS.ps1`
- Reads the Cloudflare API token from `secrets/cloudflare_token.txt`.
- Looks up the current public IP via `api.ipify.org`.
- Queries the Cloudflare API for the zone ID matching the configured domain.
- Iterates over all required subdomains (`""`, `jellyfin`, `sonarr`, `radarr`, `prowlarr`, `deluge`).
- For each: if an A record exists and the IP differs, issues a PUT; if no record exists, issues a POST.
- Only updates records that have changed.

### `Update-DuckDNS.ps1`
- Reads the DuckDNS token from `secrets/duckdns_token.txt`.
- Calls the DuckDNS update URL with the current IP.

Both are registered as a Windows Scheduled Task (`Seedbox_Cloudflare_Updater` / `Seedbox_DuckDNS_Updater`) that repeats every 5 minutes indefinitely, running under `seedbox-svc`.

---

## 9. Quality Automation (Recyclarr)

**`recyclarr/recyclarr.yml`** — a fully configured [Recyclarr v8](https://recyclarr.dev) config using [TRaSH Guides](https://trash-guides.info) `trash_ids`.

### Sonarr profiles
| Profile | Target | Fallback |
|---|---|---|
| `WEB-1080p` | WEB-DL / WEBRip 1080p | 720p WEB |
| `WEB-2160p` | WEB-DL / WEBRip 4K | 1080p WEB |
| `Remux-2160p` | Bluray 4K Remux | WEB-2160p → Bluray 1080p Remux |

### Radarr profiles
| Profile | Target | Fallback |
|---|---|---|
| `Radarr - 4K WEB-DL` | WEB-DL 4K | 1080p WEB |
| `Radarr - 4K Remux` | Remux 4K | WEB-2160p → Remux-1080p |

### Custom format scoring highlights
- **Blocked**: BR-DISK, LQ, x265 (HD), Extras, Upscaled, 3D → score `-10000`
- **Release group tiers**: WEB Tier 01 (+1700) → Tier 02 (+1250) → Tier 03 (+1000)
- **Streaming sources**: NF, AMZN, ATVP, DSNP, HBO, HULU, MAX → +15
- **HDR**: Dolby Vision (+15), HDR10+ (+10), HDR (+5)
- **Audio** (4K profiles): TrueHD Atmos (+5000), DTS:X (+4500), DD+ Atmos (+3000), TrueHD (+2750), DTS-HD MA (+2500), DD+ (+1750)
- **IMAX Enhanced** (Radarr only): +800

---

## 10. Test Suite

**`test-suite.ps1`** — an administrator-required validation script that can be run after installation.

Checks performed:
1. **Services**: Caddy, Sonarr, Radarr, Prowlarr, Jellyfin (tries 3 service name variants), Deluge — all must be `Running`.
2. **Listening ports**: 80, 443, and all configured app ports must be bound.
3. **TLS redirect**: HTTP request to port 80 must return a redirect to HTTPS.
4. **API health**: `GET /api/v3/system/status` for Sonarr/Radarr/Prowlarr with API key authentication must return HTTP 200.
5. **DNS resolution** (skipped with `-Quick`): configured subdomains must resolve to the current public IP.

Output uses `[PASS]` / `[FAIL]` / `[WARN]` lines per check, with a final summary count.

---

## 11. End-to-End Sanity Check

**`scripts/sanity_check.py`** — a Python script that drives the full media pipeline via REST APIs after install, verifying each app is correctly wired to the next.

Unlike `test-suite.ps1` (which only confirms services are running and ports are open), the sanity check performs real operations — adding content, triggering searches, and polling for results — catching misconfiguration that the installer cannot detect.

### Configuration

Config is loaded from three sources in priority order:
1. `scripts/sanity_config.json` — non-secret defaults (movie/series titles, poll timeouts)
2. `config.json` — admin credentials, ports, paths (auto-loaded from `../config.json`)
3. Environment variables — `ADMIN_USER`, `ADMIN_PASS`, `SANITY_MOVIE`, `SANITY_SERIES`, `DOMAIN_MODE`, `INSTALL_DIR`

API keys are auto-discovered from installed app config files (`C:\ProgramData\*\config.xml`, Bazarr's `config.yaml`, and the Deluge password file).

Default test targets: *The Godfather* (1972) for Radarr and *Friends* S01 for Sonarr — configurable via `sanity_config.json`.

### Steps

| Step | Name | What it checks |
|---|---|---|
| 0 | Infrastructure | Service states, API health for all apps, Prowlarr→Sonarr/Radarr registration, FlareSolverr proxy, root folders, download clients, quality profiles, disk space |
| 1 | Radarr | Adds a movie, triggers `MoviesSearch`, polls history/queue for a `grabbed` event; falls back to interactive release search if auto-grab doesn't fire within 60 s |
| 2 | Sonarr | Adds a series, pins only S01E01 as monitored (prevents season-wide grabs), triggers `EpisodeSearch`, polls for grab; same fallback |
| 3 | Deluge | Polls `core.get_torrents_status` every 5 s up to `DownloadPollSecs` (default 300 s) for an active download |
| 4 | Jellyfin | Polls `GET /Users/{id}/Items` and `GET /Shows/{seriesId}/Episodes` every 30 s up to `ImportPollSecs` (default 1800 s) for the downloaded media; auto-runs the season hierarchy repair if needed |
| 5 | Bazarr | Checks health, Sonarr/Radarr connection status, provider count, and wanted subtitle queue |

Steps 4 and 5 are non-fatal (import/download timing is unpredictable). Steps 0–3 return exit code 1 on failure.

### Usage

```bash
# Run all steps (default)
python scripts/sanity_check.py

# Infrastructure check only — fast, no changes made
python scripts/sanity_check.py --steps 0

# Run steps 1-3, skip cleanup (leave added content for inspection)
python scripts/sanity_check.py --steps 1,2,3 --no-cleanup

# Re-check Jellyfin/Bazarr after downloads complete
python scripts/sanity_check.py --steps 4,5
```

### Cleanup

After the run, the script removes any movie/series it added from Radarr/Sonarr and cancels the corresponding Deluge downloads. Pass `--no-cleanup` to skip this (useful when debugging a failed run). Content that already existed in the library before the run is never deleted.

### Dependencies

`requirements_sanity.txt` — only `requests>=2.31.0` is required. The script uses direct API calls, not a browser — no Selenium or ChromeDriver needed.
