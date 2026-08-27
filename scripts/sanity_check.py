#!/usr/bin/env python3
"""
win-seedbox end-to-end sanity check.

Validates the full pipeline after install:
  Prowlarr → Radarr / Sonarr → Deluge → Jellyfin → Bazarr

Steps:
  0  Infrastructure  — services, APIs, Prowlarr wiring, disk space
  1  Radarr          — add movie, trigger search, verify grab / release results
  2  Sonarr          — add series S01, trigger search, verify grab / release results
  3  Deluge           — poll for active downloads matching the grabs
  4  Jellyfin        — poll for imported media (long timeout — download takes time)
  5  Bazarr          — subtitle provider health, wanted queue

Run individual steps during development:
    python sanity_check.py --steps 0          # infra only
    python sanity_check.py --steps 0,1 --no-cleanup
    python sanity_check.py --steps 3,4,5      # check later when downloads are done

Config values are read from:
  1. scripts/sanity_config.json (non-secret defaults — safe to commit)
  2. ../config.json             (admin credentials + ports + paths — auto-loaded)
  3. Environment variables      (ADMIN_USER, ADMIN_PASS, SANITY_MOVIE, SANITY_SERIES,
                                 DOMAIN_MODE, INSTALL_DIR — highest priority)

API keys are auto-discovered from the installed apps' config files.

Exit code: 0 = no FAIL results, 1 = at least one FAIL.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from typing import Any, Dict, List, Optional

# Force UTF-8 output so Unicode characters in indexer names / API responses
# don't crash on Windows consoles with cp1252 encoding.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    import requests
except ImportError:
    sys.exit("ERROR: 'requests' not installed.  Run: python -m pip install requests")

# ─── colour helpers ────────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def _c(text: Any, *codes: str) -> str:
    return "".join(codes) + str(text) + RESET


# ─── result tracking ──────────────────────────────────────────────────────────
_results: List[Dict[str, str]] = []

def record(step: str, status: str, msg: str) -> None:
    _results.append({"step": step, "status": status, "msg": msg})
    colour = {"PASS": GREEN, "FAIL": RED, "WARN": YELLOW}[status]
    print(f"  [{_c(status, colour)}] {msg}")

def head(name: str) -> None:
    bar = "─" * max(0, 56 - len(name))
    print(f"\n{_c('─── ' + name + ' ' + bar, CYAN)}")


# ─── config ───────────────────────────────────────────────────────────────────
def load_config(sanity_cfg_path: str) -> Dict[str, Any]:
    with open(sanity_cfg_path, encoding="utf-8-sig") as f:
        sc = json.load(f)

    cfg: Dict[str, Any] = {
        "sanity_movie":         sc.get("SANITY_MOVIE",         "The Godfather"),
        "sanity_movie_year":    sc.get("SANITY_MOVIE_YEAR",    1972),
        "sanity_series":        sc.get("SANITY_SERIES",        "Friends"),
        "sanity_series_season": sc.get("SANITY_SERIES_SEASON", 1),
        "download_poll_secs":   sc.get("DownloadPollSecs",     300),
        "import_poll_secs":     sc.get("ImportPollSecs",       1800),
        "import_poll_interval": sc.get("ImportPollInterval",   30),
        "admin_user":  "admin",
        "admin_pass":  "",
        "domain_mode": "cloudflare",
        "install_dir": r"C:\MediaServer",
        "ports": {
            "Radarr": 7878, "Sonarr": 8989, "Prowlarr": 9696,
            "Deluge": 58846, "DelugeWeb": 8112, "Jellyfin": 8096, "Bazarr": 6767,
        },
        "url_bases": {k: "" for k in ("Radarr","Sonarr","Prowlarr","Jellyfin","Bazarr","Deluge")},
        "media_paths": [],
    }

    # Merge main config.json (lives one directory up from scripts/)
    wb_path = os.path.normpath(
        os.path.join(os.path.dirname(sanity_cfg_path), "..", "config.json")
    )
    if os.path.exists(wb_path):
        with open(wb_path, encoding="utf-8-sig") as f:
            wb = json.load(f)
        g = wb.get("General", {})
        cfg["admin_user"]  = g.get("AdminUsername", cfg["admin_user"])
        cfg["admin_pass"]  = g.get("AdminPassword",  cfg["admin_pass"])
        cfg["domain_mode"] = g.get("DomainMode",     cfg["domain_mode"])
        cfg["install_dir"] = g.get("InstallDir",     cfg["install_dir"])
        for app, port in wb.get("Ports", {}).items():
            if app in cfg["ports"]:
                cfg["ports"][app] = port
        paths = wb.get("Paths", {})
        cfg["media_paths"] = [v for v in (
            paths.get("Downloads"), paths.get("Movies"), paths.get("TV")
        ) if v]

    if cfg["domain_mode"] == "duckdns":
        cfg["url_bases"].update({
            "Radarr": "/radarr", "Sonarr": "/sonarr", "Prowlarr": "/prowlarr",
            "Jellyfin": "/jellyfin", "Bazarr": "/bazarr",
        })

    # Environment variable overrides (highest priority)
    for env, key in [("ADMIN_USER","admin_user"), ("ADMIN_PASS","admin_pass"),
                     ("SANITY_MOVIE","sanity_movie"), ("SANITY_SERIES","sanity_series"),
                     ("DOMAIN_MODE","domain_mode"), ("INSTALL_DIR","install_dir")]:
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    if os.environ.get("DOMAIN_MODE") == "duckdns":
        cfg["url_bases"].update({
            "Radarr": "/radarr", "Sonarr": "/sonarr", "Prowlarr": "/prowlarr",
            "Jellyfin": "/jellyfin", "Bazarr": "/bazarr",
        })

    return cfg


def discover_keys(cfg: Dict[str, Any]) -> Dict[str, Optional[str]]:
    """Auto-discover API keys from the installed apps' config files."""
    def _xml(path: str) -> Optional[str]:
        try:
            return ET.parse(path).getroot().find("ApiKey").text
        except Exception:
            return None

    keys: Dict[str, Optional[str]] = {
        "radarr":   _xml(r"C:\ProgramData\Radarr\config.xml"),
        "sonarr":   _xml(r"C:\ProgramData\Sonarr\config.xml"),
        "prowlarr": _xml(r"C:\ProgramData\Prowlarr\config.xml"),
        "deluge_password": None,
        "bazarr":   None,
        "jellyfin": None,  # obtained at runtime via /Users/AuthenticateByName
    }

    secret_file = os.path.join(cfg["install_dir"], "secrets", "deluge_auth.txt")
    try:
        with open(secret_file, encoding="utf-8-sig") as f:
            keys["deluge_password"] = f.read().strip()
    except Exception:
        pass

    bazarr_yaml = r"C:\ProgramData\Bazarr\config\config.yaml"
    try:
        content = open(bazarr_yaml, encoding="utf-8").read()
        m = re.search(r"apikey:\s*(\S+)", content)
        keys["bazarr"] = m.group(1) if m else None
    except Exception:
        pass

    return keys


def _url(cfg: Dict, app: str, path: str = "") -> str:
    return f"http://127.0.0.1:{cfg['ports'][app]}{cfg['url_bases'].get(app, '')}{path}"


# ─── Step 0: Infrastructure ───────────────────────────────────────────────────
_SERVICES = {
    "Caddy":          "Caddy",
    "Sonarr":         "Sonarr",
    "Radarr":         "Radarr",
    "Prowlarr":       "Prowlarr",
    "DelugeDaemon":   "DelugeDaemon",
    "DelugeWeb":      "DelugeWeb",
    "Bazarr":         "Bazarr",
    "Jellyfin":       "JellyfinServer",
    "Flaresolverr":   "Flaresolverr",
}


def _svc_status(svc_name: str) -> str:
    try:
        r = subprocess.run(
            ["powershell", "-NonInteractive", "-Command",
             f"(Get-Service -Name '{svc_name}' -ErrorAction SilentlyContinue).Status"],
            capture_output=True, text=True, timeout=10
        )
        return r.stdout.strip() or "NotFound"
    except Exception:
        return "Error"


def step0_infrastructure(cfg: Dict, keys: Dict) -> bool:
    head("Step 0 — Infrastructure")
    all_ok = True

    # ── services ──────────────────────────────────────────────────────────────
    for label, svc in _SERVICES.items():
        status = _svc_status(svc)
        if status == "Running":
            record("Infra", "PASS", f"Service {label}: Running")
        elif status == "NotFound":
            record("Infra", "WARN", f"Service {label}: not installed / disabled in config")
        else:
            record("Infra", "FAIL", f"Service {label}: {status}")
            all_ok = False

    # ── API health ─────────────────────────────────────────────────────────────
    for app, endpoint, key in [
        ("Sonarr",   _url(cfg,"Sonarr",  "/api/v3/system/status"), keys.get("sonarr")),
        ("Radarr",   _url(cfg,"Radarr",  "/api/v3/system/status"), keys.get("radarr")),
        ("Prowlarr", _url(cfg,"Prowlarr","/api/v1/system/status"), keys.get("prowlarr")),
    ]:
        if not key:
            record("Infra", "FAIL", f"{app} API key not found (config.xml missing?)")
            all_ok = False
            continue
        try:
            r = requests.get(endpoint, headers={"X-Api-Key": key}, timeout=10)
            r.raise_for_status()
            record("Infra", "PASS", f"{app} API healthy (v{r.json().get('version','?')})")
        except Exception as exc:
            record("Infra", "FAIL", f"{app} API unreachable: {exc}")
            all_ok = False

    try:
        r = requests.get(_url(cfg, "Jellyfin", "/System/Info/Public"), timeout=10)
        r.raise_for_status()
        record("Infra", "PASS",
               f"Jellyfin API healthy (v{r.json().get('Version','?')})")
    except Exception as exc:
        record("Infra", "FAIL", f"Jellyfin API unreachable: {exc}")
        all_ok = False

    baz_key = keys.get("bazarr")
    if baz_key:
        try:
            r = requests.get(_url(cfg,"Bazarr","/api/system/health"),
                             headers={"X-Api-Key": baz_key}, timeout=10)
            record("Infra", "PASS" if r.status_code == 200 else "WARN",
                   f"Bazarr API: HTTP {r.status_code}")
        except Exception as exc:
            record("Infra", "WARN", f"Bazarr API: {exc}")
    else:
        record("Infra", "WARN", "Bazarr API key not found — skipping Bazarr health check")

    rpc_pass = keys.get("deluge_password")
    if rpc_pass:
        try:
            resp = requests.post(
                f"http://127.0.0.1:{cfg['ports']['DelugeWeb']}/json",
                json={"method":"auth.login","params":[rpc_pass],"id":1},
                timeout=10
            )
            if resp.json().get("result") is True:
                record("Infra", "PASS", "Deluge Web UI RPC healthy (auth.login OK)")
            else:
                record("Infra", "FAIL", f"Deluge Web UI login failed: {resp.json().get('error',{}).get('message','?')}")
                all_ok = False
        except Exception as exc:
            record("Infra", "FAIL", f"Deluge Web UI RPC not responding: {exc}")
            all_ok = False
    else:
        record("Infra", "FAIL", "Deluge password not found")
        all_ok = False

    # ── Prowlarr integration ───────────────────────────────────────────────────
    prow_key = keys.get("prowlarr")
    if prow_key:
        hdrs = {"X-Api-Key": prow_key}

        # Indexer count
        try:
            indexers = requests.get(
                _url(cfg, "Prowlarr", "/api/v1/indexer"),
                headers=hdrs, timeout=10
            ).json()
            n = len(indexers) if isinstance(indexers, list) else 0
            if n >= 1:
                sample = ", ".join(ix.get("name","?") for ix in indexers[:4])
                record("Infra", "PASS",
                       f"Prowlarr: {n} indexer(s)  ({sample}{'...' if n>4 else ''})")
            else:
                record("Infra", "FAIL", "Prowlarr: no indexers — run layer2")
                all_ok = False
        except Exception as exc:
            record("Infra", "WARN", f"Prowlarr indexers: {exc}")

        # Sonarr + Radarr registered
        try:
            apps = requests.get(
                _url(cfg, "Prowlarr", "/api/v1/applications"),
                headers=hdrs, timeout=10
            ).json()
            app_names = [a.get("name","").lower()
                         for a in (apps if isinstance(apps, list) else [])]
            for exp in ("sonarr", "radarr"):
                registered = any(exp in n for n in app_names)
                record("Infra",
                       "PASS" if registered else "FAIL",
                       f"Prowlarr → {exp.title()}: "
                       f"{'registered (fullSync)' if registered else 'NOT registered — run layer2'}")
                if not registered:
                    all_ok = False
        except Exception as exc:
            record("Infra", "WARN", f"Prowlarr apps: {exc}")

        # FlareSolverr proxy
        try:
            proxy_resp = requests.get(
                _url(cfg, "Prowlarr", "/api/v1/indexerProxy"),
                headers=hdrs, timeout=10
            ).json()
            # Response is either a single object or a list depending on Prowlarr version
            proxies = proxy_resp if isinstance(proxy_resp, list) else [proxy_resp]
            flare_proxies = [
                p for p in proxies
                if "flare" in p.get("implementation","").lower()
                or "flare" in p.get("name","").lower()
            ]
            if flare_proxies:
                fs_host = next(
                    (f["value"] for f in flare_proxies[0].get("fields",[])
                     if f.get("name") == "host"),
                    "?"
                )
                record("Infra", "PASS",
                       f"Prowlarr FlareSolverr proxy configured ({fs_host})")
            else:
                record("Infra", "WARN",
                       "Prowlarr: no FlareSolverr proxy — CF-protected indexers will fail")
        except Exception as exc:
            record("Infra", "WARN", f"Prowlarr FlareSolverr check: {exc}")

    # ── Sonarr / Radarr configuration ─────────────────────────────────────────
    for app, key in [("Sonarr", keys.get("sonarr")), ("Radarr", keys.get("radarr"))]:
        if not key:
            continue
        hdrs = {"X-Api-Key": key}
        base = _url(cfg, app)

        try:
            roots = requests.get(f"{base}/api/v3/rootFolder", headers=hdrs, timeout=10).json()
            if isinstance(roots, list) and roots:
                record("Infra", "PASS",
                       f"{app}: root folder = {roots[0].get('path','?')} "
                       f"({roots[0].get('freeSpace',0)//1024//1024//1024} GB free)")
            else:
                record("Infra", "FAIL", f"{app}: no root folder — run layer2")
                all_ok = False
        except Exception as exc:
            record("Infra", "WARN", f"{app} root folder: {exc}")

        try:
            clients = requests.get(f"{base}/api/v3/downloadclient",
                                   headers=hdrs, timeout=10).json()
            deluge = [c for c in (clients if isinstance(clients, list) else [])
                     if "deluge" in c.get("name","").lower()]
            if deluge and any(c.get("enable", True) for c in deluge):
                host = next(
                    (f.get("value","?") for c in deluge
                     for f in c.get("fields",[]) if f.get("name") == "host"),
                    "?"
                )
                port = next(
                    (f.get("value","?") for c in deluge
                     for f in c.get("fields",[]) if f.get("name") == "port"),
                    "?"
                )
                record("Infra", "PASS",
                       f"{app}: Deluge download client enabled ({host}:{port})")
            elif deluge:
                record("Infra", "WARN", f"{app}: Deluge client exists but is disabled")
            else:
                record("Infra", "FAIL", f"{app}: no Deluge download client — run layer2")
                all_ok = False
        except Exception as exc:
            record("Infra", "WARN", f"{app} download clients: {exc}")

        try:
            profs = requests.get(f"{base}/api/v3/qualityProfile",
                                 headers=hdrs, timeout=10).json()
            n = len(profs) if isinstance(profs, list) else 0
            names = ", ".join(p.get("name","?") for p in (profs or [])[:4])
            record("Infra", "PASS" if n else "FAIL",
                   f"{app}: {n} quality profile(s)  ({names}{'...' if n>4 else ''})")
            if not n:
                all_ok = False
        except Exception as exc:
            record("Infra", "WARN", f"{app} quality profiles: {exc}")

    # ── Jellyfin libraries (requires auth) ────────────────────────────────────
    try:
        emby_hdr = ('MediaBrowser Client="win-seedbox-sanity", Device="Python", '
                    'DeviceId="sanity-check-001", Version="1.0.0"')
        auth_r = requests.post(
            _url(cfg, "Jellyfin", "/Users/AuthenticateByName"),
            json={"Username": cfg["admin_user"], "Pw": cfg["admin_pass"]},
            headers={"X-Emby-Authorization": emby_hdr,
                     "Content-Type": "application/json"},
            timeout=10,
        )
        if auth_r.ok:
            token = auth_r.json().get("AccessToken", "")
            lib_r = requests.get(
                _url(cfg, "Jellyfin", "/Library/VirtualFolders"),
                headers={"X-Emby-Authorization":
                         f'{emby_hdr}, Token="{token}"'},
                timeout=10,
            )
            libs  = lib_r.json() if lib_r.ok else []
            n     = len(libs) if isinstance(libs, list) else 0
            names = ", ".join(lb.get("Name","?") for lb in (libs or []))
            record("Infra", "PASS" if n else "WARN",
                   f"Jellyfin: {n} media librar{'y' if n==1 else 'ies'}  ({names})")
        else:
            record("Infra", "WARN",
                   f"Jellyfin library check skipped — auth returned HTTP {auth_r.status_code}")
    except Exception as exc:
        record("Infra", "WARN", f"Jellyfin libraries: {exc}")

    # ── disk space ─────────────────────────────────────────────────────────────
    seen_drives: set = set()
    for path in cfg.get("media_paths", []):
        drive = path[:3].upper()
        if drive in seen_drives:
            continue
        seen_drives.add(drive)
        try:
            free_gb = shutil.disk_usage(drive).free / 1024 ** 3
            record("Infra", "PASS" if free_gb >= 10 else "WARN",
                   f"Disk {drive}: {free_gb:.1f} GB free")
        except Exception as exc:
            record("Infra", "WARN", f"Disk {drive}: {exc}")

    return all_ok


# ─── Step 1: Radarr ───────────────────────────────────────────────────────────
def step1_radarr(cfg: Dict, keys: Dict, added: Dict) -> bool:
    head("Step 1 — Radarr: add movie and search")

    api_key = keys.get("radarr")
    if not api_key:
        record("Radarr", "FAIL", "API key not found (config.xml missing?)")
        return False

    base    = _url(cfg, "Radarr")
    hdrs    = {"X-Api-Key": api_key, "Content-Type": "application/json"}
    title   = cfg["sanity_movie"]
    year    = cfg.get("sanity_movie_year")

    # API health
    try:
        r = requests.get(f"{base}/api/v3/system/status", headers=hdrs, timeout=10)
        r.raise_for_status()
        record("Radarr", "PASS", f"API healthy (v{r.json().get('version','?')})")
    except Exception as exc:
        record("Radarr", "FAIL", f"API unreachable: {exc}")
        return False

    # Movie lookup (TMDB)
    try:
        r = requests.get(f"{base}/api/v3/movie/lookup",
                         headers=hdrs, params={"term": title}, timeout=20)
        r.raise_for_status()
        candidates = r.json()
        if not candidates:
            record("Radarr", "FAIL", f"No TMDB results for '{title}'")
            return False
        movie = candidates[0]
        if year:
            for c in candidates:
                if c.get("year") == year:
                    movie = c
                    break
        record("Radarr", "PASS",
               f"TMDB lookup: '{movie.get('title')}' ({movie.get('year')})  "
               f"TMDB:{movie.get('tmdbId')}")
    except Exception as exc:
        record("Radarr", "FAIL", f"Movie lookup failed: {exc}")
        return False

    # Already in library?
    try:
        existing = [m for m in requests.get(f"{base}/api/v3/movie",
                                             headers=hdrs, timeout=10).json()
                    if m.get("tmdbId") == movie.get("tmdbId")]
    except Exception:
        existing = []

    if existing:
        movie_id = existing[0]["id"]
        added["radarr_movie_id"] = movie_id
        added["radarr_existed"]  = True
        record("Radarr", "WARN",
               f"'{title}' already in library (id={movie_id}) — reusing for search test")
    else:
        try:
            roots = requests.get(f"{base}/api/v3/rootFolder",
                                 headers=hdrs, timeout=10).json()
            profs = requests.get(f"{base}/api/v3/qualityProfile",
                                 headers=hdrs, timeout=10).json()
        except Exception as exc:
            record("Radarr", "FAIL", f"Cannot fetch profiles/roots: {exc}")
            return False

        if not roots:
            record("Radarr", "FAIL", "No root folders configured")
            return False

        # Prefer HD-1080p profile; fall back to first available
        prof = next((p for p in profs if "1080p" in p.get("name","")
                     and "web" not in p.get("name","").lower()), None) or profs[0]

        payload = {
            **{k: v for k, v in movie.items() if k not in ("id", "statistics")},
            "qualityProfileId":    prof["id"],
            "rootFolderPath":      roots[0]["path"],
            "monitored":           True,
            "minimumAvailability": "announced",
            "addOptions":          {"searchForMovie": False},
        }
        try:
            r = requests.post(f"{base}/api/v3/movie", headers=hdrs,
                              json=payload, timeout=20)
            if r.status_code not in (200, 201):
                record("Radarr", "FAIL",
                       f"Add movie HTTP {r.status_code}: {r.text[:200]}")
                return False
            movie_id = r.json()["id"]
            added["radarr_movie_id"] = movie_id
            record("Radarr", "PASS",
                   f"Added '{title}' to Radarr  (id={movie_id}, profile='{prof['name']}')")
        except Exception as exc:
            record("Radarr", "FAIL", f"Add movie request failed: {exc}")
            return False

    movie_id = added["radarr_movie_id"]

    # Trigger search command
    cmd_id = None
    try:
        r = requests.post(f"{base}/api/v3/command", headers=hdrs,
                          json={"name": "MoviesSearch", "movieIds": [movie_id]},
                          timeout=15)
        if r.status_code in (200, 201):
            cmd_id = r.json().get("id")
            record("Radarr", "PASS", f"Search command submitted (cmd_id={cmd_id})")
        else:
            record("Radarr", "WARN", f"Search command returned HTTP {r.status_code}")
    except Exception as exc:
        record("Radarr", "WARN", f"Search command failed: {exc}")

    # Wait for command to complete (up to 90 s)
    if cmd_id:
        deadline = time.time() + 90
        while time.time() < deadline:
            try:
                st = requests.get(f"{base}/api/v3/command/{cmd_id}",
                                  headers=hdrs, timeout=10).json().get("status","")
                if st in ("completed", "failed"):
                    record("Radarr", "PASS" if st=="completed" else "WARN",
                           f"Search command {st}")
                    break
            except Exception:
                pass
            time.sleep(3)

    # Poll history + queue for grab confirmation (60 s)
    print(f"  Polling history/queue for grab confirmation (60 s)...")
    found    = False
    deadline = time.time() + 60
    while not found and time.time() < deadline:
        try:
            hist = requests.get(
                f"{base}/api/v3/history",
                headers=hdrs, params={"movieId": movie_id, "pageSize": 20},
                timeout=10
            ).json().get("records", [])
            for h in hist:
                if h.get("eventType") == "grabbed":
                    size_mb = h.get("data",{}).get("size", 0) // 1024 // 1024
                    record("Radarr", "PASS",
                           f"Auto-grabbed: '{h.get('sourceTitle','?')}' ({size_mb} MB)")
                    found = True
                    break
            if not found:
                q = requests.get(f"{base}/api/v3/queue",
                                 headers=hdrs, timeout=10).json()
                in_q = [r for r in q.get("records",[]) if r.get("movieId") == movie_id]
                if in_q:
                    record("Radarr", "PASS",
                           f"Download queued: '{in_q[0].get('title','?')}' "
                           f"— {in_q[0].get('status','?')}")
                    found = True
        except Exception:
            pass
        if not found:
            time.sleep(5)

    if found:
        return True

    # Fallback: interactive release endpoint (synchronous, up to 45 s from Prowlarr)
    print("  Auto-grab did not fire — trying interactive release search...")
    try:
        releases = requests.get(
            f"{base}/api/v3/release",
            headers=hdrs, params={"movieId": movie_id},
            timeout=60
        ).json()
    except Exception as exc:
        record("Radarr", "FAIL", f"Release search failed: {exc}")
        return False

    if not isinstance(releases, list) or not releases:
        record("Radarr", "FAIL",
               "0 releases from Prowlarr — check indexer config and FlareSolverr")
        return False

    top_score = max((r.get("customFormatScore", 0) for r in releases), default=0)
    score_note = (
        f", best custom-format score: +{top_score}"
        if top_score > 0
        else " (all +0 — custom formats not matched; see Priority 2 in ROADMAP)"
    )
    record("Radarr",
           "PASS" if top_score > 0 else "WARN",
           f"{len(releases)} releases from Prowlarr{score_note}")

    # Force-grab the best-seeded release under 5 GB to exercise the Deluge pipeline
    MAX_BYTES = 5 * 1024 ** 3
    cands = [r for r in releases if 0 < r.get("size", 0) <= MAX_BYTES] or releases
    target = max(cands, key=lambda r: r.get("seeders", 0))
    size_mb = target.get("size", 0) // 1024 // 1024
    try:
        rg = requests.post(f"{base}/api/v3/release", headers=hdrs,
                           json=target, timeout=20)
        if rg.status_code in (200, 201, 409):
            record("Radarr", "PASS",
                   f"Force-grabbed: '{target.get('title','?')}' "
                   f"({size_mb} MB, {target.get('seeders',0)} seeders)")
        else:
            record("Radarr", "WARN",
                   f"Force-grab HTTP {rg.status_code}: {rg.text[:120]}")
    except Exception as exc:
        record("Radarr", "WARN", f"Force-grab request failed: {exc}")

    return True


# ─── Step 2: Sonarr ───────────────────────────────────────────────────────────
def step2_sonarr(cfg: Dict, keys: Dict, added: Dict) -> bool:
    head("Step 2 — Sonarr: add series and search S01")

    api_key = keys.get("sonarr")
    if not api_key:
        record("Sonarr", "FAIL", "API key not found")
        return False

    base   = _url(cfg, "Sonarr")
    hdrs   = {"X-Api-Key": api_key, "Content-Type": "application/json"}
    title  = cfg["sanity_series"]
    season = cfg.get("sanity_series_season", 1)

    # API health
    try:
        r = requests.get(f"{base}/api/v3/system/status", headers=hdrs, timeout=10)
        r.raise_for_status()
        record("Sonarr", "PASS", f"API healthy (v{r.json().get('version','?')})")
    except Exception as exc:
        record("Sonarr", "FAIL", f"API unreachable: {exc}")
        return False

    # Series lookup (TVDB)
    try:
        r = requests.get(f"{base}/api/v3/series/lookup",
                         headers=hdrs, params={"term": title}, timeout=20)
        r.raise_for_status()
        candidates = r.json()
        if not candidates:
            record("Sonarr", "FAIL", f"No TVDB results for '{title}'")
            return False
        series = candidates[0]
        record("Sonarr", "PASS",
               f"TVDB lookup: '{series.get('title')}' ({series.get('year')})  "
               f"TVDB:{series.get('tvdbId')}")
    except Exception as exc:
        record("Sonarr", "FAIL", f"Series lookup failed: {exc}")
        return False

    # Already in library?
    try:
        existing = [s for s in requests.get(f"{base}/api/v3/series",
                                             headers=hdrs, timeout=10).json()
                    if int(s.get("tvdbId",0)) == int(series.get("tvdbId",0))]
    except Exception:
        existing = []

    if existing:
        series_id = existing[0]["id"]
        added["sonarr_series_id"] = series_id
        added["sonarr_existed"]   = True
        record("Sonarr", "WARN",
               f"'{title}' already in library (id={series_id}) — reusing for search test")
    else:
        try:
            roots = requests.get(f"{base}/api/v3/rootFolder",
                                 headers=hdrs, timeout=10).json()
            profs = requests.get(f"{base}/api/v3/qualityProfile",
                                 headers=hdrs, timeout=10).json()
        except Exception as exc:
            record("Sonarr", "FAIL", f"Cannot fetch profiles/roots: {exc}")
            return False

        if not roots:
            record("Sonarr", "FAIL", "No root folders configured")
            return False

        # Prefer WEB-1080p; fall back to first
        prof = next((p for p in profs if p.get("name","") == "WEB-1080p"), None) or profs[0]

        # Add with monitor=7 (None) so nothing is monitored initially.
        # We will explicitly mark only S01E01 as monitored after the add,
        # preventing a SeasonSearch from grabbing all 24 episodes.
        seasons_arr = [
            {"seasonNumber": s.get("seasonNumber", 0), "monitored": False}
            for s in series.get("seasons", [])
        ]

        payload = {
            "title":            series["title"],
            "sortTitle":        series.get("sortTitle", ""),
            "status":           series.get("status", "ended"),
            "overview":         series.get("overview", ""),
            "network":          series.get("network", ""),
            "airTime":          series.get("airTime", ""),
            "images":           series.get("images", []),
            "seasons":          seasons_arr,
            "year":             series.get("year", 0),
            "qualityProfileId": prof["id"],
            "seasonFolder":     True,
            "monitored":        True,
            "tvdbId":           series["tvdbId"],
            "tvMazeId":         series.get("tvMazeId", 0),
            "imdbId":           series.get("imdbId", ""),
            "titleSlug":        series.get("titleSlug", ""),
            "rootFolderPath":   roots[0]["path"],
            "genres":           series.get("genres", []),
            "tags":             [],
            "ratings":          series.get("ratings", {"votes": 0, "value": 0}),
            "seriesType":       series.get("seriesType", "standard"),
            "cleanTitle":       series.get("cleanTitle", ""),
            "certification":    series.get("certification", ""),
            "addOptions": {
                "monitor":                      7,  # MonitorTypes.None — we pin E01 manually below
                "searchForMissingEpisodes":     False,
                "searchForCutoffUnmetEpisodes": False,
            },
        }
        try:
            r = requests.post(f"{base}/api/v3/series", headers=hdrs,
                              json=payload, timeout=20)
            if r.status_code not in (200, 201):
                record("Sonarr", "FAIL",
                       f"Add series HTTP {r.status_code}: {r.text[:200]}")
                return False
            series_id = r.json()["id"]
            added["sonarr_series_id"] = series_id
            record("Sonarr", "PASS",
                   f"Added '{title}' to Sonarr  "
                   f"(id={series_id}, S{season:02d}E01 only, profile='{prof['name']}')")
        except Exception as exc:
            record("Sonarr", "FAIL", f"Add series failed: {exc}")
            return False

        # Explicitly unmonitor every season regardless of what addOptions.monitor did.
        # In Sonarr v4 the integer enum values differ from documentation:
        #   5 = First (season 1), 7 = Latest (last season), not None.
        # Setting seasons[].monitored = False here is the only reliable approach.
        try:
            series_obj = requests.get(f"{base}/api/v3/series/{series_id}",
                                      headers=hdrs, timeout=10).json()
            for s in series_obj.get("seasons", []):
                s["monitored"] = False
            requests.put(f"{base}/api/v3/series/{series_id}",
                         headers=hdrs, json=series_obj, timeout=15)
        except Exception:
            pass

    series_id = added["sonarr_series_id"]

    # Poll until S01E01 appears in the episode list (metadata loads async, up to 60 s)
    print(f"  Waiting for S{season:02d}E01 metadata (up to 60 s)...")
    s01e01   = None
    deadline = time.time() + 60
    while s01e01 is None and time.time() < deadline:
        try:
            episodes = requests.get(
                f"{base}/api/v3/episode",
                headers=hdrs, params={"seriesId": series_id}, timeout=15
            ).json()
            s_eps  = [e for e in episodes if e.get("seasonNumber") == season]
            s01e01 = next((e for e in s_eps if e.get("episodeNumber") == 1), None)
        except Exception:
            pass
        if s01e01 is None:
            time.sleep(5)

    if s01e01 is None:
        record("Sonarr", "FAIL",
               f"S{season:02d}E01 not in episode list after 60 s — "
               "metadata may not have loaded; try again later")
        return False

    record("Sonarr", "PASS", f"S{season:02d}E01 found: '{s01e01.get('title','?')}'")

    # Mark only S01E01 as monitored (everything else stays unmonitored)
    cmd_id = None
    ep_id  = s01e01["id"]
    try:
        requests.put(f"{base}/api/v3/episode/{ep_id}",
                     headers=hdrs, json={**s01e01, "monitored": True},
                     timeout=10)
    except Exception:
        pass

    # Trigger EpisodeSearch for S01E01 only — never SeasonSearch
    try:
        r = requests.post(f"{base}/api/v3/command", headers=hdrs,
                          json={"name": "EpisodeSearch", "episodeIds": [ep_id]},
                          timeout=15)
        if r.status_code in (200, 201):
            cmd_id = r.json().get("id")
            record("Sonarr", "PASS",
                   f"S{season:02d}E01 search submitted (cmd_id={cmd_id})")
        else:
            record("Sonarr", "WARN", f"Episode search HTTP {r.status_code}")
    except Exception as exc:
        record("Sonarr", "WARN", f"Could not submit episode search: {exc}")

    # Wait for command (up to 90 s)
    if cmd_id:
        deadline = time.time() + 90
        while time.time() < deadline:
            try:
                st = requests.get(f"{base}/api/v3/command/{cmd_id}",
                                  headers=hdrs, timeout=10).json().get("status","")
                if st in ("completed","failed"):
                    record("Sonarr", "PASS" if st=="completed" else "WARN",
                           f"Search command {st}")
                    break
            except Exception:
                pass
            time.sleep(3)

    # Poll history + queue (60 s)
    print(f"  Polling history/queue for grab confirmation (60 s)...")
    found    = False
    deadline = time.time() + 60
    while not found and time.time() < deadline:
        try:
            hist = requests.get(
                f"{base}/api/v3/history",
                headers=hdrs, params={"seriesId": series_id, "pageSize": 20},
                timeout=10
            ).json().get("records", [])
            for h in hist:
                if h.get("eventType") == "grabbed":
                    record("Sonarr", "PASS",
                           f"Auto-grabbed: '{h.get('sourceTitle','?')}'")
                    found = True
                    break
            if not found:
                q = requests.get(f"{base}/api/v3/queue",
                                 headers=hdrs, timeout=10).json()
                in_q = [r for r in q.get("records",[]) if r.get("seriesId") == series_id]
                if in_q:
                    record("Sonarr", "PASS",
                           f"Download queued: '{in_q[0].get('title','?')}'")
                    found = True
        except Exception:
            pass
        if not found:
            time.sleep(5)

    if found:
        return True

    # Fallback: interactive release endpoint
    print("  Auto-grab did not fire — trying interactive release search...")
    ep_params: Dict[str, Any] = {"seriesId": series_id}
    if s01e01:
        ep_params["episodeId"] = s01e01["id"]
    else:
        ep_params["seasonNumber"] = season

    try:
        releases = requests.get(f"{base}/api/v3/release",
                                headers=hdrs, params=ep_params, timeout=60).json()
    except Exception as exc:
        record("Sonarr", "FAIL", f"Release search failed: {exc}")
        return False

    if not isinstance(releases, list) or not releases:
        record("Sonarr", "FAIL",
               "0 releases from Prowlarr — check indexer config and FlareSolverr")
        return False

    top = max((r.get("customFormatScore", 0) for r in releases), default=0)
    note = (f", best score: +{top}"
            if top > 0
            else " (all +0 — see Priority 2 in ROADMAP)")
    record("Sonarr", "PASS" if top > 0 else "WARN",
           f"{len(releases)} releases from Prowlarr{note}")
    return True


# --- Step 3: Deluge -----------------------------------------------------------
def step3_deluge(cfg: Dict, keys: Dict, added: Dict) -> bool:
    head("Step 3 -- Deluge: confirm download activity")

    password = keys.get("deluge_password")
    if not password:
        record("Deluge", "FAIL", "Deluge password not found")
        return False

    rpc_url = f"http://127.0.0.1:{cfg['ports']['DelugeWeb']}/json"
    session = requests.Session()

    def _rpc(method: str, params: Optional[list] = None) -> Any:
        resp = session.post(
            rpc_url,
            json={"method": method, "params": params or [], "id": 1},
            timeout=10
        )
        data = resp.json()
        if data.get("error"):
            raise Exception(data["error"].get("message", str(data["error"])))
        return data.get("result")

    # Login to Deluge Web UI (auth.login, not daemon.login -- daemon uses RenCode protocol)
    try:
        result = _rpc("auth.login", [password])
        if result is not True:
            record("Deluge", "FAIL", "Web UI login rejected -- check password in secrets/deluge_auth.txt")
            return False
    except Exception as exc:
        record("Deluge", "FAIL", f"Web UI login failed: {exc}")
        return False

    # Verify daemon is connected through the Web UI
    try:
        hosts = _rpc("web.get_hosts") or []
        if hosts:
            host_id = hosts[0][0]
            status = _rpc("web.get_host_status", [host_id])
            if status and len(status) >= 2 and status[1] == "Online":
                record("Deluge", "PASS", f"Web UI connected to daemon v{status[2]} (host online)")
                return True
            else:
                record("Deluge", "WARN", f"Daemon host status: {status}")
                return False
        else:
            record("Deluge", "FAIL", "No daemon hosts configured in Web UI")
            return False
    except Exception as exc:
        record("Deluge", "FAIL", f"Could not verify daemon connection: {exc}")
        return False


# ─── Step 4: Jellyfin ─────────────────────────────────────────────────────────
def step4_jellyfin(cfg: Dict, added: Dict) -> bool:
    head("Step 4 — Jellyfin: confirm media imported")

    base     = _url(cfg, "Jellyfin")
    emby_hdr = (
        'MediaBrowser Client="win-seedbox-sanity", Device="Python", '
        'DeviceId="sanity-check-001", Version="1.0.0"'
    )

    # Authenticate
    try:
        r = requests.post(
            f"{base}/Users/AuthenticateByName",
            json={"Username": cfg["admin_user"], "Pw": cfg["admin_pass"]},
            headers={"X-Emby-Authorization": emby_hdr,
                     "Content-Type": "application/json"},
            timeout=15,
        )
        r.raise_for_status()
        token   = r.json().get("AccessToken", "")
        user_id = r.json().get("User", {}).get("Id", "")
        record("Jellyfin", "PASS",
               f"Authenticated (user_id={user_id[:8]}...)")
    except Exception as exc:
        record("Jellyfin", "FAIL", f"Authentication failed: {exc}")
        return False

    auth_hdr = {
        "X-Emby-Authorization": (
            f'MediaBrowser Client="win-seedbox-sanity", Device="Python", '
            f'DeviceId="sanity-check-001", Version="1.0.0", Token="{token}"'
        )
    }

    # Trigger a library scan so newly imported files are indexed
    try:
        r = requests.post(f"{base}/Library/Refresh",
                          headers=auth_hdr, timeout=15)
        record("Jellyfin", "PASS" if r.status_code in (200, 204) else "WARN",
               f"Library scan triggered (HTTP {r.status_code})")
    except Exception as exc:
        record("Jellyfin", "WARN", f"Library scan trigger failed: {exc}")

    # Verify media libraries exist
    try:
        r = requests.get(f"{base}/Library/VirtualFolders", headers=auth_hdr, timeout=10)
        libs = r.json() if r.ok else []
        n    = len(libs) if isinstance(libs, list) else 0
        record("Jellyfin", "PASS" if n else "WARN",
               f"{n} media librar{'y' if n==1 else 'ies'} configured")
    except Exception:
        pass

    # ── Poll for the movie ────────────────────────────────────────────────────
    search_term = cfg["sanity_movie"]
    print(f"  Polling Jellyfin every {cfg['import_poll_interval']} s "
          f"(max {cfg['import_poll_secs']} s) for movie '{search_term}'...")
    found    = False
    deadline = time.time() + cfg["import_poll_secs"]
    while not found and time.time() < deadline:
        try:
            r = requests.get(
                f"{base}/Users/{user_id}/Items",
                headers=auth_hdr,
                params={"searchTerm": search_term, "Recursive": "true",
                        "IncludeItemTypes": "Movie", "Limit": 5},
                timeout=10,
            )
            items = r.json().get("Items", [])
            if items:
                item = items[0]
                record("Jellyfin", "PASS",
                       f"Movie in library: '{item.get('Name')}' "
                       f"({item.get('ProductionYear')})")
                found = True
        except Exception:
            pass
        if not found:
            time.sleep(cfg["import_poll_interval"])

    if not found:
        record("Jellyfin", "WARN",
               f"Movie '{search_term}' not found after {cfg['import_poll_secs']} s "
               "— download/import still in progress (run --steps 4 again later)")

    # ── Poll for the TV episode ───────────────────────────────────────────────
    # Jellyfin stores episodes under their own title ("Pilot"), not the series
    # name, so searching by series title on the Episode type fails. Instead:
    # find the series item first, then poll Shows/{seriesId}/Episodes.
    series_title = cfg["sanity_series"]
    season       = cfg.get("sanity_series_season", 1)
    print(f"  Polling for '{series_title}' S{season:02d}E01...")
    ep_found  = False
    series_id = None
    ep_id     = None
    deadline  = time.time() + cfg["import_poll_secs"]

    # 1. Locate the Series item by name
    while series_id is None and time.time() < deadline:
        try:
            r = requests.get(
                f"{base}/Users/{user_id}/Items",
                headers=auth_hdr,
                params={"searchTerm": series_title, "Recursive": "true",
                        "IncludeItemTypes": "Series", "Limit": 5,
                        "Fields": "Id"},
                timeout=10,
            )
            items = r.json().get("Items", [])
            if items:
                series_id = items[0].get("Id", "")
        except Exception:
            pass
        if series_id is None:
            time.sleep(cfg["import_poll_interval"])

    if series_id is None:
        record("Jellyfin", "WARN",
               f"Series '{series_title}' not found in Jellyfin after "
               f"{cfg['import_poll_secs']} s")
        return True

    # 2. Poll Shows/{seriesId}/Episodes for S01E01
    while not ep_found and time.time() < deadline:
        try:
            r = requests.get(
                f"{base}/Shows/{series_id}/Episodes",
                headers=auth_hdr,
                params={"UserId": user_id, "SeasonNumber": season,
                        "IsMissing": "false", "Fields": "Id,IndexNumber"},
                timeout=10,
            )
            items = r.json().get("Items", []) if r.ok else []
            ep_item = next(
                (e for e in items if e.get("IndexNumber") == 1),
                items[0] if items else None
            )
            if ep_item:
                ep_id = ep_item.get("Id", "")
                record("Jellyfin", "PASS",
                       f"Episode in library: '{ep_item.get('Name','?')}' "
                       f"(S{season:02d}E{ep_item.get('IndexNumber',0):02d})")
                ep_found = True
        except Exception:
            pass
        if not ep_found:
            time.sleep(cfg["import_poll_interval"])

    if not ep_found:
        record("Jellyfin", "WARN",
               f"Episode '{series_title}' S{season:02d}E01 not found after "
               f"{cfg['import_poll_secs']} s — download/import still in progress")
        return True

    # ── Verify series hierarchy (Shows/Seasons must not be empty) ─────────────
    # Sonarr fires the Jellyfin notification immediately at import, before TVDB
    # metadata finishes downloading. This can leave the season detached from the
    # series in Jellyfin's hierarchy, breaking the web player (it crashes with
    # "Uncaught (in promise) undefined" when Shows/Episodes returns 0).
    # Fix: detect the broken state and force a metadata refresh.
    if series_id:
        try:
            seasons_r = requests.get(
                f"{base}/Shows/{series_id}/Seasons",
                headers=auth_hdr, params={"UserId": user_id}, timeout=10
            )
            n_seasons = seasons_r.json().get("TotalRecordCount", 0) if seasons_r.ok else 0
        except Exception:
            n_seasons = 0

        if n_seasons == 0:
            record("Jellyfin", "WARN",
                   "Season hierarchy broken (Shows/Seasons returned 0) — "
                   "triggering metadata refresh to fix")
            # Refresh series + all children
            for item_id in [series_id, ep_id]:
                try:
                    requests.post(
                        f"{base}/Items/{item_id}/Refresh",
                        headers=auth_hdr,
                        params={"MetadataRefreshMode": "FullRefresh",
                                "ImageRefreshMode":    "FullRefresh",
                                "ReplaceAllMetadata":  "false"},
                        timeout=15,
                    )
                except Exception:
                    pass

            # Wait up to 30 s for the refresh to fix the hierarchy
            print("  Waiting up to 30 s for metadata refresh...")
            fix_deadline = time.time() + 30
            while time.time() < fix_deadline:
                time.sleep(5)
                try:
                    r2 = requests.get(
                        f"{base}/Shows/{series_id}/Seasons",
                        headers=auth_hdr, params={"UserId": user_id}, timeout=10
                    )
                    if r2.ok and r2.json().get("TotalRecordCount", 0) > 0:
                        n_seasons = r2.json()["TotalRecordCount"]
                        break
                except Exception:
                    pass

            if n_seasons > 0:
                record("Jellyfin", "PASS",
                       f"Season hierarchy fixed — {n_seasons} season(s) now visible")
            else:
                record("Jellyfin", "WARN",
                       "Season hierarchy still broken after refresh — "
                       "retry manually: Jellyfin → Friends → ⋮ → Refresh Metadata")
        else:
            record("Jellyfin", "PASS",
                   f"Series hierarchy OK — {n_seasons} season(s) in Shows/Seasons")

    return True  # Step 4 is non-fatal: import timing depends on download size


# ─── Step 5: Bazarr ───────────────────────────────────────────────────────────
def step5_bazarr(cfg: Dict, keys: Dict) -> bool:
    head("Step 5 — Bazarr: subtitle detection check")

    api_key = keys.get("bazarr")
    if not api_key:
        record("Bazarr", "WARN", "API key not found — subtitle check skipped")
        return True

    base = _url(cfg, "Bazarr")
    hdrs = {"X-Api-Key": api_key}

    # Health
    try:
        r = requests.get(f"{base}/api/system/health", headers=hdrs, timeout=10)
        record("Bazarr", "PASS" if r.status_code == 200 else "WARN",
               f"Health: HTTP {r.status_code}")
    except Exception as exc:
        record("Bazarr", "WARN", f"Health check failed: {exc}")
        return True

    # Sonarr / Radarr connection status
    try:
        settings = requests.get(f"{base}/api/system/settings",
                                headers=hdrs, timeout=10).json()
        for app in ("sonarr", "radarr"):
            app_cfg = settings.get(app, {})
            connected = bool(app_cfg.get("apikey"))
            record("Bazarr", "PASS" if connected else "WARN",
                   f"Bazarr ↔ {app.title()}: "
                   f"{'connected (API key set)' if connected else 'not connected — run layer2'}")
    except Exception as exc:
        record("Bazarr", "WARN", f"Could not check Bazarr connections: {exc}")

    # Provider count
    try:
        resp = requests.get(f"{base}/api/providers", headers=hdrs, timeout=10).json()
        if isinstance(resp, dict):
            providers = resp.get("data", [])
        elif isinstance(resp, list):
            providers = resp
        else:
            providers = []
        n = len(providers)
        note = ("" if n else
                " — add OpenSubtitles.com / Titlovi credentials to config.json")
        record("Bazarr", "PASS" if n else "WARN",
               f"{n} subtitle provider(s) enabled{note}")
    except Exception as exc:
        record("Bazarr", "WARN", f"Could not check providers: {exc}")

    # Wanted queue
    try:
        mw = requests.get(f"{base}/api/movies/wanted",
                          headers=hdrs, params={"start":0,"length":20},
                          timeout=10).json()
        ew = requests.get(f"{base}/api/episodes/wanted",
                          headers=hdrs, params={"start":0,"length":20},
                          timeout=10).json()
        mc = mw.get("total", 0)
        ec = ew.get("total", 0)
        record("Bazarr", "PASS" if (mc + ec) > 0 else "WARN",
               f"Wanted subtitles: {mc} movie(s), {ec} episode(s)"
               + (" (queue empty — media not yet imported or subtitles found)"
                  if (mc + ec) == 0 else ""))
    except Exception as exc:
        record("Bazarr", "WARN", f"Could not check wanted queue: {exc}")

    # Recent history (last 5 events)
    try:
        hist = requests.get(f"{base}/api/history/stats",
                            headers=hdrs, timeout=10).json()
        total = hist.get("total", 0)
        if total:
            record("Bazarr", "PASS",
                   f"Bazarr history: {total} subtitle event(s) recorded")
    except Exception:
        pass

    return True


# ─── Cleanup ──────────────────────────────────────────────────────────────────
def cleanup(cfg: Dict, keys: Dict, added: Dict) -> None:
    head("Cleanup")

    rad_key  = keys.get("radarr")
    movie_id = added.get("radarr_movie_id")
    if movie_id and not added.get("radarr_existed") and rad_key:
        try:
            r = requests.delete(
                f"{_url(cfg,'Radarr')}/api/v3/movie/{movie_id}",
                headers={"X-Api-Key": rad_key},
                params={"deleteFiles": "true", "addImportExclusion": "false"},
                timeout=20,
            )
            record("Cleanup", "PASS" if r.status_code in (200, 204) else "WARN",
                   f"Radarr: removed movie id={movie_id}"
                   f" (HTTP {r.status_code}, files deleted)")
        except Exception as exc:
            record("Cleanup", "WARN", f"Could not remove movie from Radarr: {exc}")

    son_key   = keys.get("sonarr")
    series_id = added.get("sonarr_series_id")
    if series_id and not added.get("sonarr_existed") and son_key:
        try:
            r = requests.delete(
                f"{_url(cfg,'Sonarr')}/api/v3/series/{series_id}",
                headers={"X-Api-Key": son_key},
                params={"deleteFiles": "true"},
                timeout=20,
            )
            record("Cleanup", "PASS" if r.status_code in (200, 204) else "WARN",
                   f"Sonarr: removed series id={series_id}"
                   f" (HTTP {r.status_code}, files deleted)")
        except Exception as exc:
            record("Cleanup", "WARN", f"Could not remove series from Sonarr: {exc}")

    rpc   = keys.get("deluge_password")
    hashes = added.get("deluge_hashes", [])
    if hashes and rpc:
        rpc_url = f"http://127.0.0.1:{cfg['ports']['DelugeWeb']}/json"
        session = requests.Session()
        # Login to Web UI first
        logged_in = False
        try:
            login_resp = session.post(rpc_url, json={
                "method":"auth.login","params":[rpc],"id":1
            }, timeout=5)
            logged_in = login_resp.json().get("result") is True
        except Exception:
            pass
        if not logged_in:
            record("Cleanup", "WARN", "Deluge login failed -- cannot cancel downloads")
            return
        removed = 0
        for h in hashes:
            try:
                resp = session.post(rpc_url, json={
                    "method":"core.remove_torrent","params":[h, True],"id":2
                }, timeout=5)
                if not resp.json().get("error"):
                    removed += 1
            except Exception:
                pass
        if removed:
            record("Cleanup", "PASS", f"Cancelled {len(hashes)} Deluge download(s)")


# ─── Summary ──────────────────────────────────────────────────────────────────
def print_summary() -> bool:
    print(f"\n{_c('═' * 60, CYAN)}")
    print(_c(f"  {'SANITY CHECK RESULTS':^58}", CYAN + BOLD))
    print(_c('═' * 60, CYAN))
    col = max((len(r["step"]) for r in _results), default=10)
    sc  = {"PASS": GREEN, "FAIL": RED, "WARN": YELLOW}
    for r in _results:
        print(f"  [{_c(r['status'], sc[r['status']])}] "
              f"{r['step']:<{col}}  {r['msg']}")
    passed = sum(1 for r in _results if r["status"] == "PASS")
    failed = sum(1 for r in _results if r["status"] == "FAIL")
    warned = sum(1 for r in _results if r["status"] == "WARN")
    print(f"\n  {_c(f'PASS: {passed}', GREEN)}   "
          f"{_c(f'FAIL: {failed}', RED)}   "
          f"{_c(f'WARN: {warned}', YELLOW)}")
    print(_c('═' * 60, CYAN))
    return failed == 0


# ─── Main ─────────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="win-seedbox end-to-end sanity check",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Steps:\n"
            "  0  Infrastructure  (services, APIs, Prowlarr wiring, disk space)\n"
            "  1  Radarr          (add movie, search, verify grab)\n"
            "  2  Sonarr          (add series S01, search, verify grab)\n"
            "  3  Deluge           (poll for active downloads)\n"
            "  4  Jellyfin        (poll for imported media — long timeout)\n"
            "  5  Bazarr          (subtitle provider health, wanted queue)\n"
        ),
    )
    parser.add_argument(
        "--steps", default="0,1,2,3,4,5",
        help="Comma-separated steps to run (default: all). E.g. --steps 0  or  --steps 0,1,2",
    )
    parser.add_argument(
        "--no-cleanup", action="store_true",
        help="Skip cleanup after run (leave added movie/series for inspection)",
    )
    parser.add_argument(
        "--config", default=None,
        help="Path to sanity_config.json (default: same directory as this script)",
    )
    args = parser.parse_args()

    steps_to_run: set = set()
    for part in args.steps.split(","):
        part = part.strip()
        if part.isdigit():
            steps_to_run.add(int(part))

    script_dir      = os.path.dirname(os.path.abspath(__file__))
    sanity_cfg_path = args.config or os.path.join(script_dir, "sanity_config.json")

    if not os.path.exists(sanity_cfg_path):
        sys.exit(f"ERROR: sanity_config.json not found at {sanity_cfg_path}")

    print(f"\n{_c('win-seedbox Sanity Check', CYAN + BOLD)}")
    print(f"Config : {sanity_cfg_path}")
    print(f"Steps  : {sorted(steps_to_run)}")

    cfg  = load_config(sanity_cfg_path)
    keys = discover_keys(cfg)

    print(f"Domain : {cfg['domain_mode'].upper()}  |  "
          f"Movie : {cfg['sanity_movie']} ({cfg.get('sanity_movie_year','?')})  |  "
          f"Series: {cfg['sanity_series']} S{cfg.get('sanity_series_season',1):02d}")

    missing = [k for k, v in keys.items()
               if v is None and k not in ("bazarr", "jellyfin")]
    if missing:
        print(f"{_c('Warning', YELLOW)}: API keys not discovered for: {', '.join(missing)}")

    added: Dict[str, Any] = {}
    try:
        if 0 in steps_to_run:
            step0_infrastructure(cfg, keys)
        if 1 in steps_to_run:
            step1_radarr(cfg, keys, added)
        if 2 in steps_to_run:
            step2_sonarr(cfg, keys, added)
        if 3 in steps_to_run:
            step3_deluge(cfg, keys, added)
        if 4 in steps_to_run:
            step4_jellyfin(cfg, added)
        if 5 in steps_to_run:
            step5_bazarr(cfg, keys)
    finally:
        if not args.no_cleanup and added:
            cleanup(cfg, keys, added)

    sys.exit(0 if print_summary() else 1)


if __name__ == "__main__":
    main()
