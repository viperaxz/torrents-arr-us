# win-seedbox Roadmap

RULE FOR AI 1: ALL THE FEATURES WILL BE IMPLEMENTED ON THEIR OWN BRANCHES!!!!!!!!!!!!!!
RULE FOR AI 2: COMMIT ONLY AFTER A FULL UNINSTALL -> DO CHANGES -> FULLY INSTALL -> UNINSTALL CYCLE. YOU CAN DO AS MANY CYCLES YOU WANT, BUT DO NOT COMMIT UNLESS YOU HAVE A FLAWLESS CYCLE. YOU, AI, RUN THE SCRIPTS!

## Upcoming

### Priority 0 — Open items from the bug audit

A 16-agent parallel audit fixed ~150 defects across 66 files, and follow-up rounds worked the deferred list. **Only what is still open is listed here.**

Two blocks below are kept deliberately even though they are not work to do: an accepted-decision record, and a list of things that look like defects right after a fresh install but are not.

**Won't fix (accepted)** — the `/jellyseerr` path alias is rendered unconditionally and so 502s when `Apps.Jellyseerr = false`; and there is still no test module for ffmpeg.

**Expected after a fresh install (not defects)**

Two things show up in the *arr UIs right after an install and are worth recognising so they are not chased as bugs:

- **"New update is available"** on Sonarr, Radarr and Prowlarr. This is by design: `versions.json` pins a known-good version and the weekly Action is what bumps it, so the app is routinely a little behind upstream. The notice comes from the app's own periodic update *check*, which exposes no API switch, so it cannot be suppressed — and it would be wrong to try, since it is accurate. What matters is that the app cannot act on it: `configure_layer1_*.ps1` sets `updateAutomatically = false`, so the upgrade path stays `box update` (rolling swap + health gate + rollback + ledger). Note `updateMechanism` cannot be pinned either — the apps reset it to `builtIn` at startup — so a manual in-app "Install" remains clickable. Prefer `box update`.
- **"Indexers unavailable due to failures: <name> (Prowlarr)"** in Sonarr. On a fresh install the *arr apps test and RSS-sync every newly added indexer at once, and a rate-limited private tracker answers **429 TooManyRequests**; Sonarr then disables that indexer for a short window. It clears itself: observed on a real install as a burst at 22:18–22:19 followed by `Total of 100 reports were found` for the same indexer at 22:26, with the health warning gone and nothing to repair. Only investigate if it persists past the disable window or Prowlarr's own test (`POST /api/v1/indexer/test`) also fails.
- **An indexer that only answers a plain `t=search` is never synced to Sonarr/Radarr.** Prowlarr decides sync-ability by querying the app's categories with the current year (`t=movie&cat=2000`, `t=tvsearch&cat=5000`) and logs `No Results in configured categories. See FAQ Entry: Prowlarr will not sync X Indexer to App`. Measured on `torrentdownloads`: `t=caps` → 200, `t=search&q=matrix&cat=2000` → 50 items, but `t=movie`/`t=tvsearch` → 0, so it stays out of both apps while remaining searchable from the Prowlarr UI. That is an upstream Cardigann-definition limitation, not something the installer can fix — do not chase the resulting `RadarrV3Proxy|Invalid Request` / `400 BadRequest` lines.

**Verification still outstanding**

- **The LLM reverse proxy has never been through a full install/uninstall cycle.** It was implemented on `feature/update-strategy`; the generated Caddyfile was exercised with a real `caddy validate` (14/14 clean) and the bearer gate verified live (`/llm/v1/models` → 200 with the key, 401 without), but the full cycle was deferred at your request. Until that runs, treat the feature as implemented-but-unverified. Config keys, the Cloudflare-vs-DuckDNS layouts and the "API only in DuckDNS mode" limitation are documented in `TECHNICAL_OVERVIEW.md` and the README.

**Silent-success / health-check gaps (still open)**

- **The service-state check cannot prove the *new* image is loaded.** `Restart-Service -Force` can silently no-op on a failed stop, which `update_crowdsec.ps1` / `update_crowdsecbouncer.ps1` now verify around — so they confirm the service is `Running`, not which binary it is running.
- **`Seedbox_CrowdSecWhitelistRefresh` and `Seedbox_SecurityEventExport` were missing on a live box** while `Seedbox_Blocklist_Update` (registered later in the same `12_security.ps1` run) was present. The suite's `WhitelistRefreshTask` check caught it; the whitelist parser and the operator-IP marker were correct, so only the auto-refresh was gone — meaning a WAN-IP rotation could lock the operator out until someone updates the whitelist by hand. Why the two registrations were skipped is unresolved: it needs a full uninstall/install cycle with `12_security.ps1` logging to see whether `Copy-Item` of `update_crowdsec_whitelist.ps1` threw or the block was never reached. **Do not hand-register the task to silence the warning** — that hides the installer bug the check exists to find.
- **Layer 2/3 checks must assert values, not counts.** Two real outages (every synced indexer on a dead `baseUrl`, and Deluge missing the `radarr`/`tv-sonarr` labels) both passed a green suite. `IndexersFromProwlarr` and `Deluge LabelsPresent` now validate the actual values; treat any new check that only counts as incomplete.

**Feature / UX gaps (still open)**

- **The dashboard still ignores part of what the collector publishes.** The `api_ok` dot and tooltip landed, but `consecutive_ok`, `port_open`, and the queue/indexer/wanted counts are still unrendered, and `test_results.json` and `update_notification.json` are written with no consumer. The `test-suite` results reach Grafana (via the Loki push, now on a 15-minute `Seedbox_TestSuite` timer), but the generated HTML dashboard still does not read `test_results.json`.
- **`tests/test_llm_block.ps1` is not wired into `test-suite.ps1`** — it lacks a `-LayerFilter` parameter and asserts on `01_webserver.ps1`'s internal variable names, so it needs an adapter before it can join the suite.

**Known-incorrect behaviour left as documented trade-offs (still open)**

- **A bare `"AMD Radeon(TM) Graphics"` iGPU now takes the conservative profile.** The GPU mapping was corrected, but Ryzen Vega/Renoir/Raphael iGPUs report that ambiguous generic name, so they lose HEVC encode. That needs a device-ID table, not a name pattern.
- **`security_unban.ps1 -Whitelist` still refuses to create a missing `Security` block** (it prints the exact JSON to paste instead, because surgical block creation has a far worse failure surface than refusing). The install now warns up front so this is no longer a surprise.
- **Deluge has no runtime version re-detection.** `update_common.ps1`'s `Detect-InstalledVersion` has no Deluge case and Deluge is no longer Chocolatey-sourced, so `box check` relies on the ledger and lock file (both written with the on-disk version). A deleted ledger means an "unknown" installed version.

**Cleanup / conventions (still open)**

- **`<repo>\bin` and `cert-cache\` are kept across an uninstall but neither is named in the "Kept intact" footer.** Both are deliberate: `bin` caches the downloaded release zips (~1.5 GB, so a reinstall does not re-download them) and `cert-cache` preserves the ACME account and certificates. The footer lists only Chocolatey/NSSM/vcredist, the media paths and the Sonarr/Radarr backup, so a user reading it would reasonably expect both to be gone.
- **`update_crowdsec.ps1` and `update_crowdsecbouncer.ps1` duplicate four service helpers.** They are near-identical and belong in `update_common.ps1` as `Resolve-ServiceName` / `Ensure-ServiceRunning` alongside the sibling `update_*.ps1` scripts.

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

| **VPN binding** | Bind Deluge traffic to a WireGuard interface so the host IP is never exposed to torrent swarms |
| **Bazarr second subtitle language** | Second language from `config.json` should be added to the Bazarr language profile during Layer 2 via `POST /api/languages/profiles` |
| **Certificate renewal monitoring** | Weekly check of cert expiry from `caddy-data/`; warn via Windows toast if expiry < 14 days; `scripts\renew_cert.ps1` one-liner for a forced ACME attempt |
| **`master_status.ps1`** | Prints all service states, listening ports, disk usage per media path, and last warning from each app log |
| **Media health scan** | ffprobe pass over the library flagging corrupt or truncated video files |
| **Download ratio management** | Configure Deluge to stop seeding after a target ratio and auto-delete the torrent and files |
| **Dashboard: remaining collector fields** | `api_ok` has shipped; `consecutive_ok`, `port_open` and the queue/indexer/wanted counts are still unrendered — see the still-open item in Priority 0 rather than tracking it twice |
| **Navidrome** | Self-hosted music streaming server (Spotify replacement); pairs with Lidarr; exposes a Subsonic API so any mobile app works |
