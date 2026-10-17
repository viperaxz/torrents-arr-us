#!/usr/bin/env python3
"""
Post-import hook: fix Jellyfin season hierarchy after a Sonarr download.

Sonarr fires its Jellyfin updateLibrary notification the instant it imports
a file. Jellyfin scans immediately, but TVDB metadata for a brand-new series
is still downloading at that point. The season ends up detached from the
series in Jellyfin's database — Shows/Seasons returns 0 and the web player
crashes. A targeted Items/{id}/Refresh after the scan finishes resolves it.

Sonarr calls this script as a Custom Script connect on the OnDownload event.
It is launched as a background process and exits quickly; Sonarr does not wait.

Environment variables supplied by Sonarr:
  sonarr_series_title   — series name used to find it in Jellyfin
  sonarr_eventtype      — "Download", "Test", etc.

Settings come from secrets/jellyfin_hook.json, written next to this script by
scripts/configure_layer2_sonarr.ps1 (base URL, Jellyfin API key, admin user id).
config.json is only read as a fallback for standalone/manual deployments.
"""

import json
import os
import sys
import time

try:
    import requests
except ImportError:
    sys.exit(0)  # no requests = nothing to do, don't break Sonarr

# ── settings ──────────────────────────────────────────────────────────────────
# PRIMARY: the sidecar written next to this script by
# configure_layer2_sonarr.ps1 (<dir of this script>\secrets\jellyfin_hook.json).
# It holds only a Jellyfin base URL, an API key and an admin user id, so the hook
# needs nothing out of config.json -- which contains every credential in the
# stack and is deliberately not readable by the account Sonarr runs as.
# FALLBACK: the legacy win-seedbox config.json, for manual/standalone deployments.
_SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
_SIDECAR_PATH = os.path.join(_SCRIPT_DIR, "secrets", "jellyfin_hook.json")
_LEGACY_PATH  = os.path.normpath(os.path.join(_SCRIPT_DIR, "..", "config.json"))
_WAIT_SECONDS = 45   # let Jellyfin finish its initial scan before refreshing
_EMBY_HEADER  = ('MediaBrowser Client="sonarr-hook", Device="Python", '
                 'DeviceId="sonarr-jellyfin-hook", Version="1.0.0"')


def _load_sidecar():
    """(base_url, api_key, user_id) from the installer-written sidecar, or None."""
    try:
        with open(_SIDECAR_PATH, encoding="utf-8-sig") as f:
            cfg = json.load(f)
        base_url = str(cfg.get("base_url") or "").strip().rstrip("/")
        api_key  = str(cfg.get("api_key") or "").strip()
        user_id  = str(cfg.get("user_id") or "").strip()
        if base_url and api_key and user_id:
            return base_url, api_key, user_id
    except Exception:
        pass  # absent or malformed sidecar -> try the legacy config.json
    return None


def _load_legacy_cfg():
    """(base_url, admin_user, admin_password) from config.json, or None.

    Tolerant of config.json not existing: a hook deployed into the install
    directory has no config.json above it."""
    try:
        with open(_LEGACY_PATH, encoding="utf-8-sig") as f:
            cfg = json.load(f)
        g      = cfg.get("General", {})
        ports  = cfg.get("Ports", {})
        mode   = str(g.get("DomainMode", "cloudflare")).strip().lower()
        port   = ports.get("Jellyfin", 8096)
        prefix = "/jellyfin" if mode == "duckdns" else ""
        return (f"http://127.0.0.1:{port}{prefix}",
                str(g.get("AdminUsername", "admin")),
                str(g.get("AdminPassword", "")))
    except Exception:
        return None


def main():
    event = os.environ.get("sonarr_eventtype", "")
    if event == "Test":
        print("sonarr_jellyfin_refresh.py: test OK")
        sys.exit(0)
    if event != "Download":
        sys.exit(0)

    series_title = os.environ.get("sonarr_series_title", "").strip()
    if not series_title:
        sys.exit(0)

    sidecar = _load_sidecar()
    legacy  = None if sidecar else _load_legacy_cfg()
    if not sidecar and not legacy:
        sys.exit(0)

    # Wait for Jellyfin's initial scan to settle
    time.sleep(_WAIT_SECONDS)

    if sidecar:
        # API key + admin user id resolved by the installer: no login round-trip.
        base_url, api_key, user_id = sidecar
        # Jellyfin 12.x answers 401 for X-Emby-Token / X-Emby-Authorization carrying
        # an API key. Only the Authorization header with the MediaBrowser client
        # string plus Token= is accepted, so every request below uses this form.
        auth_hdr = {"Authorization": f'{_EMBY_HEADER}, Token="{api_key}"'}
    else:
        # Legacy: authenticate with the admin credentials from config.json.
        base_url, admin_user, admin_pass = legacy
        try:
            r = requests.post(
                f"{base_url}/Users/AuthenticateByName",
                json={"Username": admin_user, "Pw": admin_pass},
                headers={"Authorization": _EMBY_HEADER,
                         "Content-Type": "application/json"},
                timeout=10,
            )
            r.raise_for_status()
            token   = r.json().get("AccessToken", "")
            user_id = r.json().get("User", {}).get("Id", "")
        except Exception:
            sys.exit(0)
        if not token or not user_id:
            sys.exit(0)
        auth_hdr = {"Authorization": f'{_EMBY_HEADER}, Token="{token}"'}

    # Find the series in Jellyfin by title
    try:
        r = requests.get(
            f"{base_url}/Users/{user_id}/Items",
            headers=auth_hdr,
            params={"searchTerm": series_title, "Recursive": "true",
                    "IncludeItemTypes": "Series", "Limit": 5, "Fields": "Id"},
            timeout=10,
        )
        items = r.json().get("Items", []) if r.ok else []
        if not items:
            sys.exit(0)
        series_id = items[0]["Id"]
    except Exception:
        sys.exit(0)

    # Check if the season hierarchy is intact
    try:
        r = requests.get(
            f"{base_url}/Shows/{series_id}/Seasons",
            headers=auth_hdr,
            params={"UserId": user_id},
            timeout=10,
        )
        n_seasons = r.json().get("TotalRecordCount", 0) if r.ok else 0
    except Exception:
        n_seasons = 0

    if n_seasons > 0:
        sys.exit(0)  # hierarchy is fine, nothing to do

    # Hierarchy is broken — trigger a full metadata refresh
    try:
        requests.post(
            f"{base_url}/Items/{series_id}/Refresh",
            headers=auth_hdr,
            params={"MetadataRefreshMode": "FullRefresh",
                    "ImageRefreshMode":    "FullRefresh",
                    "ReplaceAllMetadata":  "false"},
            timeout=15,
        )
    except Exception:
        pass


if __name__ == "__main__":
    main()
