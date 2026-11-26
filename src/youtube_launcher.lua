-- youtube_launcher.lua
-- Spawn the companion Python YouTube uploader without blocking OBS.
-- Uses Win32 CreateProcess(CREATE_NO_WINDOW) so no console flashes.

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

local function basename_without_ext(path)
  local file = path:match("([^\\/]+)$") or path
  local name = file:match("^(.*)%.[^%.]+$")
  return name or file
end

local function temp_dir()
  return os.getenv("TEMP") or os.getenv("TMP") or "."
end

local function unique_temp(prefix, ext)
  return string.format(
    "%s\\%s_%d_%d.%s",
    temp_dir(),
    prefix,
    os.time(),
    math.random(1000, 9999),
    ext
  )
end

--- Prefer pythonw.exe so Windows does not allocate a console.
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

--- Escape text for a PowerShell single-quoted string.
local function ps_single(s)
  return tostring(s):gsub("'", "''")
end

--- Quote one cmdline argument for CreateProcess.
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

--- Resolve pythonw to an absolute path (no shell / where.exe).
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

  local pf = os.getenv("ProgramFiles")
  if pf then
    local guess = pf .. "\\Python312\\pythonw.exe"
    if file_is_executable(guess) then
      return guess
    end
  end

  return candidate
end

local JSON_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

--- Encode a flat table of string/number/boolean values as a JSON object.
local function encode_flat_json(tbl)
  local keys = {}
  for k, v in pairs(tbl) do
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = tbl[k]
    local encoded
    if type(v) == "string" then
      local escaped = v:gsub('[%c"\\]', function(c)
        return JSON_ESCAPES[c] or string.format("\\u%04x", c:byte())
      end)
      encoded = '"' .. escaped .. '"'
    else
      encoded = tostring(v)
    end
    parts[#parts + 1] = '"' .. k .. '":' .. encoded
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Run a command with no console window.
local function run_hidden(command_line)
  if win_silent.run_hidden(command_line) then
    return true
  end
  logger.warn("Silent process spawn failed")
  return false
end

--- Resolve the uploader script path (sibling of this module by default).
function M.uploader_script_path()
  return script_dir() .. "youtube_uploader.py"
end

--- Brief tray/balloon notification (clears after ~1s). Non-blocking, no console.
function M.notify(title, message, duration_ms)
  duration_ms = duration_ms or 1000
  local ps1 = unique_temp("sf6_yt_toast", "ps1")
  local f = io.open(ps1, "wb")
  if not f then
    logger.debug("Could not write notification script")
    return false
  end

  f:write("Add-Type -AssemblyName System.Windows.Forms\r\n")
  f:write("Add-Type -AssemblyName System.Drawing\r\n")
  f:write("$n = New-Object System.Windows.Forms.NotifyIcon\r\n")
  f:write("$n.Icon = [System.Drawing.SystemIcons]::Information\r\n")
  f:write("$n.Visible = $true\r\n")
  f:write("$n.BalloonTipTitle = '" .. ps_single(title) .. "'\r\n")
  f:write("$n.BalloonTipText = '" .. ps_single(message) .. "'\r\n")
  f:write("$n.ShowBalloonTip(" .. tostring(duration_ms) .. ")\r\n")
  f:write("Start-Sleep -Milliseconds " .. tostring(duration_ms + 200) .. "\r\n")
  f:write("$n.Visible = $false\r\n")
  f:write("$n.Dispose()\r\n")
  f:write(
    "Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue\r\n"
  )
  f:close()

  -- powershell.exe still allocates a console unless started with CREATE_NO_WINDOW.
  local plain = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "
    .. win_quote(ps1)
  return run_hidden(plain)
end

--- Launch a detached upload for a successfully processed local clip.
--- Never raises; logs failures. Does not wait for upload completion.
function M.launch_upload(opts)
  opts = opts or {}
  local video_path = opts.video_path
  if not video_path or video_path == "" then
    logger.warn("YouTube upload skipped: missing video path")
    return false
  end

  local title = opts.title
  if not title or title == "" then
    title = basename_without_ext(video_path)
  end

  local privacy = opts.privacy or "unlisted"
  local python_path = resolve_pythonw(opts.python_path)
  local client_secret = opts.client_secret_path or ""
  local description = opts.description or ""
  local uploader = opts.uploader_script or M.uploader_script_path()

  local desc_file = nil
  if description ~= "" then
    desc_file = unique_temp("sf6_yt_desc", "txt")
    local df = io.open(desc_file, "wb")
    if df then
      df:write(description)
      df:close()
    else
      desc_file = nil
    end
  end

  -- Global argparse flags (--client-secret, --token) must come BEFORE the
  -- subcommand; otherwise pythonw exits with "unrecognized arguments" and no log.
  local parts = {
    win_quote(python_path),
    win_quote(uploader),
  }
  if client_secret ~= "" then
    parts[#parts + 1] = "--client-secret"
    parts[#parts + 1] = win_quote(client_secret)
  end
  parts[#parts + 1] = "upload"
  parts[#parts + 1] = win_quote(video_path)
  parts[#parts + 1] = "--title"
  parts[#parts + 1] = win_quote(title)
  parts[#parts + 1] = "--privacy"
  parts[#parts + 1] = win_quote(privacy)
  if desc_file then
    parts[#parts + 1] = "--description-file"
    parts[#parts + 1] = win_quote(desc_file)
  end
  -- Optional: log the match to the training notes sheet after the upload.
  local sheet = opts.sheet or ""
  if sheet ~= "" and type(opts.match) == "table" then
    local match_file = unique_temp("sf6_match", "json")
    local mf = io.open(match_file, "wb")
    if mf then
      mf:write(encode_flat_json(opts.match))
      mf:close()
      parts[#parts + 1] = "--match-file"
      parts[#parts + 1] = win_quote(match_file)
      parts[#parts + 1] = "--sheet"
      parts[#parts + 1] = win_quote(sheet)
    else
      logger.warn("Could not write match file; training sheet row skipped")
    end
  end
  local cmdline = table.concat(parts, " ")

  logger.info("YouTube upload queued: " .. (video_path:match("([^\\/]+)$") or video_path))
  logger.debug("YouTube spawn: " .. cmdline)

  local ok = run_hidden(cmdline)
  if not ok then
    logger.warn("Failed to start YouTube uploader (local clip kept)")
    return false
  end
  return true
end

return M
