# win-seedbox Roadmap

RULE FOR AI 1: ALL THE FEATURES WILL BE IMPLEMENTED ON THEIR OWN BRANCHES!!!!!!!!!!!!!!
RULE FOR AI 2: COMMIT ONLY AFTER A FULL UNINSTALL -> DO CHANGES -> FULLY INSTALL -> UNINSTALL CYCLE. YOU CAN DO AS MANY CYCLES YOU WANT, BUT DO NOT COMMIT UNLESS YOU HAVE A FLAWLESS CYCLE. YOU, AI, RUN THE SCRIPTS!

## Upcoming

### Priority 0 — LLM reverse proxy (bring-your-own LLM)

Expose an externally managed LLM server (Strata, Ollama, LM Studio, any OpenAI-compatible backend) over the internet through the project's Caddy setup — **without the project installing or managing the LLM itself**. The user installs and runs the LLM separately; the project only publishes it.

Rationale: the current `llm.viperax.org` / Open WebUI setup is a manual, hand-edited Caddyfile addition that is wiped on every reinstall. This feature makes it a first-class, config-driven, reinstall-safe part of the seedbox.

Design (final):

- **Config** — new `LLM` section in `config.json.example`, disabled by default:
  - `Enabled: false`
  - `Subdomain: "llm"` — Cloudflare-mode subdomain
  - `BackendHost: "127.0.0.1"` — backend always stays loopback-bound; Caddy is the only exposure
  - `BackendPort: 8081` — deliberately NOT 8080 (CrowdSec LAPI owns 8080)
  - `ApiKey: ""` — if set, Caddy requires `Authorization: Bearer <key>` on `/v1/*` (works for phone apps that don't speak basic auth; satisfies Strata's "never expose without a key" rule)
  - `ExposeUi: true` — also proxy the backend UI at `/`
- **Caddy templates** — conditional LLM server block rendered only when `LLM.Enabled`:
  - Cloudflare mode: `llm.<domain>` with `handle /v1/*` (bearer gate) and the UI behind `basicauth` (Strata's built-in UI has no login; Caddy's bcrypt-hashed admin credentials are the gate)
  - DuckDNS mode: API-only (`/llm/v1/*`) — Strata's UI does not support path prefixes (same class of problem as Jellyseerr); document UI as Cloudflare-mode only
- **`01_webserver.ps1`** — renders the block from config; adds `llm` to the Cloudflare DNS updater `$Subdomains` when enabled. No new firewall rules (Caddy 80/443 already open)
- **Monitoring** — `collect_status.ps1` health probe `GET /health` on `127.0.0.1:<BackendPort>` + dashboard card when enabled
- **Docs** — `TECHNICAL_OVERVIEW.md` + `README.md` section: "Optional LLM proxy — pair with Strata (`--port 8081`, keep `--host 127.0.0.1`, set `--api-key`) or any OpenAI-compatible backend"
- **Uninstaller** — nothing to remove (Caddyfile is regenerated); explicitly document that the user's external LLM install is never touched by the project

Reference (current hand-made live config to be replaced): `llm.viperax.org` proxies `/v1/*` → `127.0.0.1:11434` behind a static Bearer check and `/` → Open WebUI at `127.0.0.1:9090`; Open WebUI, Ollama, and ComfyUI live as manual installs under `E:\MediaServer`.

Open decisions:
- ComfyUI (`img.viperax.org`) is also a manual Caddyfile addition — cover with a generic "extra subdomain proxy" feature or leave out of scope?
- UI over the internet behind Caddy `basicauth`, or API-only exposure?
- Confirm `BackendPort` default of 8081

Out of scope: installing/updating Strata or any LLM, LLM web UI hosting, model management.

---

### Priority 1 — Setup wizard

A first-time user should be able to go from a blank Windows machine to a fully configured seedbox by running one script and answering prompts — no JSON editing, no documentation reading, no prior knowledge of the apps involved.

Choices over typing: wherever a value comes from a known set, show a numbered menu. Defaults everywhere: every prompt shows its default in brackets; pressing Enter accepts it. Validate immediately on each field, then show a full review screen before writing `config.json`. Launch `master_install.ps1` automatically at the end.

The wizard collects: domain mode (DuckDNS / Cloudflare), TLS mode and email, admin credentials, install directory and media paths, which apps to enable, GPU type, extra user accounts (for Jellyfin + Jellyseerr), subtitle provider credentials, and port overrides. Option to pre-fill from an existing `config.json` for re-configuration.

Entry point: `setup_wizard.ps1` — top-level script, runs as Administrator, calls `master_install.ps1` when done.

---

### Backup script

Stops all services, archives each app's `C:\ProgramData\<App>` data directory (indexers, quality profiles, API keys, subtitle settings — everything that takes hours to recreate), writes a dated zip to a configurable destination (external drive, network share, or cloud-sync folder), and restarts services. Registers as a weekly Windows Scheduled Task. A restore script unpacks the archive and restarts services.

---

## Backlog

| Item | Notes |
|---|---|
| **Bazarr second subtitle language** | Second language from `config.json` should be added to the Bazarr language profile during Layer 2 via `POST /api/languages/profiles` |
| **Certificate renewal monitoring** | Weekly check of cert expiry from `caddy-data/`; warn via Windows toast if expiry < 14 days; `scripts\renew_cert.ps1` one-liner for a forced ACME attempt |
| **Notifiarr** | Discord/Telegram/email alerts on download events; all *arr apps support it natively via webhooks; free; one configure script wires all apps to a single endpoint |
| **Maintainerr** | Removes media nobody has watched after a configurable period via Jellyfin watch history + Sonarr/Radarr APIs; prevents library from growing forever |
| **Storage monitoring** | Daily scheduled task warns via Windows toast when any media drive falls below a configurable free-space threshold |
| **Service startup ordering** | After reboot, Sonarr/Radarr connect before Prowlarr is ready; fix via Windows service dependencies or a delayed-start script |
| **Tailscale** | VPN alternative to port forwarding for users behind CGNAT; free tier; add as alternative path alongside DuckDNS/Cloudflare in the setup wizard |
| **4K split libraries** | Second Radarr + Sonarr instances on separate ports with dedicated 4K root folders and separate Recyclarr quality profiles |
| **Unpackerr** | Auto-extracts `.rar` archives in download dirs so Sonarr/Radarr can import; lightweight Go binary, one NSSM service |
| **`master_status.ps1`** | Prints all service states, listening ports, disk usage per media path, and last warning from each app log |
| **Media health scan** | ffprobe pass over the library flagging corrupt or truncated video files |
| **Download ratio management** | Configure Deluge to stop seeding after a target ratio and auto-delete the torrent and files |
| **Tdarr** | Automated H.265/HEVC re-encoding pipeline that shrinks library size significantly |
| **Lidarr** | Music collection management, same install pattern as Sonarr/Radarr |
| **Readarr** | Books and ebooks management |
| **VPN binding** | Bind Deluge traffic to a WireGuard interface so the host IP is never exposed to torrent swarms |
| **`-DryRun` flag** | Print what would be installed or configured without executing anything |
| **Log transcript capture** | `Start-SeedboxLog`/`Stop-SeedboxLog` wrapper for full terminal transcript with ANSI strip; log rotation (keep last 10 per category); structured header block at top of each log file |
| **Service health alerting** | Push a Telegram/Discord notification when `collect_status.ps1` detects a service flip OK→FAIL (consecutive_ok resets); distinct from Notifiarr which covers download events only |
| **Dashboard: api_ok + consecutive_ok** | Surface `api_ok` and `consecutive_ok` in the web status page service list — a service can be `Running` but API-dead, which the current dot doesn't show |
| **Jellyseerr auto-configuration** | Installer currently leaves Jellyseerr unconfigured; Layer 2 should wire it to Jellyfin + Sonarr + Radarr via its API and import users from `config.json` |
| **qBittorrent** | Alternative BitTorrent client alongside Deluge for ratio management — per-torrent seed ratio/time limits, category-based save paths, and native VPN binding; run alongside Deluge or replace it for torrent-only use |
| **Autobrr** | IRC announce watcher that grabs freeleech and bonus torrents from private trackers the moment they're announced; integrates with Sonarr/Radarr/qBittorrent; dramatically improves ratios on private trackers |
| **Cross-seed** | Finds existing downloads that match torrents on other trackers and cross-seeds them without re-downloading; pairs with qBittorrent; near-zero cost ratio building |
| **Navidrome** | Self-hosted music streaming server (Spotify replacement); pairs with Lidarr; exposes a Subsonic API so any mobile app works |
| **Audiobookshelf** | Self-hosted audiobook server + podcast manager; pairs with Readarr; has its own mobile app |
| **Kavita** | Self-hosted manga/comics/books reader; pairs with Readarr/Mylar3; OPDS support for e-readers |
| **Immich** | Self-hosted photo and video backup (Google Photos replacement); mobile app with automatic upload |
| **Vaultwarden** | Self-hosted Bitwarden-compatible password manager; free; all Bitwarden clients work against it |

---

## Implemented

| Feature | Description |
|---|---|
| **Security — IPBan** | Monitors Windows Event Log and Caddy access log for failed logins; bans IPs that exceed the threshold with a Windows Firewall BLOCK rule; auto-whitelists LAN ranges and the server's own public IP |
| **Security — Caddy access log coverage** | Caddy JSON access logging enabled on all service blocks; CrowdSec parses the Caddy log covering Jellyfin, all *Arr apps, Deluge Web UI, and the dashboard from a single log source |
| **Security — abuse blocklists** | `update_blocklists.ps1` fetches Spamhaus DROP/EDROP and Firehol Level 1 and creates Windows Firewall BLOCK rules; refreshed every 6 hours via SYSTEM scheduled task |
| **Jellyseerr** | Netflix-style media request portal for Jellyfin users; built from source (Node.js 22 + pnpm); fully wired to Jellyfin, Sonarr, and Radarr during Layer 1 |
| **Shared user provisioning** | Users defined once in `config.json` are created in Jellyfin and imported into Jellyseerr -- no duplicate admin work across apps |
| **GPU auto-detection + transcoding profiles** | `detect_gpu.ps1` identifies the GPU family from `Win32_VideoController`; 18 JSON profiles across NVIDIA (Maxwell to Blackwell), AMD (GCN4 to RDNA4), Intel (HD to Arc), plus CPU fallback; applied to Jellyfin via Layer 2 |
| **Real-Debrid integration (Zurg + rclone)** | `15_zurg.ps1` installs Zurg as an NSSM service (WebDAV bridge for RD); `16_rclone.ps1` installs WinFsp + rclone and mounts Zurg on a drive letter for movies; Jellyfin libraries provisioned via Layer 2 with optional `Lean` flags (`DisableVideoExtraction`, `DisableMetadata`, `DisableImages`); controlled by `Apps.RealDebrid` + `RealDebrid.ApiKey` in config.json |
| **Observability stack (Grafana + Loki + Alloy)** | `14_grafana.ps1` installs Grafana, Loki, and Alloy as NSSM services; Alloy ships logs from all services (Caddy, CrowdSec, Deluge, Sonarr, Radarr, Prowlarr, Jellyfin, Bazarr, Flaresolverr, Jellyseerr) to Loki; Grafana pre-provisioned with Loki data source and seedbox dashboards; Caddy route added automatically; `grafana_enable.ps1` / `grafana_disable.ps1` for post-install toggle; controlled by `Apps.Grafana` |
| **Server status monitoring** | `13_status.ps1` registers `Seedbox_Status_Collector` scheduled task (every 5 min, SYSTEM); `collect_status.ps1` writes `dashboard/current_status.json` with system uptime, memory, drive usage, service states, download activity, and security stats; consumed by the dashboard UI |
| **Prowlarr indexer Enabled flag + private tracker support** | Each indexer in `Layer2.Prowlarr.Indexers` now has an `Enabled` boolean; disabled indexers are skipped during Layer 2. Private trackers (FileList, IPTorrents, RuTracker, TorrentLeech) supported via per-indexer `Credentials` object and `SeedRules` (ratio + seed time) |
| **Version pinning + updater + box CLI** | `versions.json` as single version source of truth; per-app `scripts\update_<App>.ps1` scripts (18 apps) with rollback; `installed_versions.json` ledger; data-driven `master_update.ps1` / `box check` / daily `check_updates.ps1`; `scripts\bump_versions.ps1` + weekly CI PR for manifest bumps |
| **Quality automation (Recyclarr + TRaSH Guides)** | Custom formats, quality profiles, and scoring synced to Sonarr/Radarr on every install from TRaSH Guides trash_ids |
| **Structured debug logging** | `debug_logger.ps1` dot-sourced by every script; opt-in via `General.DebugLogging`; timestamped per-session log to `<InstallDir>\logs\` |
| **End-to-end sanity check** | `scripts/sanity_check.py` drives the full Prowlarr -> Radarr/Sonarr -> Deluge -> Jellyfin -> Bazarr pipeline via REST APIs and reports pass/fail per stage |
| **Flaresolverr** | Headless Chromium CAPTCHA bypass proxy; registered with Prowlarr automatically; 18+ public indexers pre-added to Prowlarr |
| **Sonarr -> Jellyfin season repair** | `sonarr_jellyfin_refresh.py` Sonarr Custom Script that fixes the season hierarchy bug when TVDB metadata loads late at import time |
| **Cert cache** | Caddy cert store AES-256 encrypted on uninstall, restored on reinstall -- avoids Let's Encrypt rate limits |
| **Core stack** | Jellyfin, Sonarr, Radarr, Prowlarr, Deluge, Bazarr, ffmpeg -- full automated install, Layer 1 auth config, Layer 2 integration wiring |
