# Architecture

## Goal

Automatically rename OBS Studio Replay Buffer clips using the most recent
**Street Fighter 6** match from CFN / Buckler's Boot Camp, only while SF6 is
running. Organize clips into per-character folders and optionally upload to
YouTube.

Example:

```text
SF6Clips\Ken\Ken_vs_Ryu_W_Ranked_2026-11-25_16-14-02.mp4
```

## Design summary

| Concern | Decision |
|---------|----------|
| Match data | Buckler's Boot Camp battlelog (Next.js pageProps) |
| Auth | User-provided `buckler_id` session cookie file |
| OBS naming | Post-save rename (OBS cannot set replay filename before write) |
| Delivery | OBS Lua script (Tools → Scripts) |
| Folder org | Optional per-character subfolders under clips root |
| YouTube | Opt-in companion Python process + YouTube Data API OAuth |
| Fail-safe | On any uncertainty, keep the original OBS filename |

## Data flow

```text
SF6 launches
        │
        ▼
AutoCapture starts Replay Buffer + baselines latest CFN match id
        │
User finishes a match → CFN battlelog gains a new entry
        │
        ▼
AutoCapture poll (every ~40s) sees new match_id
        │
        ▼
obs_frontend_replay_buffer_save()
        │
        ▼
OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED
        │
        ▼
cfn_launcher → latest_match.json → rename/move → optional YouTube
```

Manual Save Replay follows the same rename/upload path.

## Components

### Sf6Detector

Checks for `StreetFighter6.exe` via Win32 Toolhelp (no console flash).

### CfnLauncher + cfn_fetch.py

On replay save only, runs the Python Buckler client and writes
`%AppData%\sf6-clip-namer\latest_match.json`.

### ResultProvider

Reads/normalizes that JSON into a `CompletedMatch` table.

### MatchTracker

Enforces max age and optional one-clip-per-match association.

### FilenameFormatter / FileRenamer / YouTube

Same roles as the Kovaak clip namer, adapted for match fields and character folders.

## Fail-safe

Any uncertainty (SF6 not running, cookie missing/expired, stale match, locked
file, invalid name) → **leave OBS filename unchanged**. Never delete or overwrite.
