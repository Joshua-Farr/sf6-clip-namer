"""Append SF6 match rows to a Google Sheet (training notes log).

The sheet's own header row decides where each value goes, so you can reorder
or add columns (e.g. notes) freely. Unknown columns are left blank for you to
fill in. If the sheet is empty, a default header row is written first.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Optional

from youtube_auth import AuthError
from youtube_paths import (
    SHEETS_SCOPES,
    default_client_secret_path,
    default_sheets_token_path,
)

DEFAULT_HEADERS = [
    "Date",
    "Time (CT)",
    "Mode",
    "My Character",
    "Opp Character",
    "Opponent",
    "Result",
    "Score",
    "My MR",
    "Opp MR",
    "VOD",
    "Why I won/lost",
    "What to do better",
    "Tags",
]

# Normalized header text -> field name in the match dict.
HEADER_ALIASES = {
    "date": "date",
    "time": "time",
    "timect": "time",
    "mode": "mode",
    "mycharacter": "my_character",
    "mychar": "my_character",
    "character": "my_character",
    "oppcharacter": "opp_character",
    "opponentcharacter": "opp_character",
    "oppchar": "opp_character",
    "matchup": "matchup",
    "opponent": "opp_name",
    "oppname": "opp_name",
    "opponentname": "opp_name",
    "result": "result",
    "wl": "result",
    "score": "score",
    "mymr": "my_mr",
    "oppmr": "opp_mr",
    "opponentmr": "opp_mr",
    "myrank": "my_rank",
    "opprank": "opp_rank",
    "opponentrank": "opp_rank",
    "vod": "vod",
    "vodlink": "vod",
    "link": "vod",
    "video": "vod",
    "youtube": "vod",
    "replayid": "replay_id",
}

MR_FIELDS = {"my_mr", "opp_mr"}


def header_key(header: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(header).lower())


def parse_sheet_ref(text: str) -> tuple[str, Optional[int]]:
    """Accept a full Google Sheets URL or a bare spreadsheet ID."""
    text = (text or "").strip()
    if not text:
        raise ValueError("no spreadsheet URL or ID given")
    m = re.search(r"/spreadsheets/d/([A-Za-z0-9_-]+)", text)
    sheet_id = m.group(1) if m else text
    g = re.search(r"[#?&]gid=(\d+)", text)
    return sheet_id, int(g.group(1)) if g else None


def _clean(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def field_value(field: str, match: dict[str, Any]) -> str:
    if field == "matchup":
        my = _clean(match.get("my_character"))
        opp = _clean(match.get("opp_character"))
        return f"{my} vs {opp}" if my and opp else ""
    value = _clean(match.get(field))
    if field in MR_FIELDS and value in {"0", "0.0"}:
        return ""  # MR only applies to Master players
    return value


def build_row(headers: list[str], match: dict[str, Any]) -> list[str]:
    """Map a match dict onto the sheet's header order; unknown columns blank."""
    row: list[str] = []
    for header in headers:
        field = HEADER_ALIASES.get(header_key(header))
        row.append(field_value(field, match) if field else "")
    return row


def _quote_tab(title: str) -> str:
    return "'" + title.replace("'", "''") + "'"


def get_sheets_credentials(
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
    interactive: bool = False,
):
    """Load/refresh Sheets credentials; optionally run browser consent."""
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow

    from youtube_auth import _load_client_secrets, _save_token

    client_secret_path = Path(client_secret_path or default_client_secret_path())
    token_path = Path(token_path or default_sheets_token_path())

    creds = None
    if token_path.is_file():
        creds = Credentials.from_authorized_user_file(str(token_path), SHEETS_SCOPES)
    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
            _save_token(creds, token_path)
            return creds
        except Exception as exc:  # noqa: BLE001
            if not interactive:
                raise AuthError(
                    "Google Sheets authentication expired. "
                    f"Re-run: python youtube_uploader.py sheets-auth. Detail: {exc}"
                ) from exc

    if not interactive:
        raise AuthError(
            "Google Sheets authentication required. "
            "Run: python youtube_uploader.py sheets-auth"
        )

    _load_client_secrets(client_secret_path)
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret_path), SHEETS_SCOPES)
    creds = flow.run_local_server(port=0)
    _save_token(creds, token_path)
    return creds


def _service(creds):
    from googleapiclient.discovery import build

    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def _tab_title(service, spreadsheet_id: str, gid: Optional[int]) -> str:
    meta = (
        service.spreadsheets()
        .get(spreadsheetId=spreadsheet_id, fields="sheets.properties(sheetId,title)")
        .execute()
    )
    sheets = [s["properties"] for s in meta.get("sheets", [])]
    if not sheets:
        raise RuntimeError("spreadsheet has no tabs")
    if gid is not None:
        for props in sheets:
            if props.get("sheetId") == gid:
                return props["title"]
    return sheets[0]["title"]


def _ensure_headers(service, spreadsheet_id: str, title: str) -> list[str]:
    tab = _quote_tab(title)
    values = (
        service.spreadsheets()
        .values()
        .get(spreadsheetId=spreadsheet_id, range=f"{tab}!1:1")
        .execute()
        .get("values", [])
    )
    headers = values[0] if values else []
    if any(_clean(h) for h in headers):
        return [str(h) for h in headers]

    service.spreadsheets().values().update(
        spreadsheetId=spreadsheet_id,
        range=f"{tab}!A1",
        valueInputOption="RAW",
        body={"values": [DEFAULT_HEADERS]},
    ).execute()
    return list(DEFAULT_HEADERS)


def prepare_sheet(
    sheet_ref: str,
    *,
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
    interactive: bool = False,
) -> dict[str, Any]:
    """Authenticate and make sure the target tab has a header row."""
    spreadsheet_id, gid = parse_sheet_ref(sheet_ref)
    creds = get_sheets_credentials(client_secret_path, token_path, interactive)
    service = _service(creds)
    title = _tab_title(service, spreadsheet_id, gid)
    headers = _ensure_headers(service, spreadsheet_id, title)
    return {"tab": title, "headers": headers}


def add_match_row(
    sheet_ref: str,
    match: dict[str, Any],
    *,
    client_secret_path: Optional[Path] = None,
    token_path: Optional[Path] = None,
    interactive: bool = False,
) -> dict[str, Any]:
    """Append one match as a new row at the bottom of the tab."""
    spreadsheet_id, gid = parse_sheet_ref(sheet_ref)
    creds = get_sheets_credentials(client_secret_path, token_path, interactive)
    service = _service(creds)
    title = _tab_title(service, spreadsheet_id, gid)
    headers = _ensure_headers(service, spreadsheet_id, title)
    row = build_row(headers, match)

    service.spreadsheets().values().append(
        spreadsheetId=spreadsheet_id,
        range=f"{_quote_tab(title)}!A1",
        valueInputOption="USER_ENTERED",
        insertDataOption="INSERT_ROWS",
        body={"values": [row]},
    ).execute()
    return {"tab": title, "row": row}
