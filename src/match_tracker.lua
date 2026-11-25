-- match_tracker.lua
-- Track the latest completed CFN match and association / staleness rules.

local M = {}

local Tracker = {}
Tracker.__index = Tracker

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Tracker)
  self.max_age_seconds = opts.max_age_seconds or (15 * 60)
  self.allow_multiple = opts.allow_multiple
  if self.allow_multiple == nil then
    self.allow_multiple = true
  end
  self.latest = nil
  self.used_match_ids = {}
  return self
end

function Tracker:set_max_age_seconds(seconds)
  self.max_age_seconds = tonumber(seconds) or self.max_age_seconds
end

function Tracker:set_allow_multiple(allow)
  self.allow_multiple = allow and true or false
end

function Tracker:set_latest(match)
  if not match then
    return
  end
  self.latest = match
end

function Tracker:get_latest()
  return self.latest
end

function Tracker:clear()
  self.latest = nil
end

local function is_stale(match, max_age_seconds, now)
  if not match or not match.completed_at then
    return true
  end
  now = now or os.time()
  return (now - match.completed_at) > max_age_seconds
end

--- Return an eligible match for a replay saved at `now`, or nil + reason.
function Tracker:match_for_replay(now)
  now = now or os.time()
  local match = self.latest
  if not match then
    return nil, "no completed match"
  end
  if not match.my_character or match.my_character == "" then
    return nil, "missing my_character"
  end
  if not match.opp_character or match.opp_character == "" then
    return nil, "missing opp_character"
  end
  if not match.result or match.result == "" then
    return nil, "missing result"
  end
  if is_stale(match, self.max_age_seconds, now) then
    return nil, "stale match"
  end
  local id = match.match_id or ""
  if not self.allow_multiple and id ~= "" and self.used_match_ids[id] then
    return nil, "match already used"
  end
  return match, nil
end

function Tracker:mark_used(match)
  if not match then
    return
  end
  local id = match.match_id or ""
  if id ~= "" then
    self.used_match_ids[id] = true
  end
end

M.is_stale = is_stale

return M
