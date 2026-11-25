-- config.lua
-- Default settings for the SF6 replay namer.

local M = {}

M.DEFAULTS = {
  enabled = true,
  -- When on: while SF6 is running, keep Replay Buffer active and auto-save.
  auto_capture = true,
  -- Prefer REFramework battle bridge (match_start → restart buffer,
  -- match_end → save). Falls back to CFN-only if the bridge file is absent.
  use_battle_bridge = true,
  battle_status_path = "", -- empty = <SF6>\reframework\data\sf6_obs_battle_status.json
  -- How often to check CFN (naming + backup save) while SF6 is running.
  auto_poll_seconds = 40,
  -- How often to check whether StreetFighter6.exe is running.
  process_check_seconds = 5,
  -- After a match_end save, retry CFN naming this many times (CFN lags).
  cfn_rename_retries = 12,
  cfn_rename_retry_ms = 5000,
  -- Example: "0-2 Cammy vs Ryu Ranked SF6 MR1550"
  filename_format = "{score} {my_char} vs {opp_char} {mode} SF6 {opp_rank}",
  -- Date then time. Wall clock is America/Chicago (Central); see format_timestamp.
  timestamp_format = "yyyy-MM-dd_HH-mm-ss",
  -- Allow CFN lag + poll interval after the match ends.
  max_age_minutes = 20,
  allow_multiple_clips = true,
  debug_logging = false,
  -- Your numeric CFN / Buckler short_id (from profile URL).
  cfn_short_id = "",
  -- File containing buckler_id=<cookie> (or a full Cookie header string).
  buckler_cookie_path = "",
  -- Comma-separated Buckler battlelog modes to check (newest across them wins).
  cfn_modes = "rank,casual",
  rename_delay_ms = 300,
  rename_attempts = 5,
  cfn_fetch_timeout_ms = 12000,
  -- Organize clips into {root}/{character played}/...
  organize_by_character = true,
  -- Empty = use the directory of the OBS-saved replay.
  clips_root_dir = "",
  -- YouTube companion (opt-in; requires Python helper + OAuth).
  youtube_upload_enabled = true,
  youtube_privacy = "unlisted",
  youtube_client_secret_path = "",
  youtube_python_path = "",
}

function M.copy_defaults()
  local t = {}
  for k, v in pairs(M.DEFAULTS) do
    t[k] = v
  end
  return t
end

return M
