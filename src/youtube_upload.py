"""Resumable YouTube video upload via the YouTube Data API."""

from __future__ import annotations

import mimetypes
from pathlib import Path
from typing import Optional

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload
from google.oauth2.credentials import Credentials

from youtube_auth import AuthError, get_credentials
from youtube_state import (
    STATUS_FAILED,
    STATUS_PENDING,
    STATUS_UPLOADING,
    STATUS_UPLOADED,
    UploadStateStore,
)


def _guess_mime(path: Path) -> str:
    mime, _ = mimetypes.guess_type(str(path))
    return mime or "video/mp4"


def upload_video(
    video_path: str | Path,
    *,
    title: Optional[str] = None,
    description: Optional[str] = None,
    privacy: str = "unlisted",
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
    state_store: Optional[UploadStateStore] = None,
    interactive_auth: bool = False,
) -> dict:
    """Upload a local video as unlisted (or configured privacy).

    Returns state entry dict. Never deletes the local file.
    """
    path = Path(video_path)
    if not path.is_file():
        raise FileNotFoundError(f"video not found: {path}")

    store = state_store or UploadStateStore()
    skip, reason = store.should_skip_upload(path)
    if skip:
        entry = store.get(path) or {}
        entry = dict(entry)
        entry["skipped"] = True
        entry["skip_reason"] = reason
        return entry

    resolved_title = title or path.stem
    resolved_description = description if description is not None else ""
    privacy_status = (privacy or "unlisted").lower()
    if privacy_status not in {"unlisted", "private", "public"}:
        privacy_status = "unlisted"

    store.set_status(
        path,
        STATUS_PENDING,
        title=resolved_title,
        privacy=privacy_status,
        error=None,
    )
    store.set_status(
        path,
        STATUS_UPLOADING,
        title=resolved_title,
        privacy=privacy_status,
        error=None,
    )

    try:
        creds: Credentials = get_credentials(
            client_secret_path=client_secret_path,
            token_path=token_path,
            interactive=interactive_auth,
        )
    except AuthError as exc:
        store.set_status(path, STATUS_FAILED, error=str(exc))
        raise

    try:
        youtube = build("youtube", "v3", credentials=creds, cache_discovery=False)
        body = {
            "snippet": {
                "title": resolved_title,
                "description": resolved_description,
            },
            "status": {
                "privacyStatus": privacy_status,
                "selfDeclaredMadeForKids": False,
            },
        }
        media = MediaFileUpload(
            str(path),
            mimetype=_guess_mime(path),
            resumable=True,
            chunksize=8 * 1024 * 1024,
        )
        request = youtube.videos().insert(
            part="snippet,status",
            body=body,
            media_body=media,
        )

        response = None
        while response is None:
            _status, response = request.next_chunk()

        video_id = response.get("id")
        if not video_id:
            raise RuntimeError(f"upload succeeded but no video id: {response}")

        url = f"https://youtu.be/{video_id}"
        return store.set_status(
            path,
            STATUS_UPLOADED,
            title=resolved_title,
            privacy=privacy_status,
            youtube_video_id=video_id,
            youtube_url=url,
            error=None,
        )
    except HttpError as exc:
        message = f"YouTube API error: {exc}"
        store.set_status(path, STATUS_FAILED, error=message)
        raise RuntimeError(message) from exc
    except Exception as exc:  # noqa: BLE001
        message = str(exc)
        store.set_status(path, STATUS_FAILED, error=message)
        raise
