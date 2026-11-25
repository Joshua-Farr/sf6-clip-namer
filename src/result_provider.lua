-- result_provider.lua
-- Read the latest CFN match from the JSON cache written by cfn_fetch.py.
-- Event-driven: only call after a successful CFN fetch on replay save.

local M = {}

local logger = require("logger")

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decode_string(src, i)
  i = i + 1 -- skip opening quote
  local out = {}
  while i <= #src do
    local c = src:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    end
    if c == "\\" then
      local n = src:sub(i + 1, i + 1)
      local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if n == "u" then
        -- Minimal \uXXXX support (ASCII-ish); good enough for CFN names we care about.
        local hex = src:sub(i + 2, i + 5)
        local code = tonumber(hex, 16) or 63
        out[#out + 1] = string.char(code % 256)
        i = i + 6
      else
        out[#out + 1] = map[n] or n
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return nil, i
end

local parse_value

local function parse_object(src, i)
  local obj = {}
  i = i + 1
  while true do
    while src:sub(i, i):match("[%s\r\n]") do
      i = i + 1
    end
    if src:sub(i, i) == "}" then
      return obj, i + 1
    end
    if src:sub(i, i) ~= '"' then
      return nil, i
    end
    local key
    key, i = decode_string(src, i)
    if not key then
      return nil, i
    end
    while src:sub(i, i):match("[%s\r\n]") do
      i = i + 1
    end
    if src:sub(i, i) ~= ":" then
      return nil, i
    end
    i = i + 1
    local value
    value, i = parse_value(src, i)
    if value == nil and src:sub(i, i) ~= "n" then
      -- allow explicit null via parse_value returning nil for null token carefully
    end
    obj[key] = value
    while src:sub(i, i):match("[%s\r\n]") do
      i = i + 1
    end
    local sep = src:sub(i, i)
    if sep == "}" then
      return obj, i + 1
    end
    if sep ~= "," then
      return nil, i
    end
    i = i + 1
  end
end

parse_value = function(src, i)
  while src:sub(i, i):match("[%s\r\n]") do
    i = i + 1
  end
  local c = src:sub(i, i)
  if c == '"' then
    return decode_string(src, i)
  end
  if c == "{" then
    return parse_object(src, i)
  end
  if c == "[" then
    -- Skip arrays (not needed for our flat match cache).
    local depth = 1
    i = i + 1
    while i <= #src and depth > 0 do
      local ch = src:sub(i, i)
      if ch == '"' then
        local _
        _, i = decode_string(src, i)
      elseif ch == "[" then
        depth = depth + 1
        i = i + 1
      elseif ch == "]" then
        depth = depth - 1
        i = i + 1
      else
        i = i + 1
      end
    end
    return {}, i
  end
  if src:sub(i, i + 3) == "null" then
    return nil, i + 4
  end
  if src:sub(i, i + 3) == "true" then
    return true, i + 4
  end
  if src:sub(i, i + 4) == "false" then
    return false, i + 5
  end
  local num = src:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  if num then
    return tonumber(num), i + #num
  end
  return nil, i
end

function M.parse_json_object(content)
  if not content or content == "" then
    return nil, "empty json"
  end
  local value, _ = parse_value(content, 1)
  if type(value) ~= "table" then
    return nil, "expected object"
  end
  return value, nil
end

function M.normalize_match(raw)
  if type(raw) ~= "table" then
    return nil, "invalid match"
  end
  local my = trim(raw.my_character)
  local opp = trim(raw.opp_character)
  local result = trim(raw.result)
  local match_id = trim(raw.match_id or raw.replay_id)
  local completed_at = tonumber(raw.completed_at)
  if my == "" or opp == "" or result == "" or not completed_at then
    return nil, "incomplete match fields"
  end
  return {
    match_id = match_id,
    replay_id = trim(raw.replay_id or match_id),
    completed_at = completed_at,
    my_character = my,
    opp_character = opp,
    opp_name = trim(raw.opp_name),
    result = result,
    mode = trim(raw.mode),
    mode_label = trim(raw.mode_label),
    my_mr = raw.my_mr,
    opp_mr = raw.opp_mr,
    my_lp = raw.my_lp,
    opp_lp = raw.opp_lp,
    fetched_at = tonumber(raw.fetched_at),
  }, nil
end

function M.parse_match_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, tostring(err or "open failed")
  end
  local content = f:read("*a")
  f:close()
  local raw, perr = M.parse_json_object(content)
  if not raw then
    return nil, perr
  end
  return M.normalize_match(raw)
end

local Provider = {}
Provider.__index = Provider

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Provider)
  self.cache_path = opts.cache_path or ""
  self.read_file_fn = opts.read_file_fn or M.parse_match_file
  return self
end

function Provider:set_cache_path(path)
  self.cache_path = path or ""
end

function Provider:get_newest_match()
  if not self.cache_path or self.cache_path == "" then
    return nil, "missing cache path"
  end
  local match, err = self.read_file_fn(self.cache_path)
  if not match then
    return nil, tostring(err or "parse failed")
  end
  logger.info(
    string.format(
      "Match: %s vs %s %s (%s)",
      match.my_character,
      match.opp_character,
      match.result,
      match.mode_label ~= "" and match.mode_label or match.mode
    )
  )
  return match, nil
end

M.Provider = Provider

return M
