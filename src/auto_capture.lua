-- auto_capture.lua
-- While SF6 is running: keep Replay Buffer hot, poll CFN, auto-save on new match.
--
-- CFN only updates after a match ends, so "start" = rolling Replay Buffer always
-- on; "stop"/export = save when a new battlelog entry appears.

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

  self._timer_on = false
  self._sf6_running = false
  self._baseline_id = nil
  self._last_saved_id = nil
  self._ms_since_process_check = 0
  self._ms_since_cfn_poll = 0
  self._busy = false
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

function State:_settings()
  return self.get_settings() or {}
end

function State:_on_sf6_started()
  logger.info("SF6 detected — auto-capture armed (baselining CFN, starting Replay Buffer)")
  self._baseline_id = nil
  self._ms_since_cfn_poll = 0
  local obs = self.obs
  if not replay_active(obs) then
    if replay_start(obs) then
      logger.info("Replay Buffer started")
    else
      logger.warn("Could not start Replay Buffer — start it manually in OBS")
    end
  end
  -- Immediate baseline so we don't save an already-finished match.
  self:_poll_cfn(true)
end

function State:_on_sf6_stopped()
  logger.info("SF6 closed — auto-capture idle")
  self._baseline_id = nil
  self._ms_since_cfn_poll = 0
end

function State:_ensure_replay_buffer()
  local obs = self.obs
  if replay_active(obs) then
    return true
  end
  if replay_start(obs) then
    logger.info("Replay Buffer started")
    return true
  end
  logger.warn("Replay Buffer not active")
  return false
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
    logger.info("CFN baseline match: " .. id .. " (will auto-save only newer matches)")
    return
  end

  if id == self._baseline_id or id == self._last_saved_id then
    logger.debug("CFN poll: no new match")
    return
  end

  -- New match appeared after our baseline.
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
  -- REPLAY_BUFFER_SAVED handler performs rename + YouTube.
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

  self:_ensure_replay_buffer()
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
  logger.info("Auto-capture monitor started")
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
  logger.info("Auto-capture monitor stopped")
end

function State:restart()
  self:stop()
  local settings = self:_settings()
  if settings.enabled and settings.auto_capture then
    self:start()
  end
end

return M
