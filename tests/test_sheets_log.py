"""Tests for pure helpers in sheets_log (no network)."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sheets_log import (  # noqa: E402
    DEFAULT_HEADERS,
    build_row,
    header_key,
    parse_sheet_ref,
)

MATCH = {
    "date": "2026-11-25",
    "time": "17:57:50",
    "mode": "Ranked",
    "my_character": "Cammy",
    "opp_character": "Kimberly",
    "opp_name": "Fireninja94",
    "result": "L",
    "score": "0-2",
    "my_mr": 0,
    "opp_mr": 1550,
    "vod": "https://youtu.be/abc123",
}


def test_parse_sheet_ref_url_with_gid():
    url = "https://docs.google.com/spreadsheets/d/16cxbrxJa90_evsyYfy27y-GXo/edit?gid=42#gid=42"
    assert parse_sheet_ref(url) == ("16cxbrxJa90_evsyYfy27y-GXo", 42)


def test_parse_sheet_ref_bare_id_and_empty():
    assert parse_sheet_ref("  abcDEF123  ") == ("abcDEF123", None)
    with pytest.raises(ValueError):
        parse_sheet_ref("   ")


def test_header_key_normalizes():
    assert header_key("Time (CT)") == "timect"
    assert header_key("W/L") == "wl"


def test_default_headers_fill_and_leave_notes_blank():
    row = build_row(DEFAULT_HEADERS, MATCH)
    by_header = dict(zip(DEFAULT_HEADERS, row))
    assert by_header["Date"] == "2026-11-25"
    assert by_header["My Character"] == "Cammy"
    assert by_header["Opponent"] == "Fireninja94"
    assert by_header["Score"] == "0-2"
    assert by_header["VOD"] == "https://youtu.be/abc123"
    assert by_header["My MR"] == ""  # MR 0 is not shown
    assert by_header["Opp MR"] == "1550"
    for notes in ("Why I won/lost", "What to do better", "Tags"):
        assert by_header[notes] == ""


def test_custom_header_order_and_matchup():
    headers = ["Notes", "Matchup", "W/L", "Link"]
    row = build_row(headers, MATCH)
    assert row == ["", "Cammy vs Kimberly", "L", "https://youtu.be/abc123"]
