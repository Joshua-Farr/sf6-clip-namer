#!/usr/bin/env python3
"""CLI for YouTube OAuth + clip uploads (companion to the OBS Lua script)."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

# Allow running as `python youtube_uploader.py` from src/ or repo root.
_SRC = Path(__file__).resolve().parent
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from youtube_auth import AuthError, run_auth_flow  # noqa: E402
from youtube_paths import (  # noqa: E402
    default_client_secret_path,
    default_log_path,
    default_token_path,
)
from youtube_state import STATUS_FAILED, UploadStateStore  # noqa: E402
from youtube_upload import upload_video  # noqa: E402
from sheets_log import add_match_row, prepare_sheet  # noqa: E402


def _setup_logging(verbose: bool = False) -> None:
    log_path = default_log_path()
    level = logging.DEBUG if verbose else logging.INFO
    handlers: list[logging.Handler] = [
        logging.FileHandler(log_path, encoding="utf-8"),
    ]
    # pythonw.exe has no console; sys.stdout may be None.
    if sys.stdout is not None:
        handlers.append(logging.StreamHandler(sys.stdout))
    logging.basicConfig(
        level=level,
        format="[SF6YouTube] %(levelname)s %(message)s",
        handlers=handlers,
    )


def cmd_auth(args: argparse.Namespace) -> int:
    try:
        token = run_auth_flow(
            client_secret_path=Path(args.client_secret) if args.client_secret else None,
            token_path=Path(args.token) if args.token else None,
        )
    except AuthError as exc:
        logging.error("%s", exc)
        return 1
    except Exception as exc:  # noqa: BLE001
        logging.error("Auth failed: %s", exc)
        return 1
    logging.info("Authentication saved to %s", token)
    return 0


def cmd_sheets_auth(args: argparse.Namespace) -> int:
    """One-time Google Sheets consent (separate token from YouTube)."""
    try:
        info = prepare_sheet(
            args.sheet,
            client_secret_path=Path(args.client_secret) if args.client_secret else None,
            interactive=True,
        )
    except AuthError as exc:
        logging.error("%s", exc)
        return 1
    except Exception as exc:  # noqa: BLE001
        logging.error("Sheets auth/setup failed: %s", exc)
        return 1
    logging.info("Sheets ready: tab '%s', columns: %s", info["tab"], ", ".join(info["headers"]))
    return 0


def _read_match_file(path_str: str | None) -> dict | None:
    if not path_str:
        return None
    path = Path(path_str)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        logging.warning("Could not read match file %s: %s", path, exc)
        return None
    finally:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


def _log_to_sheet(args: argparse.Namespace, match: dict, result: dict) -> None:
    """Best effort: a sheet problem must never fail an upload."""
    fields = dict(match)
    fields["vod"] = result.get("youtube_url") or ""
    try:
        info = add_match_row(
            args.sheet,
            fields,
            client_secret_path=Path(args.client_secret) if args.client_secret else None,
        )
        logging.info("Logged match to training sheet (tab '%s')", info["tab"])
    except AuthError as exc:
        logging.warning("Training sheet not updated: %s", exc)
    except Exception as exc:  # noqa: BLE001
        logging.error("Training sheet not updated: %s", exc)


def cmd_upload(args: argparse.Namespace) -> int:
    path = Path(args.path)
    client_secret = Path(args.client_secret) if args.client_secret else None
    token = Path(args.token) if args.token else None
    description = args.description
    if args.description_file:
        description = Path(args.description_file).read_text(encoding="utf-8")
        try:
            Path(args.description_file).unlink(missing_ok=True)
        except OSError:
            pass
    match = _read_match_file(args.match_file)
    try:
        result = upload_video(
            path,
            title=args.title,
            description=description,
            privacy=args.privacy,
            client_secret_path=client_secret,
            token_path=token,
            interactive_auth=False,
        )
    except AuthError as exc:
        logging.error("%s", exc)
        return 2
    except FileNotFoundError as exc:
        logging.error("%s", exc)
        return 1
    except Exception as exc:  # noqa: BLE001
        logging.error("Upload failed (local file kept): %s", exc)
        return 1

    if result.get("skipped"):
        logging.info("Skipped: %s (%s)", path.name, result.get("skip_reason"))
        return 0

    logging.info(
        "Uploaded: %s -> %s",
        path.name,
        result.get("youtube_url") or result.get("youtube_video_id"),
    )
    if args.sheet and match is not None:
        _log_to_sheet(args, match, result)
    return 0


def cmd_retry_failed(args: argparse.Namespace) -> int:
    store = UploadStateStore()
    failed = store.list_by_status(STATUS_FAILED)
    if not failed:
        logging.info("No failed uploads to retry")
        return 0

    client_secret = Path(args.client_secret) if args.client_secret else None
    token = Path(args.token) if args.token else None
    errors = 0
    for entry in failed:
        path = Path(entry.get("path") or "")
        if not path.is_file():
            logging.warning("Skipping missing file: %s", path)
            errors += 1
            continue
        try:
            result = upload_video(
                path,
                title=entry.get("title") or args.title,
                privacy=entry.get("privacy") or args.privacy,
                client_secret_path=client_secret,
                token_path=token,
                state_store=store,
                interactive_auth=False,
            )
            if result.get("skipped"):
                logging.info("Skipped: %s", path.name)
            else:
                logging.info(
                    "Uploaded: %s -> %s",
                    path.name,
                    result.get("youtube_url") or result.get("youtube_video_id"),
                )
        except Exception as exc:  # noqa: BLE001
            logging.error("Retry failed for %s: %s", path.name, exc)
            errors += 1
    return 1 if errors else 0


def cmd_status(args: argparse.Namespace) -> int:
    store = UploadStateStore()
    if args.path:
        entry = store.get(args.path)
        if not entry:
            print("unknown")
            return 0
        print(entry.get("status", "unknown"))
        if entry.get("youtube_url"):
            print(entry["youtube_url"])
        if entry.get("error"):
            print(entry["error"])
        return 0

    data_clips = store._load()["clips"]  # noqa: SLF001
    if not data_clips:
        print("No tracked clips")
        return 0
    for key, entry in sorted(data_clips.items()):
        status = entry.get("status", "?")
        name = Path(key).name
        extra = entry.get("youtube_url") or entry.get("error") or ""
        print(f"{status:10} {name}  {extra}".rstrip())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Kovaak Clip Namer — YouTube upload companion",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging",
    )
    parser.add_argument(
        "--client-secret",
        default=str(default_client_secret_path()),
        help="Path to Google OAuth Desktop client JSON",
    )
    parser.add_argument(
        "--token",
        default=str(default_token_path()),
        help="Path to OAuth token JSON",
    )

    # Also accept these after the subcommand (older launcher order).
    shared = argparse.ArgumentParser(add_help=False)
    shared.add_argument(
        "--client-secret",
        default=str(default_client_secret_path()),
        help=argparse.SUPPRESS,
    )
    shared.add_argument(
        "--token",
        default=str(default_token_path()),
        help=argparse.SUPPRESS,
    )

    sub = parser.add_subparsers(dest="command", required=True)

    auth = sub.add_parser(
        "auth",
        parents=[shared],
        help="Run interactive OAuth and save token",
    )
    auth.set_defaults(func=cmd_auth)

    upload = sub.add_parser("upload", parents=[shared], help="Upload one processed clip")
    upload.add_argument("path", help="Absolute path to the video file")
    upload.add_argument("--title", default=None, help="YouTube title (default: filename stem)")
    upload.add_argument(
        "--description",
        default=None,
        help="YouTube description text",
    )
    upload.add_argument(
        "--description-file",
        default=None,
        help="Read YouTube description from this file (deleted after read)",
    )
    upload.add_argument(
        "--privacy",
        default="unlisted",
        choices=["unlisted", "private", "public"],
        help="YouTube privacy status",
    )
    upload.add_argument(
        "--match-file",
        default=None,
        help="JSON with match details for the training sheet (deleted after read)",
    )
    upload.add_argument(
        "--sheet",
        default=None,
        help="Google Sheet URL/ID to log the match to after upload",
    )
    upload.set_defaults(func=cmd_upload)

    sheets_auth = sub.add_parser(
        "sheets-auth",
        parents=[shared],
        help="One-time Google Sheets consent and header setup",
    )
    sheets_auth.add_argument("--sheet", required=True, help="Google Sheet URL or ID")
    sheets_auth.set_defaults(func=cmd_sheets_auth)

    retry = sub.add_parser(
        "retry-failed",
        parents=[shared],
        help="Retry clips marked failed",
    )
    retry.add_argument("--title", default=None, help="Override title (rarely needed)")
    retry.add_argument(
        "--privacy",
        default="unlisted",
        choices=["unlisted", "private", "public"],
    )
    retry.set_defaults(func=cmd_retry_failed)

    status = sub.add_parser("status", parents=[shared], help="Show upload state")
    status.add_argument("path", nargs="?", default=None, help="Optional clip path")
    status.set_defaults(func=cmd_status)

    return parser


def main(argv: list[str] | None = None) -> int:
    # File logging before argparse so flag/order mistakes are not silent under pythonw.
    pre_verbose = "-v" in (argv or sys.argv[1:]) or "--verbose" in (argv or sys.argv[1:])
    _setup_logging(verbose=pre_verbose)
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        code = int(exc.code or 0) if isinstance(exc.code, int) or exc.code is None else 1
        if code:
            logging.error("Invalid arguments: %s", " ".join(argv or sys.argv[1:]))
        raise
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
