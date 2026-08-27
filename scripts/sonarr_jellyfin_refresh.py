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
"""

import json
import os
import sys
import time

try:
    import requests
except ImportError:
    sys.exit(0)  # no requests = nothing to do, don't break Sonarr

# ── config (read from win-seedbox config.json sitting next to scripts/) ───────
_SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
_CONFIG_PATH  = os.path.normpath(os.path.join(_SCRIPT_DIR, "..", "config.json"))
_WAIT_SECONDS = 45   # let Jellyfin finish its initial scan before refreshing


def _load_jellyfin_cfg():
    try:
        with open(_CONFIG_PATH, encoding="utf-8-sig") as f:
            cfg = json.load(f)
        g       = cfg.get("General", {})
        ports   = cfg.get("Ports", {})
        mode    = g.get("DomainMode", "cloudflare")
        base    = "http://127.0.0.1"
        port    = ports.get("Jellyfin", 8096)
        prefix  = "/jellyfin" if mode == "duckdns" else ""
        key_file = os.path.join(g.get("InstallDir") or r"C:\MediaServer",
                                "secrets", "jellyfin_api_key.txt")
        api_key = ""
        if os.path.exists(key_file):
            with open(key_file, encoding="utf-8-sig") as f:
                api_key = f.read().strip()
        return f"{base}:{port}{prefix}", api_key, g.get("AdminUsername", "admin"), g.get("AdminPassword", "")
    except Exception:
        return None, None, None, None


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

    base_url, api_key, admin_user, admin_pass = _load_jellyfin_cfg()
    if not base_url:
        sys.exit(0)

    # Wait for Jellyfin's initial scan to settle
    time.sleep(_WAIT_SECONDS)

    # Authenticate
    emby_hdr = ('MediaBrowser Client="sonarr-hook", Device="Python", '
                'DeviceId="sonarr-jellyfin-hook", Version="1.0.0"')
    try:
        r = requests.post(
            f"{base_url}/Users/AuthenticateByName",
            json={"Username": admin_user, "Pw": admin_pass},
            headers={"X-Emby-Authorization": emby_hdr,
                     "Content-Type": "application/json"},
            timeout=10,
        )
        r.raise_for_status()
        token   = r.json().get("AccessToken", "")
        user_id = r.json().get("User", {}).get("Id", "")
    except Exception:
        sys.exit(0)

    auth_hdr = {"X-Emby-Authorization": f'{emby_hdr}, Token="{token}"'}

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
