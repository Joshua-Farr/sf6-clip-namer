# REFramework match start/end bridge

This gives true “round 1 → match end” capture.

## What it does

| Event | Action |
|-------|--------|
| Match start (`gBattle` fight running) | OBS restarts Replay Buffer |
| Match end (`fight_st == 7` or leave battle) | OBS saves Replay Buffer → rename via CFN → YouTube |

Status file:

```text
%AppData%\sf6-clip-namer\battle_status.json
```

## Install (once)

1. Close Street Fighter 6.
2. Download [REFramework SF6.zip](https://github.com/praydog/REFramework/releases) (`SF6.zip`).
3. Extract **into** the SF6 install folder so you have:

```text
...\Street Fighter 6\dinput8.dll
...\Street Fighter 6\reframework\autorun\
```

Typical path:

```text
C:\Program Files (x86)\Steam\steamapps\common\Street Fighter 6\
```

4. Copy this repo’s bridge script:

```text
reframework\autorun\sf6_obs_battle_bridge.lua
```

→

```text
...\Street Fighter 6\reframework\autorun\sf6_obs_battle_bridge.lua
```

5. Launch SF6. You should see the REFramework UI (Insert key by default). Confirm the script loaded in the REFramework console.
6. In OBS → Scripts → SF6 Replay Namer: keep **Auto-capture** and **Use REFramework match start/end bridge** checked.
7. Set Replay Buffer length to **5–10+ minutes**, then Stop/Start the buffer once so the new length applies.

## Verify

1. OBS Script Log: `REFramework battle bridge connected` (after first status write) or match start/end lines.
2. Play a match: buffer should flicker restart at round 1; after the match, a clip should save and rename.

## Notes

- Anti-cheat / online: REFramework is widely used for SF6 training tools; use at your own risk and keep it updated.
- If the bridge file is missing, the OBS script falls back to CFN-only auto-save (no true match-start reset).
- CFN can lag after match end; the OBS script retries naming for about a minute.
