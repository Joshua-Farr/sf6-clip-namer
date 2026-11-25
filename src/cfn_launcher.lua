-- cfn_launcher.lua
-- Spawn cfn_fetch.py (hidden) and wait for latest_match.json.

local M = {}

local logger = require("logger")
local win_silent = require("win_silent")

local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("(.*[/\\])")
  return dir or "./"
end

local function win_quote(s)
  return '"' .. tostring(s):gsub('"', '""') .. '"'
end

local function file_is_executable(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function to_pythonw(path)
  if not path or path == "" or path == "python" or path == "python.exe" then
    return "pythonw"
  end
  local replaced = path:gsub("[/\\]python%.exe$", "\\pythonw.exe")
  replaced = replaced:gsub("[/\\]python$", "\\pythonw")
  if replaced:lower():match("pythonw") then
    return replaced
  end
  return path
end

local function resolve_pythonw(path)
  local candidate = to_pythonw(path)
  if candidate:find("[/\\]") then
    return candidate
  end

  local home = os.getenv("LOCALAPPDATA")
  if home then
    local guesses = {
      home .. "\\Programs\\Python\\Python313\\pythonw.exe",
      home .. "\\Programs\\Python\\Python312\\pythonw.exe",
      home .. "\\Programs\\Python\\Python311\\pythonw.exe",
      home .. "\\Programs\\Python\\Python310\\pythonw.exe",
    }
    for _, guess in ipairs(guesses) do
      if file_is_executable(guess) then
        return guess
      end
    end
  end

  return candidate
end

local function appdata_dir()
  local base = os.getenv("APPDATA")
  if not base or base == "" then
    return nil
  end
  return base .. "\\sf6-clip-namer"
end

function M.default_cookie_path()
  local dir = appdata_dir()
  if not dir then
    return ""
  end
  return dir .. "\\buckler_cookie.txt"
end

function M.default_cache_path()
  local dir = appdata_dir()
  if not dir then
    return ""
  end
  return dir .. "\\latest_match.json"
end

function M.fetch_script_path()
  return script_dir() .. "cfn_fetch.py"
end

--- Fetch newest CFN match into cache_path. Blocks OBS briefly (timeout_ms).
--- Returns ok, err
function M.fetch_latest(opts)
  opts = opts or {}
  local short_id = tostring(opts.short_id or ""):match("^%s*(.-)%s*$")
  if not short_id or short_id == "" or not short_id:match("^%d+$") then
    return false, "Set your CFN short_id (numeric id from Buckler profile URL)"
  end

  local cookie_path = opts.cookie_path
  if not cookie_path or cookie_path == "" then
    cookie_path = M.default_cookie_path()
  end
  local cookie_file = cookie_path ~= "" and io.open(cookie_path, "rb") or nil
  if cookie_file then
    cookie_file:close()
  else
    return false, "Buckler cookie file missing: " .. tostring(cookie_path)
  end

  local cache_path = opts.cache_path
  if not cache_path or cache_path == "" then
    cache_path = M.default_cache_path()
  end
  if cache_path == "" then
    return false, "Could not resolve match cache path"
  end

  -- Ensure AppData folder exists so Python can write the cache.
  local cache_dir = cache_path:match("^(.-)[^\\/]+$")
  if cache_dir and cache_dir ~= "" then
    win_silent.ensure_dir(cache_dir)
  end

  local python_path = resolve_pythonw(opts.python_path)
  local script = opts.fetch_script or M.fetch_script_path()
  local modes = opts.modes or "rank,casual"
  local timeout_ms = tonumber(opts.timeout_ms) or 12000

  local parts = {
    win_quote(python_path),
    win_quote(script),
    "fetch",
    "--short-id",
    win_quote(short_id),
    "--cookie",
    win_quote(cookie_path),
    "--out",
    win_quote(cache_path),
    "--modes",
    win_quote(modes),
  }
  local cmdline = table.concat(parts, " ")
  logger.debug("CFN fetch: " .. cmdline)

  local ok, result = win_silent.run_hidden_wait(cmdline, timeout_ms)
  if not ok then
    return false, "CFN fetch failed: " .. tostring(result)
  end
  if result ~= nil and result ~= 0 then
    return false, "CFN fetch exited with code " .. tostring(result)
  end
  return true, cache_path
end

return M
