#!/usr/bin/env python3
"""CLI: fetch latest CFN / Buckler match and write latest_match.json for the OBS script."""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path

_SRC = Path(__file__).resolve().parent
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from cfn_client import BucklerClient, BucklerError  # noqa: E402
from cfn_core import normalize_cookie  # noqa: E402
from cfn_paths import (  # noqa: E402
    default_cookie_path,
    default_log_path,
    default_match_cache_path,
)


def _setup_logging(verbose: bool = False) -> None:
    log_path = default_log_path()
    level = logging.DEBUG if verbose else logging.INFO
    handlers: list[logging.Handler] = [
        logging.FileHandler(log_path, encoding="utf-8"),
    ]
    if sys.stdout is not None:
        handlers.append(logging.StreamHandler(sys.stdout))
    logging.basicConfig(
        level=level,
        format="[SF6CFN] %(levelname)s %(message)s",
        handlers=handlers,
    )


def _read_cookie(path: Path | None) -> str:
    cookie_path = path or default_cookie_path()
    if not cookie_path.is_file():
        raise BucklerError(
            f"Cookie file not found: {cookie_path}. "
            "Log into Buckler's Boot Camp, copy the buckler_id cookie, "
            "and save it as buckler_id=<value> in that file."
        )
    raw = cookie_path.read_text(encoding="utf-8").strip()
    cookie = normalize_cookie(raw)
    if not cookie:
        raise BucklerError(f"Cookie file is empty: {cookie_path}")
    return cookie


def _parse_modes(raw: str) -> list[str]:
    modes = [m.strip().lower() for m in (raw or "").split(",") if m.strip()]
    return modes or ["rank", "casual"]


def cmd_fetch(args: argparse.Namespace) -> int:
    try:
        short_id = int(args.short_id)
    except (TypeError, ValueError):
        logging.error("cfn_short_id must be a number (from your Buckler profile URL)")
        return 2

    out_path = Path(args.out) if args.out else default_match_cache_path()
    modes = _parse_modes(args.modes)

    try:
        cookie = _read_cookie(Path(args.cookie) if args.cookie else None)
        client = BucklerClient(cookie)
        match = client.latest_match(short_id, modes=modes)
    except BucklerError as exc:
        logging.error("%s", exc)
        return 1
    except Exception as exc:  # noqa: BLE001
        logging.error("CFN fetch failed: %s", exc)
        return 1

    if not match:
        logging.error("No matches found in battlelog modes: %s", ",".join(modes))
        return 1

    out_path.parent.mkdir(parents=True, exist_ok=True)
    payload = dict(match)
    payload["fetched_at"] = int(time.time())
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    logging.info(
        "Latest match: %s vs %s %s (%s) replay=%s -> %s",
        payload.get("my_character"),
        payload.get("opp_character"),
        payload.get("result"),
        payload.get("mode_label") or payload.get("mode"),
        payload.get("replay_id"),
        out_path,
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fetch latest SF6 CFN match for OBS renaming")
    parser.add_argument("--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    fetch = sub.add_parser("fetch", help="Fetch newest match and write JSON cache")
    fetch.add_argument("--short-id", required=True, help="Numeric CFN / Buckler short_id")
    fetch.add_argument(
        "--cookie",
        default="",
        help="Path to buckler cookie file (default: %%AppData%%/sf6-clip-namer/buckler_cookie.txt)",
    )
    fetch.add_argument(
        "--out",
        default="",
        help="Output JSON path (default: %%AppData%%/sf6-clip-namer/latest_match.json)",
    )
    fetch.add_argument(
        "--modes",
        default="rank,casual",
        help="Comma-separated battlelog modes (rank,casual,hub,custom,extreme)",
    )
    fetch.set_defaults(func=cmd_fetch)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    _setup_logging(verbose=bool(args.verbose))
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
