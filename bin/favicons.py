#!/usr/bin/env python3
# From Omarchy Spaces (MIT, (c) 2026 Tornike Gomareli), so the minimap shows
# the same tab favicons as Spaces; only the cache directory differs.
"""Map Brave / Chromium windows to the current tab's site favicon.

Hyprland only reports class=brave-origin for a normal browser window, so the
bar would otherwise show the Brave icon for every tab. Chromium already keeps
the page title in the window title and the favicon in its local sqlite DBs.
This prints {normalizedAddress: {source, name, host}} for those windows.
"""
from __future__ import annotations

import json
import re
import sqlite3
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse

BROWSER_CLASSES = {
    "brave-origin",
    "brave-browser",
    "brave-browser-stable",
    "brave",
    "chromium",
    "chromium-browser",
    "google-chrome",
    "google-chrome-stable",
    "helium",
}

TITLE_SUFFIXES = (
    " - Brave Origin",
    " - Brave",
    " - Chromium",
    " - Google Chrome",
    " — Brave Origin",
    " — Brave",
)

INTERNAL_SCHEMES = (
    "chrome:",
    "brave:",
    "about:",
    "chrome-extension:",
    "devtools:",
    "view-source:",
)

PROFILE_ROOTS = (
    Path.home() / ".config" / "BraveSoftware" / "Brave-Origin",
    Path.home() / ".config" / "BraveSoftware" / "Brave-Browser",
    Path.home() / ".config" / "chromium",
    Path.home() / ".config" / "google-chrome",
)

CACHE_DIR = Path.home() / ".cache" / "austraz-minimap" / "favicons"
HOST_RE = re.compile(r"[^a-zA-Z0-9._-]+")
COUNT_PREFIX = re.compile(r"^\(\d+\)\s*")


def is_browser_class(app_id: str) -> bool:
    return str(app_id or "").lower() in BROWSER_CLASSES


def normalize_address(address: str) -> str:
    value = str(address or "").lower()
    return value[2:] if value.startswith("0x") else value


def strip_browser_suffix(title: str) -> str:
    text = str(title or "").strip()
    for suffix in TITLE_SUFFIXES:
        if text.endswith(suffix):
            return text[: -len(suffix)].strip()
    return text


def page_title_candidates(title: str) -> list[str]:
    stripped = strip_browser_suffix(title)
    out = []
    for value in (stripped, COUNT_PREFIX.sub("", stripped).strip()):
        if value and value not in out:
            out.append(value)
    return out


def skip_url(url: str) -> bool:
    value = str(url or "").lower()
    return (not value) or value.startswith(INTERNAL_SCHEMES)


def display_name(page_title: str, host: str) -> str:
    parts = [part.strip() for part in page_title.split("|") if part.strip()]
    if parts:
        last = parts[-1]
        if last.lower() not in {"brave origin", "brave", "chromium", "google chrome"}:
            return last
    return host


def url_variants(url: str) -> list[str]:
    parsed = urlparse(url)
    if not parsed.scheme or not parsed.netloc:
        return [url] if url else []
    origin = f"{parsed.scheme}://{parsed.netloc}"
    variants = [
        url,
        urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, parsed.query, "")),
        urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", "")),
        origin + "/",
        origin,
    ]
    out = []
    for value in variants:
        if value and value not in out:
            out.append(value)
    return out


def profile_dirs() -> list[Path]:
    found = []
    for root in PROFILE_ROOTS:
        if not root.is_dir():
            continue
        for child in [root / "Default", *sorted(root.glob("Profile *"))]:
            if (child / "History").is_file() and child not in found:
                found.append(child)
    return found


_db_cache: dict[str, sqlite3.Connection | None] = {}


def open_db(path: Path) -> sqlite3.Connection | None:
    key = str(path)
    if key in _db_cache:
        return _db_cache[key]
    if not path.is_file():
        _db_cache[key] = None
        return None
    # Chromium keeps a write lock. immutable reads the last checkpoint
    # instead of waiting on the live WAL.
    try:
        conn = sqlite3.connect(path.resolve().as_uri() + "?immutable=1", uri=True)
        conn.execute("PRAGMA query_only=ON")
    except sqlite3.Error:
        _db_cache[key] = None
        return None
    _db_cache[key] = conn
    return conn


def lookup_url(title: str) -> tuple[str, str] | None:
    candidates = page_title_candidates(title)
    if not candidates:
        return None
    best = None
    for profile in profile_dirs():
        conn = open_db(profile / "History")
        if conn is None:
            continue
        try:
            for candidate in candidates:
                row = conn.execute(
                    "SELECT url, title, last_visit_time FROM urls WHERE title = ? "
                    "ORDER BY last_visit_time DESC LIMIT 1",
                    (candidate,),
                ).fetchone()
                if not row:
                    continue
                url, page_title, visit = row
                if skip_url(url):
                    continue
                if best is None or visit >= best[0]:
                    best = (visit, url, page_title or candidate)
        except sqlite3.Error:
            continue
    if best is None:
        return None
    return best[1], best[2]


def bitmap_looks_usable(data: bytes, width: int) -> bool:
    if not data or width < 16 or len(data) < 64:
        return False
    return data[:8] == b"\x89PNG\r\n\x1a\n" or data[:2] == b"\xff\xd8" or data[:4] == b"RIFF"


def lookup_bitmap(page_url: str) -> bytes | None:
    variants = url_variants(page_url)
    best = None
    for profile in profile_dirs():
        conn = open_db(profile / "Favicons")
        if conn is None:
            continue
        try:
            for variant in variants:
                rows = conn.execute(
                    "SELECT b.width, b.image_data FROM icon_mapping m "
                    "JOIN favicon_bitmaps b ON b.icon_id = m.icon_id "
                    "WHERE m.page_url = ? ORDER BY b.width DESC LIMIT 6",
                    (variant,),
                ).fetchall()
                for width, data in rows:
                    if isinstance(data, bytes) and bitmap_looks_usable(data, width):
                        if best is None or width > best[0]:
                            best = (width, data)
                if best:
                    break
        except sqlite3.Error:
            continue
        if best:
            break
    return None if best is None else best[1]


def cache_path(host: str) -> Path:
    safe = HOST_RE.sub("_", host).strip("._") or "site"
    return CACHE_DIR / f"{safe}.png"


def write_icon(host: str, data: bytes) -> str:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = cache_path(host)
    tmp = path.with_suffix(".png.tmp")
    tmp.write_bytes(data)
    tmp.replace(path)
    return str(path)


def resolve_title(title: str) -> dict | None:
    found = lookup_url(title)
    if found is None:
        return None
    url, page_title = found
    host = urlparse(url).hostname or ""
    if host.startswith("www."):
        host = host[4:]
    if not host:
        return None
    path = cache_path(host)
    if not path.is_file() or path.stat().st_size == 0:
        blob = lookup_bitmap(url)
        if blob is None:
            return None
        write_icon(host, blob)
    return {
        "source": str(path),
        "name": display_name(page_title, host),
        "host": host,
    }


def load_clients() -> list[dict]:
    try:
        return json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def resolve_windows(windows: list[dict]) -> dict:
    out = {}
    for window in windows:
        try:
            if not is_browser_class(window.get("class") or window.get("appId") or ""):
                continue
            address = normalize_address(window.get("address") or "")
            title = window.get("title") or ""
            if not address or not title:
                continue
            info = resolve_title(title)
            if info:
                out[address] = info
        except Exception:
            continue
    return out


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return 0 if _self_test() else 1
    if argv[1:2] == ["--title"]:
        fake = [{"address": "0xtest", "class": "brave-origin", "title": " ".join(argv[2:])}]
        json.dump(resolve_windows(fake), sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    json.dump(resolve_windows(load_clients()), sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def _self_test() -> bool:
    assert is_browser_class("brave-origin")
    assert is_browser_class("Brave-Origin")
    assert not is_browser_class("brave-mail.google.com__mail_u_1_-Default")
    assert not is_browser_class("foot")
    assert normalize_address("0x56B433C71AF0") == "56b433c71af0"
    title = "(18) Inbox | user@example.com | Proton Mail - Brave Origin"
    assert strip_browser_suffix(title).endswith("Proton Mail")
    assert page_title_candidates(title)[0].startswith("(18)")
    assert skip_url("chrome://newtab")
    assert not skip_url("https://mail.proton.me/u/2/inbox")
    assert display_name(strip_browser_suffix(title), "mail.proton.me") == "Proton Mail"
    return True


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
