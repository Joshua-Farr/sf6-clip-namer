# SF6 Clip Namer

OBS Studio script that renames Replay Buffer clips using your most recent
**Street Fighter 6** match from CFN / Buckler's Boot Camp.

**Example**

```text
SF6Clips\Ken\Ken_vs_Ryu_W_Ranked_2026-11-25_16-14-02.mp4
```

Renaming only happens while Street Fighter 6 (`StreetFighter6.exe`) is running.
If SF6 is closed, or a CFN match cannot be matched confidently, OBS keeps its
normal filename.

With **Auto-capture** + **REFramework**, the script restarts the Replay Buffer at
**match start** and saves at **match end**, then renames from CFN and uploads to
YouTube—no hotkey needed.

Features:

- **Match-start capture** — REFramework detects battle start/end in-game
- **Auto-capture** — restarts Replay Buffer at round 1; saves when the match ends
- **Character folders** — store clips under `{root}/{character played}/`
- **YouTube uploads** — after a successful local rename/move, upload as **Unlisted**
- **CFN match metadata** — character, opponent, W/L, mode, replay id

---

## Requirements

| Requirement | Notes |
|-------------|--------|
| Windows 10/11 | Tested layout matches the Kovaak clip namer |
| [OBS Studio](https://obsproject.com/) | Current stable build |
| [Street Fighter 6](https://store.steampowered.com/app/1364780/) | Steam |
| Python 3.10+ | Needed for CFN fetch + optional YouTube |
| Capcom ID / Buckler login | For the `buckler_id` session cookie |

**Strongly recommended:** turn off OBS **Auto Remux** for replay clips so this
script renames the final file (not a temporary one).

---

## Install (step by step)

### 1. Get your CFN short_id and Buckler cookie

1. Open [Buckler's Boot Camp](https://www.streetfighter.com/6/buckler) and sign in
2. Open your profile — the URL contains your numeric id, e.g.
   `.../profile/1234567890` → short_id `1234567890`
3. DevTools → Application → Cookies → `www.streetfighter.com`
4. Copy the **`buckler_id`** value
5. Create this file:

```text
%AppData%\sf6-clip-namer\buckler_cookie.txt
```

Contents:

```text
buckler_id=PASTE_VALUE_HERE
```

Cookies expire; refresh this file if fetches start failing.

### 2. Download this project

```bash
git clone https://github.com/Joshua-Farr/sf6-clip-namer.git
```

(Or download the ZIP from GitHub and extract it.)

### 3. Copy the script files into OBS

Install the **entire** `src/` folder. All `.lua` and companion `.py` files must
stay together.

1. Create:

```text
%AppData%\obs-studio\scripts\sf6-clip-namer\
```

2. Copy **every file** from this repo's `src/` folder into that directory.

3. In OBS: **Tools → Scripts → +** → select `sf6_replay_namer.lua`

### 4. Configure the script

In the script settings panel:

| Setting | Value |
|---------|--------|
| CFN short_id | Your numeric profile id |
| Buckler cookie file | Path to `buckler_cookie.txt` (default AppData path is fine) |
| Organize into character folders | On |
| Clips root folder | Optional review folder (e.g. `D:\SF6Clips`) |
| YouTube upload | Optional — see below |

### 5. (Optional) YouTube upload

```bash
pip install -r requirements-youtube.txt
```

1. Create a Google Cloud OAuth **Desktop** client and download `client_secret.json`
2. Point the script setting **YouTube OAuth client secret JSON** at that file
3. Run once interactively to authorize:

```bash
python src/youtube_uploader.py auth --client-secret path\to\client_secret.json
```

Tokens and upload state live under `%AppData%\sf6-clip-namer\`.

---

## Usage

1. Install **REFramework** + the battle bridge (see [REFramework setup](docs/REFRAMEWORK_SETUP.md))
2. OBS → **Settings → Output → Replay Buffer**: set length to **5–10+ minutes**, then restart the buffer
3. Load the script with **Auto-capture** and **Use REFramework match start/end bridge** checked
4. Leave OBS open, launch SF6, play — clips save/rename/upload after each match

Manual **Save Replay Buffer** still works. Log lines use `[SF6Replay]`.

---

## Filename format

Default:

```text
{my_char}_vs_{opp_char}_{result}_{mode}_{timestamp}
```

Tokens: `{my_char}` `{opp_char}` `{result}` `{mode}` `{opp_name}` `{timestamp}`

---

## Development

```bash
pip install -r requirements-dev.txt
pytest -q
```

CFN fetch (manual smoke test once cookie + short_id are set):

```bash
python src/cfn_fetch.py fetch --short-id YOUR_ID
```

Docs:

- [REFramework setup](docs/REFRAMEWORK_SETUP.md) ← match start/end
- [Architecture](docs/ARCHITECTURE.md)
- [CFN data source](docs/CFN_DATA_SOURCE.md)
- [OBS integration](docs/OBS_INTEGRATION.md)

---

## Related

Sister project: [kovaak-clip-namer](https://github.com/Joshua-Farr/kovaak-clip-namer)
