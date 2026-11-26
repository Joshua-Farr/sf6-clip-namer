"""Paths and helpers for YouTube companion credentials/state."""

from __future__ import annotations

import os
from pathlib import Path

APP_DIR_NAME = "sf6-clip-namer"
SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]
# Separate token so a Sheets problem can never break YouTube uploads.
SHEETS_SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]


def app_data_dir() -> Path:
    """Return %AppData%/sf6-clip-namer on Windows, or ~/.config equivalent."""
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


def default_client_secret_path() -> Path:
    return app_data_dir() / "client_secret.json"


def default_token_path() -> Path:
    return app_data_dir() / "token.json"


def default_sheets_token_path() -> Path:
    return app_data_dir() / "sheets_token.json"


def default_state_path() -> Path:
    return app_data_dir() / "upload_state.json"


def default_log_path() -> Path:
    return app_data_dir() / "youtube_uploader.log"
