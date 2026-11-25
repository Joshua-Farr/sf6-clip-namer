"""OAuth 2.0 helpers for the YouTube Data API (installed / desktop app)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow

from youtube_paths import SCOPES, default_client_secret_path, default_token_path


class AuthError(Exception):
    """Raised when OAuth credentials are missing or cannot be refreshed."""


def _load_client_secrets(client_secret_path: Path) -> dict:
    if not client_secret_path.is_file():
        raise AuthError(
            f"OAuth client secret not found: {client_secret_path}\n"
            "Download a Desktop OAuth client JSON from Google Cloud Console "
            "and save it to this path (see README)."
        )
    with client_secret_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def get_credentials(
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
    interactive: bool = True,
) -> Credentials:
    """Load or refresh OAuth credentials; optionally run interactive auth."""
    client_secret_path = Path(client_secret_path or default_client_secret_path())
    token_path = Path(token_path or default_token_path())

    creds: Optional[Credentials] = None
    if token_path.is_file():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
            _save_token(creds, token_path)
            return creds
        except Exception as exc:  # noqa: BLE001 - surface as AuthError
            if not interactive:
                raise AuthError(
                    "YouTube authentication expired and refresh failed. "
                    f"Re-run: python youtube_uploader.py auth. Detail: {exc}"
                ) from exc
            creds = None

    if not interactive:
        raise AuthError(
            "YouTube authentication required. "
            "Run: python youtube_uploader.py auth"
        )

    _load_client_secrets(client_secret_path)  # validate presence early
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret_path), SCOPES)
    creds = flow.run_local_server(port=0)
    _save_token(creds, token_path)
    return creds


def _save_token(creds: Credentials, token_path: Path) -> None:
    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(creds.to_json(), encoding="utf-8")


def run_auth_flow(
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
) -> Path:
    """Interactive browser OAuth; returns path to saved token."""
    token_path = Path(token_path or default_token_path())
    get_credentials(
        client_secret_path=client_secret_path,
        token_path=token_path,
        interactive=True,
    )
    return token_path
