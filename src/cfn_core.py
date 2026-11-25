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

# Buckler league_rank ids (community-observed).
LEAGUE_RANK_NAMES = {
    1: "Rookie",
    2: "Iron",
    3: "Bronze",
    4: "Silver",
    5: "Gold",
    6: "Platinum",
    7: "Diamond",
    8: "Master",
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


def round_wins(round_results: list[Any] | None) -> int:
    """Buckler: 0 = lost round for this player; non-zero = won that round."""
    if not round_results:
        return 0
    return sum(1 for r in round_results if r)


def player_won(round_results: list[Any] | None) -> bool:
    return round_wins(round_results) >= 2


def score_string(my_results: list[Any] | None, opp_results: list[Any] | None) -> str:
    """Return 'my-opp' round score from each side's perspective, e.g. '0-2'."""
    mine = round_wins(my_results)
    theirs = round_wins(opp_results)
    # If opponent results missing, infer from my losses.
    if not opp_results and my_results:
        theirs = sum(1 for r in my_results if not r)
    return f"{mine}-{theirs}"


def format_rank(
    *,
    master_rating: Any = None,
    league_point: Any = None,
    league_rank: Any = None,
) -> str:
    """Human rank label for filenames/titles: MR1600, Diamond, LP1200, etc."""
    try:
        mr = int(master_rating) if master_rating is not None else 0
    except (TypeError, ValueError):
        mr = 0
    if mr > 0:
        return f"MR{mr}"

    try:
        rank_id = int(league_rank) if league_rank is not None else 0
    except (TypeError, ValueError):
        rank_id = 0
    if rank_id in LEAGUE_RANK_NAMES:
        name = LEAGUE_RANK_NAMES[rank_id]
        if name == "Master" and mr <= 0:
            return "Master"
        if name != "Master":
            try:
                lp = int(league_point) if league_point is not None else 0
            except (TypeError, ValueError):
                lp = 0
            if lp > 0:
                return f"{name}{lp}"
            return name

    try:
        lp = int(league_point) if league_point is not None else 0
    except (TypeError, ValueError):
        lp = 0
    if lp > 0:
        return f"LP{lp}"
    return ""


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
    """Short label for titles/filenames (Ranked, Casual, …)."""
    short = MODE_LABELS.get(mode)
    if short:
        return short
    if battle_type_name:
        # "Ranked Match" → "Ranked"
        name = str(battle_type_name).replace(" Match", "").strip()
        return name or "Match"
    return mode.title() if mode else "Match"


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

    my_rounds = me.get("round_results")
    opp_rounds = opp.get("round_results")
    result = "W" if player_won(my_rounds) else "L"
    score = score_string(my_rounds, opp_rounds)
    uploaded_at = battle.get("uploaded_at")
    try:
        completed_at = int(uploaded_at)
    except (TypeError, ValueError):
        return None

    replay_id = str(battle.get("replay_id") or "")
    if not replay_id:
        return None

    opp_rank = format_rank(
        master_rating=opp.get("master_rating"),
        league_point=opp.get("league_point"),
        league_rank=opp.get("league_rank"),
    )
    my_rank = format_rank(
        master_rating=me.get("master_rating"),
        league_point=me.get("league_point"),
        league_rank=me.get("league_rank"),
    )

    return {
        "match_id": replay_id,
        "replay_id": replay_id,
        "completed_at": completed_at,
        "my_character": character_name(me),
        "opp_character": character_name(opp),
        "opp_name": fighter_name(opp),
        "result": result,
        "score": score,
        "mode": mode,
        "mode_label": mode_label(mode, battle.get("replay_battle_type_name")),
        "my_mr": me.get("master_rating"),
        "opp_mr": opp.get("master_rating"),
        "my_lp": me.get("league_point"),
        "opp_lp": opp.get("league_point"),
        "my_league_rank": me.get("league_rank"),
        "opp_league_rank": opp.get("league_rank"),
        "my_rank": my_rank,
        "opp_rank": opp_rank,
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
