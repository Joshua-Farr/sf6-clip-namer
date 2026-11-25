# CFN / Buckler data source

Street Fighter 6 does **not** export a local completed-match CSV the way
Kovaak's does. Match history for online play lives on Capcom's
[Buckler's Boot Camp](https://www.streetfighter.com/6/buckler) site (CFN web).

## What we read

For your numeric profile id (`short_id`), page 1 of:

- `profile/{short_id}/battlelog/rank`
- `profile/{short_id}/battlelog/casual`

(optional: hub / custom / extreme via the modes setting)

Buckler is a Next.js app. The companion fetches:

```text
/6/buckler/_next/data/{buildId}/en/profile/{short_id}/battlelog/{mode}.json?page=1
```

Each replay entry includes (among other fields):

| Field | Use |
|-------|-----|
| `replay_id` | Unique match id |
| `uploaded_at` | Unix timestamp (staleness + ordering) |
| `player*_info.playing_character_name` | Characters used |
| `player*_info.player.fighter_id` | CFN display names |
| `player*_info.player.short_id` | Whose side is "me" |
| `player*_info.round_results` | Win/loss (0 = lost round) |
| `replay_battle_type_name` | Mode label |

## Authentication

Buckler requires a logged-in Capcom ID session. This tool uses the
`buckler_id` cookie from your browser after you log in manually.

1. Open https://www.streetfighter.com/6/buckler and sign in
2. DevTools → Application → Cookies → `www.streetfighter.com`
3. Copy the `buckler_id` value
4. Save to `%AppData%\sf6-clip-namer\buckler_cookie.txt` as:

```text
buckler_id=PASTE_VALUE_HERE
```

Cookies expire. If fetches start failing with "session likely expired", refresh
the cookie the same way.

**Finding your short_id:** open your Buckler profile. The URL looks like
`.../profile/1234567890` — that number is your `cfn_short_id`.

## Rate limiting

The fetcher only runs when you save an OBS Replay Buffer clip, and spaces
mode requests by ~0.6s. Do not point background jobs at Buckler with this
client.

## Out of scope

- Capcom private game API / Steam ticket auth
- Replay file download / REFramework injection
- Headless Capcom ID login automation
