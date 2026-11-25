--[[
  sf6_obs_battle_bridge.lua
  REFramework autorun script for Street Fighter 6.

  Detects live battle start/end via gBattle + fight_st and writes a status
  file that the OBS SF6 Replay Namer script polls:

    <SF6>\reframework\data\sf6_obs_battle_status.json

  Install:
    1. Install REFramework (SF6.zip) into the Street Fighter 6 folder
    2. Copy this file to:
         <SF6>\reframework\autorun\sf6_obs_battle_bridge.lua
    3. Launch SF6 once so the reframework folders are created

  fight_st notes (from community tooling):
    0 = idle / not fighting
    7 = fight finished
    other non-zero = fight running

  Note: REFramework's Lua sandbox has no os.getenv, so paths are relative to
  reframework\data (json.dump_file), the same mechanism other SF6 tools use.
]]

local STATUS_FILE = "sf6_obs_battle_status.json"

local last_state = "none" -- none | running | finished
local seq = 0
-- Require a few frames stable before emitting, to avoid flicker.
local STABLE_FRAMES = 8

local function now()
  if os and os.time then
    return os.time()
  end
  return 0
end

local function write_status(state, reason)
  seq = seq + 1
  local payload = {
    state = state,
    seq = seq,
    t = now(),
    reason = reason or "",
    source = "reframework",
  }
  local ok, err = pcall(function()
    json.dump_file(STATUS_FILE, payload)
  end)
  if ok then
    log.info(string.format("[sf6_obs_bridge] %s seq=%d (%s)", state, seq, tostring(reason)))
  else
    log.info("[sf6_obs_bridge] write failed: " .. tostring(err))
  end
end

local function read_fight_state()
  local gBattle = sdk.find_type_definition("gBattle")
  if not gBattle then
    return "none"
  end

  local ok, fight_st = pcall(function()
    local sGame = gBattle:get_field("Game"):get_data(nil)
    if not sGame then
      return nil
    end
    return sGame.fight_st
  end)

  if not ok or fight_st == nil then
    return "none"
  end

  if fight_st == 0 then
    return "none"
  end
  if fight_st == 7 then
    return "finished"
  end
  return "running"
end

local pending_state = nil
local pending_count = 0

re.on_frame(function()
  local state = read_fight_state()

  if state ~= pending_state then
    pending_state = state
    pending_count = 1
    return
  end

  pending_count = pending_count + 1
  if pending_count < STABLE_FRAMES then
    return
  end

  if state == last_state then
    return
  end

  local prev = last_state
  last_state = state

  if state == "running" and prev ~= "running" then
    write_status("match_start", "fight_st_running_from_" .. tostring(prev))
  elseif state == "finished" and prev == "running" then
    write_status("match_end", "fight_st_finished")
  elseif state == "none" and prev == "running" then
    -- Left battle without seeing finished (forfeit / disconnect / menu).
    write_status("match_end", "left_battle")
  end
end)

write_status("idle", "bridge_loaded")
log.info("[sf6_obs_bridge] loaded; writing to reframework/data/" .. STATUS_FILE)
