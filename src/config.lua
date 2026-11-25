-- config.lua
-- Default settings for the SF6 replay namer.

local M = {}

M.DEFAULTS = {
  enabled = true,
  -- When on: while SF6 is running, keep Replay Buffer active and auto-save
  -- when CFN shows a newly completed match (no manual Save hotkey needed).
  auto_capture = true,
  -- How often to check CFN for a new match while SF6 is running.
  auto_poll_seconds = 40,
  -- How often to check whether StreetFighter6.exe is running.
  process_check_seconds = 5,
  filename_format = "{my_char}_vs_{opp_char}_{result}_{mode}_{timestamp}",
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
