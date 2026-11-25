-- logger.lua
-- Prefixed logging for the SF6 replay namer.

local M = {}

local obs = nil
local debug_enabled = false

function M.init(obs_module)
  obs = obs_module
end

function M.set_debug(enabled)
  debug_enabled = enabled and true or false
end

local function emit(level, message)
  local line = "[SF6Replay] " .. tostring(message)
  if obs and obs.script_log then
    obs.script_log(level, line)
  else
    print(line)
  end
end

function M.info(message)
  emit(obs and obs.LOG_INFO or 2, message)
end

function M.warn(message)
  emit(obs and obs.LOG_WARNING or 3, message)
end

function M.error(message)
  emit(obs and obs.LOG_ERROR or 1, message)
end

function M.debug(message)
  if debug_enabled then
    emit(obs and obs.LOG_INFO or 2, message)
  end
end

return M
