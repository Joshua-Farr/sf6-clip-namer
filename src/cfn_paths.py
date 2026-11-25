"""Paths for CFN / Buckler companion credentials and match cache."""

from __future__ import annotations

import os
from pathlib import Path

APP_DIR_NAME = "sf6-clip-namer"


def app_data_dir() -> Path:
    if os.name == "nt":
        base = os.environ.get("APPDATA")
        if base:
            path = Path(base) / APP_DIR_NAME
        else:
            path = Path.home() / "AppData" / "Roaming" / APP_DIR_NAME
    else:
        path = Path.home() / ".config" / APP_DIR_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def default_cookie_path() -> Path:
    return app_data_dir() / "buckler_cookie.txt"


def default_match_cache_path() -> Path:
    return app_data_dir() / "latest_match.json"


def default_log_path() -> Path:
    return app_data_dir() / "cfn_fetch.log"
