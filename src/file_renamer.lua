-- file_renamer.lua
-- Safely rename/move a finished replay file without deleting or overwriting.

local M = {}

local logger = require("logger")
local win_silent = require("win_silent")

local function normalize_dir(path)
  if not path or path == "" then
    return ""
  end
  return path:gsub("/", "\\"):gsub("[\\/]+$", "")
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function file_unlocked(path)
  local f = io.open(path, "r+b")
  if not f then
    return false
  end
  f:close()
  return true
end

--- Return true if path exists as a directory (no console window).
function M.dir_exists(path)
  local p = normalize_dir(path)
  if p == "" then
    return false
  end
  return win_silent.dir_exists(p)
end

--- Ensure directory exists. Creates it (and parents) if missing.
--- Returns ok, err.
function M.ensure_dir(path)
  return win_silent.ensure_dir(path)
end

--- Try to rename/move source -> dest. Returns ok, err.
function M.rename(source, dest)
  if not source or source == "" or not dest or dest == "" then
    return false, "missing path"
  end
  if source == dest then
    return true, nil
  end
  if not file_exists(source) then
    return false, "source missing: " .. tostring(source)
  end
  if file_exists(dest) then
    return false, "destination already exists: " .. tostring(dest)
  end
  if not file_unlocked(source) then
    return false, "source still locked"
  end

  local dest_dir = dest:match("^(.-)[^\\/]+$")
  if dest_dir and dest_dir ~= "" then
    local ok_dir, dir_err = M.ensure_dir(dest_dir)
    if not ok_dir then
      return false, tostring(dir_err or "destination directory missing")
    end
  end

  local ok, err = os.rename(source, dest)
  if not ok then
    return false, tostring(err or "rename failed")
  end
  return true, nil
end

--- Retry rename a few times. Never deletes the source on failure.
function M.rename_with_retries(source, dest, attempts, delay_ms, sleep_fn)
  attempts = attempts or 5
  delay_ms = delay_ms or 250
  sleep_fn = sleep_fn or function(_) end

  for i = 1, attempts do
    local ok, err = M.rename(source, dest)
    if ok then
      logger.info("Original: " .. source)
      logger.info("Renamed: " .. dest)
      return true, nil
    end
    logger.debug(string.format("Rename attempt %d failed: %s", i, tostring(err)))
    if i < attempts then
      sleep_fn(delay_ms)
    else
      logger.warn("Rename failed; leaving original file. " .. tostring(err))
      return false, err
    end
  end
  return false, "rename failed"
end

M.file_exists = file_exists

return M
