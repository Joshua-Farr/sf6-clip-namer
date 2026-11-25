--[[
  Street Fighter 6 OBS Replay Buffer Auto-Naming
  Tools → Scripts → +  (add this file; keep sibling modules beside it)

  Renames saved Replay Buffer clips using the latest CFN / Buckler match:
    {my_char}_vs_{opp_char}_{result}_{mode}_{timestamp}

  Organizes clips into per-character folders and optionally uploads to YouTube.

  Idle behavior: no timers, no CFN polling.
  Work happens only when OBS fires REPLAY_BUFFER_SAVED.
]]

local obs = obslua

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("(.*[/\\])")
  return dir or "./"
end

package.path = script_dir() .. "?.lua;" .. package.path

local config = require("config")
local logger = require("logger")
local detector = require("sf6_detector")
local cfn_launcher = require("cfn_launcher")
local result_provider = require("result_provider")
local match_tracker = require("match_tracker")
local formatter = require("filename_formatter")
local renamer = require("file_renamer")
local youtube_launcher = require("youtube_launcher")

local settings_state = config.copy_defaults()
local provider = result_provider.new({
  cache_path = cfn_launcher.default_cache_path(),
})
local tracker = match_tracker.new({
  max_age_seconds = settings_state.max_age_minutes * 60,
  allow_multiple = settings_state.allow_multiple_clips,
})

local pending_rename = nil
local attempt_pending_rename

local function apply_settings()
  provider:set_cache_path(cfn_launcher.default_cache_path())
  tracker:set_max_age_seconds(settings_state.max_age_minutes * 60)
  tracker:set_allow_multiple(settings_state.allow_multiple_clips)
  logger.set_debug(settings_state.debug_logging)
end

local function maybe_queue_youtube(dest_path, youtube_title, youtube_description)
  if not settings_state.youtube_upload_enabled then
    logger.info("YouTube upload disabled in script settings; skipping")
    return
  end
  local started = youtube_launcher.launch_upload({
    video_path = dest_path,
    title = youtube_title,
    description = youtube_description,
    privacy = settings_state.youtube_privacy,
    python_path = settings_state.youtube_python_path,
    client_secret_path = settings_state.youtube_client_secret_path,
  })
  if started then
    youtube_launcher.notify(
      "SF6 Replay",
      "Match captured and uploading to YouTube",
      1000
    )
  end
end

attempt_pending_rename = function()
  local job = pending_rename
  if not job then
    return
  end

  job.attempts = job.attempts + 1
  local ok, err = renamer.rename(job.source, job.dest)
  if ok then
    logger.info("Original: " .. job.source:match("([^\\/]+)$"))
    logger.info("Renamed: " .. job.dest:match("([^\\/]+)$"))
    if job.character_folder then
      logger.info("Folder: " .. job.character_folder)
    end
    tracker:mark_used(job.match)
    maybe_queue_youtube(job.dest, job.youtube_title, job.youtube_description)
    pending_rename = nil
    obs.timer_remove(attempt_pending_rename)
    return
  end

  logger.debug("Rename attempt " .. job.attempts .. ": " .. tostring(err))
  if job.attempts >= settings_state.rename_attempts then
    logger.warn("Rename failed; leaving original file. " .. tostring(err))
    pending_rename = nil
    obs.timer_remove(attempt_pending_rename)
  end
end

local function schedule_rename(source, dest, match, character_folder, youtube_title, youtube_description)
  pending_rename = {
    source = source,
    dest = dest,
    match = match,
    character_folder = character_folder,
    youtube_title = youtube_title,
    youtube_description = youtube_description,
    attempts = 0,
  }
  obs.timer_remove(attempt_pending_rename)
  obs.timer_add(attempt_pending_rename, settings_state.rename_delay_ms)
end

local function handle_replay_saved()
  logger.info("Replay buffer saved")

  if not settings_state.enabled then
    logger.debug("Disabled; skipping rename")
    return
  end

  if not detector.is_running() then
    logger.debug("Street Fighter 6 not running; preserving OBS name")
    return
  end
  logger.info("Street Fighter 6 detected")

  local fetch_ok, fetch_err = cfn_launcher.fetch_latest({
    short_id = settings_state.cfn_short_id,
    cookie_path = settings_state.buckler_cookie_path,
    modes = settings_state.cfn_modes,
    python_path = settings_state.youtube_python_path,
    timeout_ms = settings_state.cfn_fetch_timeout_ms,
    cache_path = cfn_launcher.default_cache_path(),
  })
  if not fetch_ok then
    logger.warn("CFN fetch failed; preserving OBS name. " .. tostring(fetch_err))
    return
  end

  local match, match_err = provider:get_newest_match()
  if not match then
    logger.debug("No match available: " .. tostring(match_err))
    return
  end

  tracker:set_latest(match)
  local eligible, reason = tracker:match_for_replay(os.time())
  if not eligible then
    logger.debug("No eligible match: " .. tostring(reason))
    return
  end

  local source = obs.obs_frontend_get_last_replay()
  if not source or source == "" then
    logger.warn("Could not determine replay output path")
    return
  end

  local source_dir, _, ext = formatter.split_extension(source)
  local now = os.time()
  local ts = formatter.format_timestamp(now, settings_state.timestamp_format)
  local basename = formatter.build_basename(settings_state.filename_format, eligible, ts)
  if not basename then
    logger.warn("Could not build filename; preserving original")
    return
  end

  local youtube_title = formatter.build_youtube_title(eligible)
  local youtube_description = formatter.build_youtube_description(now, eligible)

  local dest_dir = source_dir
  local character_folder = nil
  if settings_state.organize_by_character then
    local root = settings_state.clips_root_dir
    if not root or root == "" then
      root = source_dir
    end
    if root ~= "" and not root:match("[/\\]$") then
      root = root .. "\\"
    end
    character_folder = formatter.sanitize_dir_name(eligible.my_character)
    dest_dir = formatter.join_dir(root, character_folder)
  end

  local dest = formatter.unique_path(dest_dir, basename, ext, renamer.file_exists)
  if not dest then
    logger.warn("Could not allocate unique filename; preserving original")
    return
  end

  schedule_rename(source, dest, eligible, character_folder, youtube_title, youtube_description)
end

local function on_event(event)
  if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
    handle_replay_saved()
  end
end

-- OBS script API -------------------------------------------------------------

function script_description()
  return [[Street Fighter 6 Replay Buffer Auto-Naming

Renames Replay Buffer clips to
{my_char}_vs_{opp_char}_{result}_{mode}_{timestamp} (Central Time)
using the latest match from CFN / Buckler's Boot Camp. Optionally organizes
clips into per-character folders and uploads them to YouTube (unlisted).

Only active while StreetFighter6.exe is running.
Idle: no background timers or CFN polling.
Requires a Buckler session cookie (buckler_id) and your numeric CFN short_id.]]
end

function script_properties()
  local props = obs.obs_properties_create()

  obs.obs_properties_add_bool(props, "enabled", "Enable SF6 replay naming")
  obs.obs_properties_add_text(props, "cfn_short_id", "CFN short_id (profile URL number)", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_path(
    props,
    "buckler_cookie_path",
    "Buckler cookie file (buckler_id=...)",
    obs.OBS_PATH_FILE,
    "Text (*.txt)",
    cfn_launcher.default_cookie_path()
  )
  obs.obs_properties_add_text(
    props,
    "cfn_modes",
    "Battlelog modes (comma-separated)",
    obs.OBS_TEXT_DEFAULT
  )
  obs.obs_properties_add_text(props, "filename_format", "Filename format", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(props, "timestamp_format", "Timestamp format", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int(props, "max_age_minutes", "Maximum match age (minutes)", 1, 180, 1)
  obs.obs_properties_add_bool(props, "allow_multiple_clips", "Allow multiple clips per match")
  obs.obs_properties_add_bool(props, "organize_by_character", "Organize clips into character folders")
  obs.obs_properties_add_path(
    props,
    "clips_root_dir",
    "Clips root folder (empty = OBS replay folder)",
    obs.OBS_PATH_DIRECTORY,
    nil,
    ""
  )
  obs.obs_properties_add_bool(props, "youtube_upload_enabled", "Upload processed clips to YouTube")
  local privacy = obs.obs_properties_add_list(
    props,
    "youtube_privacy",
    "YouTube privacy",
    obs.OBS_COMBO_TYPE_LIST,
    obs.OBS_COMBO_FORMAT_STRING
  )
  obs.obs_property_list_add_string(privacy, "Unlisted", "unlisted")
  obs.obs_property_list_add_string(privacy, "Private", "private")
  obs.obs_property_list_add_string(privacy, "Public", "public")
  obs.obs_properties_add_path(
    props,
    "youtube_client_secret_path",
    "YouTube OAuth client secret JSON",
    obs.OBS_PATH_FILE,
    "JSON (*.json)",
    ""
  )
  obs.obs_properties_add_text(
    props,
    "youtube_python_path",
    "Python executable (empty = pythonw)",
    obs.OBS_TEXT_DEFAULT
  )
  obs.obs_properties_add_bool(props, "debug_logging", "Debug logging")

  return props
end

function script_defaults(settings)
  local d = config.DEFAULTS
  obs.obs_data_set_default_bool(settings, "enabled", d.enabled)
  obs.obs_data_set_default_string(settings, "cfn_short_id", d.cfn_short_id)
  obs.obs_data_set_default_string(settings, "buckler_cookie_path", d.buckler_cookie_path)
  obs.obs_data_set_default_string(settings, "cfn_modes", d.cfn_modes)
  obs.obs_data_set_default_string(settings, "filename_format", d.filename_format)
  obs.obs_data_set_default_string(settings, "timestamp_format", d.timestamp_format)
  obs.obs_data_set_default_int(settings, "max_age_minutes", d.max_age_minutes)
  obs.obs_data_set_default_bool(settings, "allow_multiple_clips", d.allow_multiple_clips)
  obs.obs_data_set_default_bool(settings, "organize_by_character", d.organize_by_character)
  obs.obs_data_set_default_string(settings, "clips_root_dir", d.clips_root_dir)
  obs.obs_data_set_default_bool(settings, "youtube_upload_enabled", d.youtube_upload_enabled)
  obs.obs_data_set_default_string(settings, "youtube_privacy", d.youtube_privacy)
  obs.obs_data_set_default_string(settings, "youtube_client_secret_path", d.youtube_client_secret_path)
  obs.obs_data_set_default_string(settings, "youtube_python_path", d.youtube_python_path)
  obs.obs_data_set_default_bool(settings, "debug_logging", d.debug_logging)
end

function script_update(settings)
  settings_state.enabled = obs.obs_data_get_bool(settings, "enabled")
  settings_state.cfn_short_id = obs.obs_data_get_string(settings, "cfn_short_id") or ""
  local cookie = obs.obs_data_get_string(settings, "buckler_cookie_path")
  if not cookie or cookie == "" then
    cookie = cfn_launcher.default_cookie_path()
  end
  settings_state.buckler_cookie_path = cookie

  local modes = obs.obs_data_get_string(settings, "cfn_modes")
  if not modes or modes == "" then
    modes = config.DEFAULTS.cfn_modes
  end
  settings_state.cfn_modes = modes

  settings_state.filename_format = obs.obs_data_get_string(settings, "filename_format")
  if not settings_state.filename_format or settings_state.filename_format == "" then
    settings_state.filename_format = config.DEFAULTS.filename_format
  end
  settings_state.timestamp_format = obs.obs_data_get_string(settings, "timestamp_format")
  if not settings_state.timestamp_format or settings_state.timestamp_format == "" then
    settings_state.timestamp_format = config.DEFAULTS.timestamp_format
  end
  settings_state.max_age_minutes = obs.obs_data_get_int(settings, "max_age_minutes")
  settings_state.allow_multiple_clips = obs.obs_data_get_bool(settings, "allow_multiple_clips")
  settings_state.organize_by_character = obs.obs_data_get_bool(settings, "organize_by_character")
  settings_state.clips_root_dir = obs.obs_data_get_string(settings, "clips_root_dir") or ""

  settings_state.youtube_client_secret_path =
    obs.obs_data_get_string(settings, "youtube_client_secret_path") or ""
  settings_state.youtube_python_path =
    obs.obs_data_get_string(settings, "youtube_python_path") or ""

  local has_toggle = obs.obs_data_has_user_value
    and obs.obs_data_has_user_value(settings, "youtube_upload_enabled")
  if has_toggle then
    settings_state.youtube_upload_enabled = obs.obs_data_get_bool(settings, "youtube_upload_enabled")
  else
    local auto = settings_state.youtube_client_secret_path ~= ""
      or config.DEFAULTS.youtube_upload_enabled
    settings_state.youtube_upload_enabled = auto
    if auto then
      obs.obs_data_set_bool(settings, "youtube_upload_enabled", true)
    end
  end

  local privacy = obs.obs_data_get_string(settings, "youtube_privacy")
  if privacy == nil or privacy == "" then
    privacy = config.DEFAULTS.youtube_privacy
  end
  settings_state.youtube_privacy = privacy
  settings_state.debug_logging = obs.obs_data_get_bool(settings, "debug_logging")
  apply_settings()
  logger.info(
    "YouTube upload "
      .. (settings_state.youtube_upload_enabled and "enabled" or "disabled")
  )
end

function script_load(settings)
  logger.init(obs)
  script_update(settings)
  apply_settings()
  obs.obs_frontend_add_event_callback(on_event)
  logger.info("Script loaded (event-driven; no background CFN polling)")
end

function script_unload()
  obs.timer_remove(attempt_pending_rename)
  obs.obs_frontend_remove_event_callback(on_event)
  pending_rename = nil
  logger.info("Script unloaded")
end

function script_name()
  return "SF6 Replay Namer"
end
