-- auto_capture.lua
-- While SF6 is running:
--   - Prefer REFramework battle bridge (match_start / match_end)
--   - match_start → restart Replay Buffer (clip begins at round 1)
--   - match_end   → save Replay Buffer (rename + YouTube via existing handler)
--   - Fallback: CFN poll auto-save if bridge is idle / unavailable

local M = {}

local logger = require("logger")

local State = {}
State.__index = State

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, State)
  self.obs = opts.obs
  self.detector = opts.detector
  self.fetch_fn = opts.fetch_fn
  self.read_match_fn = opts.read_match_fn
  self.get_settings = opts.get_settings
  self.tick_ms = opts.tick_ms or 1000
  self.battle_status_path = opts.battle_status_path

  self._timer_on = false
  self._sf6_running = false
  self._baseline_id = nil
  self._last_saved_id = nil
  self._ms_since_process_check = 0
  self._ms_since_cfn_poll = 0
  self._busy = false
  self._last_bridge_seq = nil
  self._bridge_seen = false
  self._restart_phase = nil -- nil | "stop" | "start"
  self._in_match = false
  self._save_cooldown_until = 0
  return self
end

local function replay_active(obs)
  if not obs or not obs.obs_frontend_replay_buffer_active then
    return false
  end
  local ok, active = pcall(obs.obs_frontend_replay_buffer_active)
  return ok and active == true
end

local function replay_start(obs)
  if not obs or not obs.obs_frontend_replay_buffer_start then
    return false
  end
  local ok = pcall(obs.obs_frontend_replay_buffer_start)
  return ok == true
end

local function replay_stop(obs)
  if not obs or not obs.obs_frontend_replay_buffer_stop then
    return false
  end
  local ok = pcall(obs.obs_frontend_replay_buffer_stop)
  return ok == true
end

local function replay_save(obs)
  if not obs or not obs.obs_frontend_replay_buffer_save then
    return false, "obs_frontend_replay_buffer_save unavailable"
  end
  local ok, err = pcall(obs.obs_frontend_replay_buffer_save)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

-- REFramework writes into <SF6>\reframework\data (see sf6_obs_battle_bridge.lua).
local STATUS_FILE = "sf6_obs_battle_status.json"
local SF6_DATA_DIRS = {
  "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Street Fighter 6\\reframework\\data\\",
  "C:\\Program Files\\Steam\\steamapps\\common\\Street Fighter 6\\reframework\\data\\",
}

local function default_battle_status_path()
  for _, dir in ipairs(SF6_DATA_DIRS) do
    local f = io.open(dir .. STATUS_FILE, "rb")
    if f then
      f:close()
      return dir .. STATUS_FILE
    end
  end
  -- Not written yet: return the most likely path so polling starts once the bridge runs.
  return SF6_DATA_DIRS[1] .. STATUS_FILE
end

local function read_battle_status(path)
  if not path or path == "" then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return nil
  end
  local state = content:match('"state"%s*:%s*"([^"]+)"')
  local seq = tonumber(content:match('"seq"%s*:%s*(%d+)'))
  local t = tonumber(content:match('"t"%s*:%s*(%d+)'))
  local reason = content:match('"reason"%s*:%s*"([^"]*)"')
  if not state or not seq then
    return nil
  end
  return { state = state, seq = seq, t = t, reason = reason or "" }
end

function State:_settings()
  return self.get_settings() or {}
end

function State:_status_path()
  local settings = self:_settings()
  if settings.battle_status_path and settings.battle_status_path ~= "" then
    return settings.battle_status_path
  end
  return self.battle_status_path or default_battle_status_path()
end

function State:_on_sf6_started()
  logger.info("SF6 detected — auto-capture armed")
  self._baseline_id = nil
  self._ms_since_cfn_poll = 0
  self._last_bridge_seq = nil
  self._bridge_seen = false
  self._pending_bridge_saves = 0
  self._in_match = false
  self._restart_phase = nil
  if not replay_active(self.obs) then
    if replay_start(self.obs) then
      logger.info("Replay Buffer started")
    else
      logger.warn("Could not start Replay Buffer — start it manually in OBS")
    end
  end
  self:_poll_cfn(true)
end

function State:_on_sf6_stopped()
  logger.info("SF6 closed — auto-capture idle")
  self._baseline_id = nil
  self._ms_since_cfn_poll = 0
  self._in_match = false
  self._restart_phase = nil
end

function State:_ensure_replay_buffer()
  if replay_active(self.obs) then
    return true
  end
  if replay_start(self.obs) then
    logger.info("Replay Buffer started")
    return true
  end
  logger.warn("Replay Buffer not active")
  return false
end

function State:_restart_buffer_for_match()
  logger.info("Match start — restarting Replay Buffer at round 1")
  self._in_match = true
  self._restart_phase = "stop"
  if replay_active(self.obs) then
    replay_stop(self.obs)
  else
    self._restart_phase = "start"
  end
end

function State:_finish_restart_if_needed()
  if not self._restart_phase then
    return
  end
  if self._restart_phase == "stop" then
    -- Wait until stop completes, then start fresh.
    if replay_active(self.obs) then
      return
    end
    self._restart_phase = "start"
  end
  if self._restart_phase == "start" then
    if replay_start(self.obs) then
      logger.info("Replay Buffer restarted for new match")
    else
      logger.warn("Failed to restart Replay Buffer after match start")
    end
    self._restart_phase = nil
  end
end

function State:_save_for_match_end(reason)
  local now = os.time()
  if now < (self._save_cooldown_until or 0) then
    logger.debug("Save cooldown active; skipping duplicate match_end")
    return
  end
  self._in_match = false
  if not self:_ensure_replay_buffer() then
    return
  end
  logger.info("Match end (" .. tostring(reason) .. ") — saving Replay Buffer")
  local saved, save_err = replay_save(self.obs)
  if not saved then
    logger.warn("Auto-save failed: " .. tostring(save_err))
    return
  end
  self._save_cooldown_until = now + 8
  self._pending_bridge_saves = (self._pending_bridge_saves or 0) + 1
end

function State:_handle_bridge_event(ev)
  if not ev then
    return
  end
  -- seq restarts when REFramework reloads, so key on seq + timestamp.
  local key = tostring(ev.seq) .. "@" .. tostring(ev.t or 0)
  if self._last_bridge_seq == key then
    return
  end
  self._last_bridge_seq = key
  self._bridge_seen = true

  if ev.state == "match_start" then
    self:_restart_buffer_for_match()
  elseif ev.state == "match_end" then
    self:_save_for_match_end(ev.reason or "bridge")
  elseif ev.state == "idle" then
    logger.info("REFramework battle bridge connected")
  end
end

function State:_poll_bridge()
  local settings = self:_settings()
  if settings.use_battle_bridge == false then
    return
  end
  local ev = read_battle_status(self:_status_path())
  if not ev then
    return
  end
  self:_handle_bridge_event(ev)
end

function State:_poll_cfn(baseline_only)
  if self._busy then
    return
  end
  local settings = self:_settings()
  self._busy = true
  local ok, err = self.fetch_fn({
    short_id = settings.cfn_short_id,
    cookie_path = settings.buckler_cookie_path,
    modes = settings.cfn_modes,
    python_path = settings.youtube_python_path,
    timeout_ms = settings.cfn_fetch_timeout_ms,
  })
  self._busy = false
  self._ms_since_cfn_poll = 0

  if not ok then
    logger.debug("Auto CFN poll failed: " .. tostring(err))
    return
  end

  local match, match_err = self.read_match_fn()
  if not match then
    logger.debug("Auto CFN poll: no match (" .. tostring(match_err) .. ")")
    return
  end

  local id = tostring(match.match_id or match.replay_id or "")
  if id == "" then
    return
  end

  if baseline_only or self._baseline_id == nil then
    self._baseline_id = id
    logger.info("CFN baseline match: " .. id)
    return
  end

  if id == self._baseline_id or id == self._last_saved_id then
    logger.debug("CFN poll: no new match")
    return
  end

  -- Each bridge match_end save already covers one CFN match. Consume that
  -- credit here so the same match is not saved twice. If the bridge never
  -- fired (no credit), CFN saves the clip as a backup.
  if (self._pending_bridge_saves or 0) > 0 then
    self._pending_bridge_saves = self._pending_bridge_saves - 1
    self._baseline_id = id
    self._last_saved_id = id
    logger.info("CFN match " .. id .. " already saved by bridge; skipping backup save")
    return
  end

  logger.info(
    string.format(
      "New CFN match: %s vs %s %s — saving Replay Buffer",
      tostring(match.my_character),
      tostring(match.opp_character),
      tostring(match.result)
    )
  )

  if not self:_ensure_replay_buffer() then
    return
  end

  local saved, save_err = replay_save(self.obs)
  if not saved then
    logger.warn("Auto-save failed: " .. tostring(save_err))
    return
  end

  self._last_saved_id = id
  self._baseline_id = id
end

function State:_tick()
  local settings = self:_settings()
  if not settings.enabled or not settings.auto_capture then
    return
  end

  local tick = self.tick_ms
  self._ms_since_process_check = self._ms_since_process_check + tick

  local process_ms = (tonumber(settings.process_check_seconds) or 5) * 1000
  if self._ms_since_process_check >= process_ms then
    self._ms_since_process_check = 0
    local running = self.detector.is_running()
    if running and not self._sf6_running then
      self._sf6_running = true
      self:_on_sf6_started()
    elseif (not running) and self._sf6_running then
      self._sf6_running = false
      self:_on_sf6_stopped()
    end
  end

  if not self._sf6_running then
    return
  end

  self:_finish_restart_if_needed()
  self:_poll_bridge()

  -- Keep buffer alive unless we are mid-restart.
  if not self._restart_phase then
    self:_ensure_replay_buffer()
  end

  self._ms_since_cfn_poll = self._ms_since_cfn_poll + tick
  local poll_ms = (tonumber(settings.auto_poll_seconds) or 40) * 1000
  if self._ms_since_cfn_poll >= poll_ms then
    self:_poll_cfn(false)
  end
end

function State:start()
  if self._timer_on then
    return
  end
  local obs = self.obs
  if not obs or not obs.timer_add then
    return
  end
  self._on_tick = function()
    self:_tick()
  end
  obs.timer_add(self._on_tick, self.tick_ms)
  self._timer_on = true
  logger.info("Auto-capture monitor started (REFramework bridge + CFN backup)")
end

function State:stop()
  if not self._timer_on then
    return
  end
  local obs = self.obs
  if obs and obs.timer_remove and self._on_tick then
    obs.timer_remove(self._on_tick)
  end
  self._timer_on = false
  self._sf6_running = false
  self._baseline_id = nil
  self._restart_phase = nil
  logger.info("Auto-capture monitor stopped")
end

function State:restart()
  self:stop()
  local settings = self:_settings()
  if settings.enabled and settings.auto_capture then
    self:start()
  end
end

M.default_battle_status_path = default_battle_status_path

return M
