# OBS integration

## Why post-save rename?

OBS does not expose a reliable API to set the Replay Buffer filename **before**
the file is written. The supported path:

1. User saves replay (hotkey)
2. `OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED`
3. `obs_frontend_get_last_replay()` → path
4. Short delay / lock check
5. `os.rename` to the new name (never overwrite; use `_2`, `_3`, …)

## Script packaging

Install the entire `src/` folder into OBS scripts (recommended):

```text
%AppData%\obs-studio\scripts\sf6-clip-namer\
```

Load **`sf6_replay_namer.lua`** in **Tools → Scripts**. Sibling `.lua` / `.py`
files must stay in the same directory.

## Recommendations

- Disable OBS **Auto Remux** for replay clips so this script renames the final file
- Keep Replay Buffer enabled while playing SF6
- Save the buffer shortly after a match ends so CFN history is fresh

## Auto-capture

When **Auto-capture** is enabled:

- A 1s timer checks whether `StreetFighter6.exe` is running
- On SF6 start: `obs_frontend_replay_buffer_start()` + CFN baseline (no save)
- While SF6 runs: poll CFN every N seconds; on new `replay_id`, call
  `obs_frontend_replay_buffer_save()`
- Rename/YouTube still run from `REPLAY_BUFFER_SAVED`

Set Replay Buffer duration long enough for a full match (5–10+ minutes).
