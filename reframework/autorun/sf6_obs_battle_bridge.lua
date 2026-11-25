--[[
  sf6_obs_battle_bridge.lua
  REFramework autorun script for Street Fighter 6.

  Detects live battle start/end via gBattle + fight_st and writes a status
  file that the OBS SF6 Replay Namer script polls:

    %AppData%\sf6-clip-namer\battle_status.json

  Install:
    1. Install REFramework (SF6.zip) into the Street Fighter 6 folder
    2. Copy this file to:
         <SF6>\reframework\autorun\sf6_obs_battle_bridge.lua
    3. Launch SF6 once so the reframework folders are created

  fight_st notes (from community tooling):
    0 = idle / not fighting
    7 = fight finished
    other non-zero = fight running
]]

local APP_DIR = (os.getenv("APPDATA") or "") .. "\\sf6-clip-namer"
local STATUS_PATH = APP_DIR .. "\\battle_status.json"

local last_state = "none" -- none | running | finished
local seq = 0
local frames_in_state = 0
-- Require a few frames stable before emitting, to avoid flicker.
local STABLE_FRAMES = 8

local function ensure_dir()
  -- REFramework may not have lfs; best-effort mkdir via echo is avoided.
  -- OBS side also ensures the AppData folder exists.
  pcall(function()
    local f = io.open(APP_DIR .. "\\.keep", "a")
    if f then
      f:close()
    end
  end)
end

local function write_status(state, reason)
  seq = seq + 1
  local payload = string.format(
    [[{
  "state": "%s",
  "seq": %d,
  "t": %d,
  "reason": "%s",
  "source": "reframework"
}]],
    state,
    seq,
    os.time(),
    reason or ""
  )
  ensure_dir()
  local ok, err = pcall(function()
    local f = assert(io.open(STATUS_PATH, "w"))
    f:write(payload)
    f:close()
  end)
  if ok then
    log.info(string.format("[sf6_obs_bridge] %s seq=%d (%s)", state, seq, tostring(reason)))
  else
    log.info("[sf6_obs_bridge] write failed: " .. tostring(err))
    -- Fallback: also dump into reframework/data for debugging.
    pcall(function()
      json.dump_file("sf6_obs_battle_status.json", {
        state = state,
        seq = seq,
        t = os.time(),
        reason = reason,
        source = "reframework",
        write_error = tostring(err),
      })
    end)
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
    frames_in_state = frames_in_state + 1
    return
  end

  local prev = last_state
  last_state = state
  frames_in_state = 0

  if state == "running" and prev ~= "running" then
    write_status("match_start", "fight_st_running_from_" .. tostring(prev))
  elseif state == "finished" and prev == "running" then
    write_status("match_end", "fight_st_finished")
  elseif state == "none" and prev == "running" then
    -- Left battle without seeing finished (forfeit / disconnect / menu).
    write_status("match_end", "left_battle")
  end
end)

-- Announce script load so Script Log / REFramework console shows it.
write_status("idle", "bridge_loaded")
log.info("[sf6_obs_bridge] loaded; writing to " .. STATUS_PATH)
