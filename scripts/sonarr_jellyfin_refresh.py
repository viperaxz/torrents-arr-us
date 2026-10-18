#!/usr/bin/env python3
"""
Post-import hook: fix Jellyfin season hierarchy after a Sonarr download.

Sonarr fires its Jellyfin updateLibrary notification the instant it imports
a file. Jellyfin scans immediately, but TVDB metadata for a brand-new series
is still downloading at that point. The season ends up detached from the
series in Jellyfin's database — Shows/Seasons returns 0 and the web player
crashes. A targeted Items/{id}/Refresh after the scan finishes resolves it.

Sonarr calls this script as a Custom Script connect on the OnDownload event and
RUNS IT SYNCHRONOUSLY: it waits for the exit code and does not import the next
episode until it returns. The first process therefore re-launches this script as
a detached child and exits at once; the child waits, then refreshes. Sleeping in
the invoked process stalled every import for _WAIT_SECONDS (measured: exactly
45 s between consecutive episodes of a season pack).

Environment variables supplied by Sonarr:
  sonarr_series_title   — series name used to find it in Jellyfin
  sonarr_eventtype      — "Download", "Test", etc.

Settings come from secrets/jellyfin_hook.json, written next to this script by
scripts/configure_layer2_sonarr.ps1 (base URL, Jellyfin API key, admin user id).
config.json is only read as a fallback for standalone/manual deployments.
"""

import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

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
_DETACH_ENV   = "SEEDBOX_JELLYFIN_HOOK_DETACHED"

# -- HTTP ---------------------------------------------------------------------
# urllib, not requests: the wrapper Sonarr executes is built from the system
# interpreter (C:\Python312), and that interpreter has no requests installed, so
# every run used to die on the import and the hook was silently dead on every
# download. The standard library is always present.
_NO_BODY = object()
# Jellyfin is always reached on 127.0.0.1 here, so never let a WinINET/env proxy
# (urllib reads the Windows proxy settings, requests did not) sit in the path.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _call(method, url, params=None, headers=None, body=_NO_BODY, timeout=10):
    """(ok, parsed_json) for one Jellyfin call. Never raises."""
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    hdrs = dict(headers or {})
    hdrs["Accept"] = "application/json"
    data = None
    if body is not _NO_BODY:
        data = json.dumps(body).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            raw = resp.read()
    except Exception:
        return False, None
    if not raw:
        return True, None
    try:
        return True, json.loads(raw.decode("utf-8-sig"))
    except Exception:
        return True, None


def _get(url, params=None, headers=None, timeout=10):
    return _call("GET", url, params=params, headers=headers, timeout=timeout)


def _post(url, params=None, headers=None, body=_NO_BODY, timeout=10):
    return _call("POST", url, params=params, headers=headers, body=body, timeout=timeout)


def _relaunch_detached():
    """Start the real work in a detached child and let the caller exit at once.

    Sonarr treats a Custom Script notification as part of the import: the child
    it executes must exit before the next episode is imported. DETACHED_PROCESS
    plus CREATE_NEW_PROCESS_GROUP (and CREATE_NO_WINDOW, so no console flashes on
    an interactive install) let the child outlive the wrapper .cmd that Sonarr is
    waiting on. Returns False when the relaunch fails, so the caller can fall back
    to doing the work inline instead of silently doing nothing.
    """
    env = dict(os.environ)
    env[_DETACH_ENV] = "1"
    flags = 0
    if os.name == "nt":
        flags = 0x00000008 | 0x00000200 | 0x08000000
    try:
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__)],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            creationflags=flags,
        )
        return True
    except Exception:
        return False


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
        # Report whether the hook can actually do its job: "test OK" alone hid a
        # hook that was missing settings (and, before, missing requests) for weeks.
        sidecar = _load_sidecar()
        legacy  = None if sidecar else _load_legacy_cfg()
        if sidecar:
            print("sonarr_jellyfin_refresh.py: test OK (settings: secrets/jellyfin_hook.json, "
                  f"base_url={sidecar[0]})")
        elif legacy:
            print("sonarr_jellyfin_refresh.py: test OK (settings: legacy config.json, "
                  f"base_url={legacy[0]})")
        else:
            print("sonarr_jellyfin_refresh.py: test OK, but NO settings found -- "
                  "downloads will be ignored")
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

    # Sonarr is blocked until this process exits, so hand the delay to a child.
    if os.environ.get(_DETACH_ENV) != "1" and _relaunch_detached():
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
        ok, body = _post(
            f"{base_url}/Users/AuthenticateByName",
            headers={"Authorization": _EMBY_HEADER},
            body={"Username": admin_user, "Pw": admin_pass},
            timeout=10,
        )
        if not ok or not isinstance(body, dict):
            sys.exit(0)
        token   = body.get("AccessToken", "")
        user_id = (body.get("User") or {}).get("Id", "")
        if not token or not user_id:
            sys.exit(0)
        auth_hdr = {"Authorization": f'{_EMBY_HEADER}, Token="{token}"'}

    # Find the series in Jellyfin by title
    ok, body = _get(
        f"{base_url}/Users/{user_id}/Items",
        headers=auth_hdr,
        params={"searchTerm": series_title, "Recursive": "true",
                "IncludeItemTypes": "Series", "Limit": 5, "Fields": "Id"},
        timeout=10,
    )
    items = body.get("Items", []) if ok and isinstance(body, dict) else []
    if not items:
        # The series is not in Jellyfin at all. That is the normal state after an
        # install: the library scan ran while the media folder was still empty, so
        # Jellyfin logged "inaccessible or empty, skipping", and every later
        # Library/Media/Updated from Sonarr only refreshes paths it already
        # knows -- so nothing ever appears and the whole library stays empty.
        # A full scan is the only thing that discovers the new folder.
        _post(f"{base_url}/Library/Refresh", headers=auth_hdr, timeout=15)
        sys.exit(0)
    series_id = items[0].get("Id", "")
    if not series_id:
        sys.exit(0)

    # Check if the season hierarchy is intact
    ok, body = _get(
        f"{base_url}/Shows/{series_id}/Seasons",
        headers=auth_hdr,
        params={"UserId": user_id},
        timeout=10,
    )
    n_seasons = body.get("TotalRecordCount", 0) if ok and isinstance(body, dict) else 0

    if n_seasons > 0:
        sys.exit(0)  # hierarchy is fine, nothing to do

    # Hierarchy is broken -- trigger a full metadata refresh
    _post(
        f"{base_url}/Items/{series_id}/Refresh",
        headers=auth_hdr,
        params={"MetadataRefreshMode": "FullRefresh",
                "ImageRefreshMode":    "FullRefresh",
                "ReplaceAllMetadata":  "false"},
        timeout=15,
    )


if __name__ == "__main__":
    main()
