"""Pure CFN / Buckler match parsing helpers (testable without network)."""

from __future__ import annotations

from typing import Any

MODE_LABELS = {
    "rank": "Ranked",
    "casual": "Casual",
    "hub": "Battle Hub",
    "custom": "Custom Room",
    "extreme": "Extreme",
}


def normalize_cookie(raw: str) -> str:
    """Accept `buckler_id=VALUE`, bare VALUE, or a full Cookie header."""
    text = (raw or "").strip()
    if not text:
        return ""
    # Full header already contains buckler_id=
    if "buckler_id=" in text:
        return text
    if "=" not in text:
        return f"buckler_id={text}"
    return text


def player_won(round_results: list[Any] | None) -> bool:
    """Buckler: 0 = lost round for this player; non-zero = won that round."""
    if not round_results:
        return False
    wins = sum(1 for r in round_results if r)
    return wins >= 2


def character_name(info: dict[str, Any] | None) -> str:
    if not info:
        return "Unknown"
    return (
        info.get("playing_character_name")
        or info.get("character_name")
        or info.get("playing_character_tool_name")
        or info.get("character_tool_name")
        or "Unknown"
    )


def fighter_name(info: dict[str, Any] | None) -> str:
    if not info:
        return "Unknown"
    player = info.get("player") or {}
    return str(player.get("fighter_id") or "Unknown")


def short_id_of(info: dict[str, Any] | None) -> int | None:
    if not info:
        return None
    player = info.get("player") or {}
    sid = player.get("short_id")
    try:
        return int(sid)
    except (TypeError, ValueError):
        return None


def mode_label(mode: str, battle_type_name: str | None = None) -> str:
    if battle_type_name:
        return str(battle_type_name)
    return MODE_LABELS.get(mode, mode.title() if mode else "Match")


def normalize_battle(
    battle: dict[str, Any],
    *,
    my_short_id: int,
    mode: str,
) -> dict[str, Any] | None:
    """Project a Buckler battle onto the authenticated player's perspective."""
    if not battle:
        return None

    p1 = battle.get("player1_info") or {}
    p2 = battle.get("player2_info") or {}
    sid1 = short_id_of(p1)
    sid2 = short_id_of(p2)

    if sid1 == my_short_id:
        me, opp = p1, p2
    elif sid2 == my_short_id:
        me, opp = p2, p1
    else:
        return None

    result = "W" if player_won(me.get("round_results")) else "L"
    uploaded_at = battle.get("uploaded_at")
    try:
        completed_at = int(uploaded_at)
    except (TypeError, ValueError):
        return None

    replay_id = str(battle.get("replay_id") or "")
    if not replay_id:
        return None

    return {
        "match_id": replay_id,
        "replay_id": replay_id,
        "completed_at": completed_at,
        "my_character": character_name(me),
        "opp_character": character_name(opp),
        "opp_name": fighter_name(opp),
        "result": result,
        "mode": mode,
        "mode_label": mode_label(mode, battle.get("replay_battle_type_name")),
        "my_mr": me.get("master_rating"),
        "opp_mr": opp.get("master_rating"),
        "my_lp": me.get("league_point"),
        "opp_lp": opp.get("league_point"),
        "fetched_at": None,
    }


def newest_match(
    battles_by_mode: dict[str, list[dict[str, Any]]],
    *,
    my_short_id: int,
) -> dict[str, Any] | None:
    """Pick the newest normalized match across mode pages."""
    best: dict[str, Any] | None = None
    for mode, battles in battles_by_mode.items():
        for battle in battles or []:
            match = normalize_battle(battle, my_short_id=my_short_id, mode=mode)
            if not match:
                continue
            if best is None or match["completed_at"] > best["completed_at"]:
                best = match
    return best
