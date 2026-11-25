-- filename_formatter.lua
-- Sanitize names and build replay filenames from a format template.

local M = {}

local INVALID_CHARS = '[\\/:*?"<>|]'

function M.sanitize_component(value)
  if value == nil then
    return ""
  end
  local s = tostring(value)
  s = s:gsub(INVALID_CHARS, "_")
  s = s:gsub("%s+", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_", ""):gsub("_$", "")
  return s
end

--- Keep spaces for readable titles like "0-2 Cammy vs Ryu Ranked SF6 MR1550".
--- Only strip filesystem-illegal characters.
function M.sanitize_filename(value)
  if value == nil then
    return ""
  end
  local s = tostring(value)
  s = s:gsub(INVALID_CHARS, " ")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("[%.%s]+$", "")
  return s
end

--- Sanitize a character name for use as a directory name.
--- Keeps spaces; only replaces filesystem-illegal characters.
function M.sanitize_dir_name(value)
  if value == nil then
    return "Unknown"
  end
  local s = tostring(value)
  s = s:gsub(INVALID_CHARS, "_")
  s = s:gsub("[_%s]+", function(chunk)
    if chunk:find("%s") then
      return " "
    end
    return "_"
  end)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("[%.%s]+$", "")
  s = s:gsub("^_", ""):gsub("_$", "")
  if s == "" then
    return "Unknown"
  end
  return s
end

--- Join directory parts with a trailing separator on the result directory.
function M.join_dir(root, child)
  root = tostring(root or "")
  child = tostring(child or "")
  if root ~= "" and not root:match("[/\\]$") then
    root = root .. "\\"
  end
  return root .. child .. "\\"
end

--- Day of week for a Gregorian date: 0 = Sunday .. 6 = Saturday.
local function dow(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  local yy = y
  if m < 3 then
    yy = yy - 1
  end
  return (yy + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) + t[m] + d) % 7
end

local function nth_weekday(year, month, weekday, n)
  local first = dow(year, month, 1)
  return 1 + (weekday - first + 7) % 7 + 7 * (n - 1)
end

--- True when America/Chicago is on daylight time for this UTC unix time.
local function chicago_is_dst(unix_time)
  local u = os.date("!*t", unix_time)
  local y = u.year
  local dst_start_day = nth_weekday(y, 3, 0, 2)
  local dst_end_day = nth_weekday(y, 11, 0, 1)

  local function utc_ymd_hms_to_unix(year, month, day, hour, min, sec)
    local lo, hi = 0, 4102444800
    while lo < hi do
      local mid = math.floor((lo + hi) / 2)
      local t = os.date("!*t", mid)
      local before = t.year < year
        or (t.year == year and t.month < month)
        or (t.year == year and t.month == month and t.day < day)
        or (t.year == year and t.month == month and t.day == day and t.hour < hour)
        or (t.year == year and t.month == month and t.day == day and t.hour == hour and t.min < min)
        or (t.year == year and t.month == month and t.day == day and t.hour == hour and t.min == min and t.sec < sec)
      if before then
        lo = mid + 1
      else
        hi = mid
      end
    end
    return lo
  end

  local start = utc_ymd_hms_to_unix(y, 3, dst_start_day, 8, 0, 0)
  local ending = utc_ymd_hms_to_unix(y, 11, dst_end_day, 7, 0, 0)
  return unix_time >= start and unix_time < ending
end

--- Wall-clock fields in America/Chicago (Central Time).
function M.central_date(unix_time)
  unix_time = unix_time or os.time()
  local offset = chicago_is_dst(unix_time) and -5 * 3600 or -6 * 3600
  return os.date("!*t", unix_time + offset)
end

--- Format a Unix timestamp in Central Time with a strftime-like pattern.
--- Supported tokens: yyyy MM dd HH mm ss
function M.format_timestamp(unix_time, pattern)
  pattern = pattern or "yyyy-MM-dd_HH-mm-ss"
  local t = M.central_date(unix_time)
  local map = {
    yyyy = string.format("%04d", t.year),
    MM = string.format("%02d", t.month),
    dd = string.format("%02d", t.day),
    HH = string.format("%02d", t.hour),
    mm = string.format("%02d", t.min),
    ss = string.format("%02d", t.sec),
  }
  local out = pattern
  out = out:gsub("yyyy", map.yyyy)
  out = out:gsub("MM", map.MM)
  out = out:gsub("dd", map.dd)
  out = out:gsub("HH", map.HH)
  out = out:gsub("mm", map.mm)
  out = out:gsub("ss", map.ss)
  return out
end

local function nonempty(value)
  if value == nil then
    return nil
  end
  local s = tostring(value)
  if s == "" then
    return nil
  end
  return s
end

--- YouTube title: "0-2 Cammy vs Ryu Ranked SF6 MR1550" style, max 100 chars.
function M.build_youtube_title(match)
  match = match or {}
  local score = nonempty(match.score) or nonempty(match.result) or "?"
  local my = nonempty(match.my_character) or "?"
  local opp = nonempty(match.opp_character) or "?"
  local mode = nonempty(match.mode_label) or nonempty(match.mode) or "Match"
  local rank = nonempty(match.opp_rank)
  local title = string.format("%s %s vs %s %s SF6", score, my, opp, mode)
  if rank then
    title = title .. " " .. rank
  end
  if #title > 100 then
    title = title:sub(1, 100)
  end
  return title
end

--- YouTube description: Central Time + match details.
function M.build_youtube_description(unix_time, match)
  local date_s = M.format_timestamp(unix_time, "yyyy-MM-dd")
  local time_s = M.format_timestamp(unix_time, "HH:mm:ss")
  local lines = {
    "Date: " .. date_s,
    "Time: " .. time_s .. " CT",
  }

  match = match or {}
  local my = nonempty(match.my_character)
  local opp_char = nonempty(match.opp_character)
  local opp_name = nonempty(match.opp_name)
  local result = nonempty(match.result)
  local mode = nonempty(match.mode_label) or nonempty(match.mode)
  local replay_id = nonempty(match.replay_id) or nonempty(match.match_id)
  local my_mr = nonempty(match.my_mr)
  local opp_mr = nonempty(match.opp_mr)

  lines[#lines + 1] = ""
  if my and opp_char then
    lines[#lines + 1] = "Match: " .. my .. " vs " .. opp_char
  end
  if opp_name then
    lines[#lines + 1] = "Opponent: " .. opp_name
  end
  if result then
    lines[#lines + 1] = "Result: " .. result
  end
  if mode then
    lines[#lines + 1] = "Mode: " .. mode
  end
  local score = nonempty(match.score)
  local opp_rank = nonempty(match.opp_rank)
  local my_rank = nonempty(match.my_rank)
  if score then
    lines[#lines + 1] = "Score: " .. score
  end
  if my_rank or opp_rank then
    lines[#lines + 1] = "Rank: " .. (my_rank or "?") .. " vs " .. (opp_rank or "?")
  elseif my_mr or opp_mr then
    lines[#lines + 1] = "MR: " .. (my_mr or "?") .. " vs " .. (opp_mr or "?")
  end
  if replay_id then
    lines[#lines + 1] = "Replay ID: " .. replay_id
  end

  return table.concat(lines, "\n")
end

function M.split_extension(path)
  local dir, file = path:match("^(.-)([^\\/]+)$")
  if not file then
    return "", path, ""
  end
  local name, ext = file:match("^(.*)(%.[^%.]+)$")
  if not name then
    return dir or "", file, ""
  end
  return dir or "", name, ext
end

--- Build a target filename (name only) from format and match data.
--- Default keeps spaces: "0-2 Cammy vs Ryu Ranked SF6 MR1550"
function M.build_basename(fmt, match, timestamp_str)
  match = match or {}
  local score = M.sanitize_filename(match.score or match.result)
  local my = M.sanitize_filename(match.my_character)
  local opp = M.sanitize_filename(match.opp_character)
  local result = M.sanitize_filename(match.result)
  local mode = M.sanitize_filename(match.mode_label or match.mode)
  local opp_rank = M.sanitize_filename(match.opp_rank)
  local my_rank = M.sanitize_filename(match.my_rank)
  local opp_name = M.sanitize_filename(match.opp_name)
  local ts_s = M.sanitize_filename(timestamp_str)
  if my == "" or opp == "" then
    return nil
  end
  if score == "" and result == "" then
    return nil
  end
  local name = fmt or "{score} {my_char} vs {opp_char} {mode} SF6 {opp_rank}"
  name = name:gsub("{score}", score)
  name = name:gsub("{my_char}", my)
  name = name:gsub("{opp_char}", opp)
  name = name:gsub("{result}", result)
  name = name:gsub("{mode}", mode)
  name = name:gsub("{opp_rank}", opp_rank)
  name = name:gsub("{my_rank}", my_rank)
  name = name:gsub("{opp_name}", opp_name)
  name = name:gsub("{timestamp}", ts_s)
  name = M.sanitize_filename(name)
  -- Drop a trailing "SF6" dangling space if opp_rank was empty.
  name = name:gsub("%s+SF6%s*$", " SF6")
  name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return nil
  end
  return name
end

--- Return a unique full path that does not overwrite an existing file.
function M.unique_path(directory, basename, extension, file_exists_fn)
  file_exists_fn = file_exists_fn or function(p)
    local f = io.open(p, "r")
    if f then
      f:close()
      return true
    end
    return false
  end
  local candidate = directory .. basename .. extension
  if not file_exists_fn(candidate) then
    return candidate
  end
  local n = 2
  while true do
    candidate = directory .. basename .. "_" .. tostring(n) .. extension
    if not file_exists_fn(candidate) then
      return candidate
    end
    n = n + 1
    if n > 1000 then
      return nil
    end
  end
end

return M
