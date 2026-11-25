from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
sys.path.insert(0, str(SRC))

from cfn_core import (  # noqa: E402
    format_rank,
    newest_match,
    normalize_battle,
    normalize_cookie,
    player_won,
    score_string,
)


FIXTURE = ROOT / "tests" / "fixtures" / "sample_battle.json"


def test_normalize_cookie_variants():
    assert normalize_cookie("abc") == "buckler_id=abc"
    assert normalize_cookie("buckler_id=abc") == "buckler_id=abc"
    assert normalize_cookie("a=1; buckler_id=abc") == "a=1; buckler_id=abc"


def test_player_won():
    assert player_won([1, 1]) is True
    assert player_won([0, 0]) is False
    assert player_won([1, 0, 1]) is True
    assert player_won([]) is False


def test_score_and_rank_helpers():
    assert score_string([1, 1], [0, 0]) == "2-0"
    assert score_string([0, 0], [1, 1]) == "0-2"
    assert format_rank(master_rating=1550, league_rank=8) == "MR1550"
    # Below Master: omit rank from title/filename.
    assert format_rank(master_rating=0, league_rank=7, league_point=1200) == ""
    assert format_rank(master_rating=0, league_rank=8) == "Master"


def test_normalize_battle_from_fixture():
    battle = json.loads(FIXTURE.read_text(encoding="utf-8"))
    match = normalize_battle(battle, my_short_id=88475682, mode="rank")
    assert match is not None
    assert match["my_character"] == "Ken"
    assert match["opp_character"] == "Ryu"
    assert match["opp_name"] == "OpponentCFN"
    assert match["result"] == "W"
    assert match["score"] == "2-0"
    assert match["mode"] == "rank"
    assert match["mode_label"] == "Ranked"
    assert match["opp_rank"] == "MR1550"
    assert match["match_id"] == "ABC123XYZ"
    assert match["completed_at"] == 1732572842


def test_normalize_battle_as_player2_loss():
    battle = json.loads(FIXTURE.read_text(encoding="utf-8"))
    match = normalize_battle(battle, my_short_id=999001, mode="casual")
    assert match is not None
    assert match["my_character"] == "Ryu"
    assert match["opp_character"] == "Ken"
    assert match["result"] == "L"


def test_newest_match_picks_later_timestamp():
    older = json.loads(FIXTURE.read_text(encoding="utf-8"))
    newer = json.loads(FIXTURE.read_text(encoding="utf-8"))
    newer["replay_id"] = "NEWER"
    newer["uploaded_at"] = older["uploaded_at"] + 100
    best = newest_match(
        {"rank": [older], "casual": [newer]},
        my_short_id=88475682,
    )
    assert best is not None
    assert best["match_id"] == "NEWER"
