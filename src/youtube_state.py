"""Lightweight JSON upload-state tracking for processed clips."""

from __future__ import annotations

import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Optional

from youtube_paths import default_state_path

STATUS_PENDING = "pending"
STATUS_UPLOADING = "uploading"
STATUS_UPLOADED = "uploaded"
STATUS_FAILED = "failed"


def normalize_path(path: str | Path) -> str:
    return os.path.normcase(os.path.abspath(os.path.normpath(str(path))))


class UploadStateStore:
    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = Path(path or default_state_path())
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _load(self) -> dict[str, Any]:
        if not self.path.is_file():
            return {"clips": {}}
        try:
            with self.path.open("r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            return {"clips": {}}
        if not isinstance(data, dict):
            return {"clips": {}}
        clips = data.get("clips")
        if not isinstance(clips, dict):
            data["clips"] = {}
        return data

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        raw = json.dumps(data, indent=2, sort_keys=True)
        # Atomic-ish replace on Windows.
        fd, tmp_name = tempfile.mkstemp(
            dir=str(self.path.parent),
            prefix=".upload_state_",
            suffix=".tmp",
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(raw)
            os.replace(tmp_name, self.path)
        except Exception:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise

    def get(self, video_path: str | Path) -> Optional[dict[str, Any]]:
        key = normalize_path(video_path)
        return self._load()["clips"].get(key)

    def set_status(
        self,
        video_path: str | Path,
        status: str,
        *,
        title: Optional[str] = None,
        privacy: Optional[str] = None,
        youtube_video_id: Optional[str] = None,
        youtube_url: Optional[str] = None,
        error: Optional[str] = None,
    ) -> dict[str, Any]:
        key = normalize_path(video_path)
        data = self._load()
        entry = dict(data["clips"].get(key) or {})
        entry["path"] = key
        entry["status"] = status
        entry["updated_at"] = int(time.time())
        if title is not None:
            entry["title"] = title
        if privacy is not None:
            entry["privacy"] = privacy
        if youtube_video_id is not None:
            entry["youtube_video_id"] = youtube_video_id
        if youtube_url is not None:
            entry["youtube_url"] = youtube_url
        if error is not None:
            entry["error"] = error
        elif status != STATUS_FAILED:
            entry.pop("error", None)
        data["clips"][key] = entry
        self._save(data)
        return entry

    def list_by_status(self, status: str) -> list[dict[str, Any]]:
        clips = self._load()["clips"]
        return [v for v in clips.values() if v.get("status") == status]

    def should_skip_upload(self, video_path: str | Path) -> tuple[bool, str]:
        entry = self.get(video_path)
        if not entry:
            return False, ""
        status = entry.get("status")
        if status == STATUS_UPLOADED:
            vid = entry.get("youtube_video_id") or ""
            return True, f"already uploaded ({vid})"
        if status == STATUS_UPLOADING:
            # Allow retry if a previous uploader appears stuck (> 2 hours).
            updated = int(entry.get("updated_at") or 0)
            if time.time() - updated < 2 * 60 * 60:
                return True, "upload already in progress"
        return False, ""
