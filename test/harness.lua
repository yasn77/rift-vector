-- test/harness.lua -- shared blind QA harness for Rift Vector.
--
-- Blind to main/*.lua and src/**: every interaction uses the 22 published
-- messages and the test_spawn_report schema from design/design.md section 4.
-- Strict Lua 5.1 (PUC Lua 5.1.4 + LuaJIT compatible).

local telescope = require "deftest.telescope"
local G = require "test.gdd_data"

telescope.make_assertion(
  "contract",
  function(_, _, detail)
    return "Contract failed: " .. tostring(detail or "missing observable behaviour")
  end,
  function(condition)
    return condition == true
  end
)

local H = {}
H.G = G
H.RUN_ID = "rift-qa"
H.SAVE_APP = "rift-vector"
H.SEEDED_HI = 350
H.SAVE_CANDIDATES = {
  "hi_score",
  "high_score",
  "save",
  "hiscore",
  "scores",
  "rift-vector",
  "rift_vector",
  "game",
  "data",
  "state",
  "profile",
  "savefile",
  "main",
  "hi_score.dat",
  "high_score.dat",
  "save.dat",
  "hiscore.dat",
  "hi_score.sav",
  "save.sav",
}

local MESSAGE_BY_HEX = {}
for i = 1, #G.MESSAGE_IDS do
  local name = G.MESSAGE_IDS[i]
  MESSAGE_BY_HEX[hash_to_hex(hash(name))] = name
end

local state = {
  frame = 0,
  sim_tick = 0,
  events = {},
  inbox = {},
  waiting = nil,
  ctrl_url = nil,
  controller_alive = false,
  probed_once = false,
  saw_title = false,
  last_report = nil,
  active_assert = nil,
  uid = 0,
}
H.state = state

---------------------------------------------------------------------------
-- Assertions and timing helpers
---------------------------------------------------------------------------

function H.use_assert(fn)
  state.active_assert = fn
end

function H.check(condition, reason)
  local ok = (condition == true)
  if state.active_assert ~= nil then
    state.active_assert(ok, reason)
    return
  end
  if not ok then
    error({ "Contract failed: " .. tostring(reason), debug.traceback() }, 0)
  end
end

function H.fail(reason)
  H.check(false, reason)
end

function H.secs(seconds)
  return math.floor(seconds * 60 + 0.5)
end

function H.near(actual, expected, tolerance)
  return type(actual) == "number" and math.abs(actual - expected) <= tolerance
end

function H.fmt(value)
  if type(value) == "number" then
    return string.format("%.2f", value)
  end
  return tostring(value)
end

function H.uid(prefix)
  state.uid = state.uid + 1
  return (prefix or "qa") .. "-" .. tostring(state.uid)
end

---------------------------------------------------------------------------
-- Controller URL resolution (/game/game#controller under test.collection)
---------------------------------------------------------------------------

function H.controller_url()
  if state.ctrl_url ~= nil then
    return state.ctrl_url
  end
  local composed = msg.url("/game/game#controller")
  local direct = msg.url("/game#controller")
  local ok_comp, has_comp = pcall(go.exists, "/game/game")
  if ok_comp and has_comp then
    state.ctrl_url = composed
    return composed
  end
  local ok_dir, has_dir = pcall(go.exists, "/game")
  if ok_dir and has_dir then
    state.ctrl_url = direct
    return direct
  end
  return composed
end

function H.post(message_id, payload)
  msg.post(H.controller_url(), message_id, payload or {})
end

---------------------------------------------------------------------------
-- Coroutine / message dispatch (wired from test/runner.script)
---------------------------------------------------------------------------

local function resume_waiter(waiter, value)
  local ok, err = coroutine.resume(waiter.co, value)
  if not ok then
    print("QA_HARNESS_ERR " .. tostring(err))
    os.exit(1)
  end
end

function H.saw_title_screen()
  return state.saw_title
end

function H.on_message(message_id, message)
  local name = MESSAGE_BY_HEX[hash_to_hex(message_id)]
  if name == nil then
    return
  end
  state.controller_alive = true
  if name == "screen_changed" and message and message.screen == "title" then
    state.saw_title = true
  end

  if name == "test_spawn_report" then
    state.last_report = message
    if message and message.screen == "title" then
      state.saw_title = true
    end
    local waiter = state.waiting
    if waiter ~= nil and waiter.kind == "report" then
      state.waiting = nil
      resume_waiter(waiter, message)
    else
      state.inbox[#state.inbox + 1] = message
    end
  else
    state.events[#state.events + 1] = {
      name = name,
      msg = message or {},
      tick = state.sim_tick,
      frame = state.frame,
    }
  end
end

function H.on_update()
  state.frame = state.frame + 1
  local waiter = state.waiting
  if waiter ~= nil and state.frame >= waiter.deadline then
    state.waiting = nil
    if waiter.kind == "sleep" then
      resume_waiter(waiter, true)
    else
      resume_waiter(waiter, nil)
    end
  end
end

function H.sleep_frames(frames)
  local n = math.max(1, math.floor(frames or 1))
  state.waiting = {
    co = coroutine.running(),
    kind = "sleep",
    deadline = state.frame + n,
  }
  return coroutine.yield()
end

local function default_timeout_frames()
  if state.controller_alive then
    return 60
  end
  if not state.probed_once then
    state.probed_once = true
    return 6
  end
  return 2
end

function H.try_advance(ticks, timeout_frames)
  local n = math.max(0, math.floor(ticks or 1))
  state.inbox = {}
  local budget = timeout_frames or default_timeout_frames()
  state.waiting = {
    co = coroutine.running(),
    kind = "report",
    deadline = state.frame + budget,
  }
  H.post("test_advance", { ticks = n })
  local report = coroutine.yield()
  if report ~= nil then
    state.sim_tick = state.sim_tick + n
  end
  return report
end

function H.advance(ticks, context_note)
  local n = math.max(0, math.floor(ticks or 1))
  local report = H.try_advance(n)
  local suffix = context_note and (" [" .. context_note .. "]") or ""
  H.check(
    report ~= nil,
    "expected /game/game#controller to reply to test_advance{ticks="
      .. tostring(n)
      .. "} with test_spawn_report (design section 4, test_advance), got no reply"
      .. suffix
  )
  return report
end

function H.advance_until(predicate, max_ticks, step_ticks, context_note)
  local step = step_ticks or 6
  local elapsed = 0
  local report = state.last_report
  while elapsed < max_ticks do
    local chunk = math.min(step, max_ticks - elapsed)
    report = H.advance(chunk, context_note)
    elapsed = elapsed + chunk
    if predicate(report, elapsed) then
      return report, elapsed
    end
  end
  return nil, elapsed
end

---------------------------------------------------------------------------
-- Session lifecycle (strictly design-documented messages only)
---------------------------------------------------------------------------

function H.clear_events()
  state.events = {}
end

function H.mark_events()
  return #state.events
end

function H.events_since(mark, filter_name)
  local out = {}
  for i = (mark or 0) + 1, #state.events do
    local entry = state.events[i]
    if filter_name == nil or entry.name == filter_name then
      out[#out + 1] = entry
    end
  end
  return out
end

function H.has_cue_since(mark, cue_id)
  local events = H.events_since(mark, "audio_request")
  for i = 1, #events do
    if events[i].msg and events[i].msg.cue_id == cue_id then
      return true
    end
  end
  return false
end

function H.count_cue_since(mark, cue_id)
  local count = 0
  local events = H.events_since(mark, "audio_request")
  for i = 1, #events do
    if events[i].msg and events[i].msg.cue_id == cue_id then
      count = count + 1
    end
  end
  return count
end

-- Put the controller into deterministic test_mode on the title screen before input_start.
function H.reset_to_title(context_note)
  state.inbox = {}
  state.events = {}
  state.sim_tick = 0
  state.last_lives = nil
  if state.controller_alive then
    H.post("test_mode", { enabled = false })
  end
  H.post("test_mode", { enabled = true })
  if state.controller_alive then
    H.sleep_frames(1)
    state.inbox = {}
  end
  local report = H.try_advance(1)
  local suffix = context_note and (" [" .. context_note .. "]") or ""
  H.check(
    report ~= nil,
    "expected /game/game#controller to answer test_mode{enabled=true} + test_advance{ticks=1} with test_spawn_report"
      .. suffix
  )
  -- Ensure any pending fire hold or movement from a prior test is cleared.
  H.post("input_fire_release", {})
  H.post("input_move", { dx = 0, dy = 0 })
  if report.screen == "pause" then
    H.post("input_pause", {})
    report = H.advance(1, context_note)
  end
  if report.screen == "victory" then
    H.post("input_start", {})
    report = H.advance(1, context_note)
  end
  if report.screen ~= "title" then
    -- Re-post test_mode false->true edge and, if needed, walk Stage 10 victory -> title.
    H.post("test_mode", { enabled = false })
    H.post("test_mode", { enabled = true })
    H.sleep_frames(1)
    state.inbox = {}
    report = H.advance(1, context_note)
    if report.screen == "game_over" or report.screen == "stage_clear" then
      H.post("input_start", {})
      report = H.advance(1, context_note)
    end
    if report.screen == "play" then
      H.post("test_set_stage", { stage = 10 })
      H.post("boss_defeated", { stage = 10 })
      report = H.advance(2, context_note)
      if report.screen == "victory" then
        H.post("input_start", {})
        report = H.advance(2, context_note)
      end
    end
  end
  H.check(
    report.screen == "title",
    "test_mode{enabled=true} before input_start must place controller on 'title' screen, got '"
      .. tostring(report.screen)
      .. "'"
      .. suffix
  )
  return report
end

function H.set_stage(stage, context_note)
  H.post("test_set_stage", { stage = stage })
  if state.controller_alive then
    H.sleep_frames(1)
    state.inbox = {}
  end
  local report = H.advance(1, context_note)
  H.check(
    H.near(report.scroll_px, 0, 1.0),
    "test_set_stage{stage=" .. tostring(stage) .. "} must load stage at scroll_px=0, got " .. H.fmt(report.scroll_px)
  )
  return report
end

-- Enter deterministic test mode, press input_start to begin a fresh run, and
-- optionally jump to `stage` via test_set_stage.
function H.start_play(stage, context_note)
  H.reset_to_title(context_note)
  local mark = H.mark_events()
  H.post("input_start", {})
  local report = H.advance(1, context_note)
  H.check(
    report.screen == "play",
    "input_start from 'title' must enter 'play' screen (atomic requirement 28), got '"
      .. tostring(report.screen)
      .. "'"
  )
  if stage ~= nil then
    report = H.set_stage(stage, context_note)
  end
  return report, mark
end

-- Advance exact `total_ticks` while actively piloting Lance inside the central
-- clear passage (y in [88, 136], net_y_ticks bounded in [-18, 18] at 80 px/s)
-- to dodge incoming formations reported in `test_spawn_report.enemies` and weave
-- away from locked-direction aimed volleys, returning Lance to exact y=112.
function H.pilot_ticks(total_ticks, opts, context_note)
  local options = opts or {}
  local do_shoot = (options.shoot == true)
  local remaining = math.max(0, math.floor(total_ticks or 0))
  if remaining == 0 then
    return H.advance(0, context_note)
  end

  local net_y_ticks = 0
  local weave_dir = 1
  local report = state.last_report

  while remaining > 0 do
    -- Reserve enough final ticks to restore net_y_ticks cleanly back to 0 (y=112).
    if remaining <= math.abs(net_y_ticks) + 2 and net_y_ticks ~= 0 then
      local back_dir = net_y_ticks > 0 and -1 or 1
      local back_ticks = math.min(remaining, math.abs(net_y_ticks))
      H.post("input_move", { dx = 0, dy = back_dir })
      report = H.advance(back_ticks, context_note)
      net_y_ticks = net_y_ticks + back_dir * back_ticks
      remaining = remaining - back_ticks
      H.post("input_move", { dx = 0, dy = 0 })
      if remaining > 0 then
        report = H.advance(remaining, context_note)
        remaining = 0
      end
      break
    end

    local est_y = 112 + net_y_ticks * (80.0 / 60.0)
    local chosen_dy = weave_dir
    if report and report.enemies then
      local threat_above = 0
      local threat_below = 0
      for i = 1, #report.enemies do
        local e = report.enemies[i]
        if type(e.x) == "number" and type(e.y) == "number" and e.x >= 44 and e.x <= 220 then
          if math.abs(e.y - est_y) <= 28 then
            if e.y >= est_y then
              threat_above = threat_above + 1
            else
              threat_below = threat_below + 1
            end
          end
        end
      end
      if threat_above > threat_below then
        chosen_dy = -1
      elseif threat_below > threat_above then
        chosen_dy = 1
      end
    end

    if net_y_ticks >= 16 and chosen_dy > 0 then
      chosen_dy = -1
    elseif net_y_ticks <= -16 and chosen_dy < 0 then
      chosen_dy = 1
    end
    weave_dir = -weave_dir

    local step = math.min(6, remaining)
    if do_shoot and step >= 3 then
      H.post("input_move", { dx = 0, dy = chosen_dy })
      H.post("input_fire_press", {})
      H.advance(1, context_note)
      H.post("input_fire_release", {})
      report = H.advance(step - 1, context_note)
    else
      H.post("input_move", { dx = 0, dy = chosen_dy })
      report = H.advance(step, context_note)
    end
    if report and report.lives and state.last_lives and report.lives < state.last_lives then
      net_y_ticks = 0
    else
      net_y_ticks = net_y_ticks + chosen_dy * step
    end
    state.last_lives = report and report.lives or nil
    remaining = remaining - step
  end

  H.post("input_move", { dx = 0, dy = 0 })
  return report
end

H.weave_advance = function(total_ticks, context_note)
  return H.pilot_ticks(total_ticks, { shoot = false }, context_note)
end

-- Pilot a stage from current scroll_px until boss scroll lock (scroll_px >= 1920
-- and report.boss ~= nil). Ceases firing during the final `quiet_tail_s` seconds
-- before 1920 px so zero in-flight player shots strike the boss before initial
-- HP assertions run.
function H.pilot_to_boss(opts, context_note)
  local options = opts or {}
  local do_shoot = (options.shoot ~= false)
  local allow_continue = (options.allow_continue == true)
  local quiet_px = 1920.0 - 24.0 * (options.quiet_tail_s or 2.0)
  local max_ticks = options.max_ticks or H.secs(220.0)
  local spent = 0
  local report = H.advance(1, context_note)

  while spent < max_ticks do
    if report.boss ~= nil and report.scroll_px >= 1918.0 then
      H.post("input_move", { dx = 0, dy = 0 })
      return report
    end
    if report.screen == "game_over" then
      if allow_continue then
        H.post("input_start", {})
        report = H.advance(2, context_note)
        spent = spent + 2
      else
        break
      end
    else
      local can_shoot = do_shoot and ((report.scroll_px or 0) < quiet_px)
      report = H.pilot_ticks(24, { shoot = can_shoot }, context_note)
      spent = spent + 24
    end
  end
  H.post("input_move", { dx = 0, dy = 0 })
  return report
end

-- Full-playfield vertical vulcan scan across y in [56, 168] (+/-42 ticks at 80 px/s)
-- firing one distinct vulcan tap every 5 ticks (~6.7 px vertical spacing) so ceiling,
-- floor and central boss cores (including Stage 8 Hatch Warden) are guaranteed hit.
function H.full_vertical_sweep(ticks_budget, context_note)
  local legs = {
    { dy = 1, ticks = 42 },
    { dy = -1, ticks = 84 },
    { dy = 1, ticks = 42 },
  }
  local spent = 0
  local leg_idx = 1
  local leg_rem = legs[1].ticks
  local report = state.last_report

  while spent < ticks_budget do
    local leg = legs[leg_idx]
    local chunk = math.min(5, leg_rem, ticks_budget - spent)
    H.post("input_move", { dx = 0, dy = leg.dy })
    if chunk >= 2 then
      H.post("input_fire_press", {})
      H.advance(1, context_note)
      H.post("input_fire_release", {})
      report = H.advance(chunk - 1, context_note)
    else
      report = H.advance(chunk, context_note)
    end
    spent = spent + chunk
    leg_rem = leg_rem - chunk
    if leg_rem <= 0 then
      leg_idx = (leg_idx % #legs) + 1
      leg_rem = legs[leg_idx].ticks
    end
  end
  H.post("input_move", { dx = 0, dy = 0 })
  return H.advance(1, context_note)
end

-- Fight the active boss across full vertical lanes until boss_defeated / stage_clear / victory.
-- Automatically pilots back from the 1152 px checkpoint if an unshielded death occurs mid-fight.
function H.defeat_active_boss(opts, context_note)
  local options = opts or {}
  local max_ticks = H.secs(options.max_seconds or 70.0)
  local allow_continue = (options.allow_continue == true)
  local re_equip = options.re_equip_red_l3 == true
  local mark = H.mark_events()
  local spent = 0
  local sweep_leg_rem = 36
  local sweep_dir = 1
  local report = H.advance(1, context_note)

  while spent < max_ticks do
    if report.screen == "stage_clear" or report.screen == "victory" then
      H.post("input_move", { dx = 0, dy = 0 })
      return report
    end
    if #H.events_since(mark, "boss_defeated") >= 1 then
      H.post("input_move", { dx = 0, dy = 0 })
      return H.advance(4, context_note)
    end
    if report.screen == "game_over" then
      if not allow_continue then
        break
      end
      H.post("input_start", {})
      report = H.advance(2, context_note)
      spent = spent + 2
      if re_equip then
        H.collect_powerup("red", nil, context_note)
        H.collect_powerup("red", nil, context_note)
        H.collect_powerup("red", nil, context_note)
      end
    elseif report.screen == "play" and report.boss == nil and (report.scroll_px or 0) < 1918.0 then
      -- Respawned at 1152 px checkpoint after losing a life; pilot back to boss lock!
      if re_equip then
        H.collect_powerup("red", nil, context_note)
        H.collect_powerup("red", nil, context_note)
        H.collect_powerup("red", nil, context_note)
      end
      report = H.pilot_to_boss({ shoot = true, allow_continue = allow_continue, quiet_tail_s = 0.5 }, context_note)
      spent = spent + H.secs(33.0)
      sweep_dir = 1
      sweep_leg_rem = 36
    else
      local step = 5
      H.post("input_move", { dx = 0, dy = sweep_dir })
      if report.boss and report.boss.exposed then
        H.post("input_fire_press", {})
        H.advance(1, context_note)
        H.post("input_fire_release", {})
        report = H.advance(step - 1, context_note)
      else
        -- Still fire occasional taps to clear Bellmite shell cells / Dop clones
        H.post("input_fire_press", {})
        H.advance(1, context_note)
        H.post("input_fire_release", {})
        report = H.advance(step - 1, context_note)
      end
      spent = spent + step
      sweep_leg_rem = sweep_leg_rem - step
      if sweep_leg_rem <= 0 then
        sweep_dir = -sweep_dir
        sweep_leg_rem = 72
      end
    end
  end
  H.post("input_move", { dx = 0, dy = 0 })
  return H.advance(2, context_note)
end

---------------------------------------------------------------------------
-- Pure-message gameplay helpers
---------------------------------------------------------------------------

function H.move_for(dx, dy, ticks, context_note)
  H.post("input_move", { dx = dx, dy = dy })
  local report = H.advance(ticks, context_note)
  H.post("input_move", { dx = 0, dy = 0 })
  return H.advance(1, context_note)
end

function H.tap_fire(settle_ticks, context_note)
  H.post("input_fire_press", {})
  H.advance(1, context_note)
  H.post("input_fire_release", {})
  return H.advance(settle_ticks or 1, context_note)
end

function H.hold_and_release_fire(hold_ticks, post_release_ticks, context_note)
  H.post("input_fire_press", {})
  local mid_report = H.advance(hold_ticks, context_note)
  H.post("input_fire_release", {})
  local after_report = H.advance(post_release_ticks or 1, context_note)
  return after_report, mid_report
end

function H.collect_powerup(kind, spawn_id, context_note)
  H.post("powerup_collected", {
    kind = kind,
    spawn_id = spawn_id or H.uid("pickup-" .. tostring(kind)),
  })
  return H.advance(1, context_note)
end

-- Measure Lance's horizontal position indirectly via Force launch duration:
-- When ship.x < 160 and Force is attached_front (pod.x = ship.x + 24),
-- input_force launches linearly at 200 px/s to x=264:
--   ticks = (264 - (ship.x + 24)) / 200 * 60  =>  ship.x = 240 - ticks * (200 / 60)
function H.measure_launch_ticks_from_front(max_ticks, context_note)
  local r0 = H.advance(1, context_note)
  if not r0.force or r0.force.level == 0 then
    r0 = H.collect_powerup("red", nil, context_note)
  end
  H.check(
    r0.force ~= nil and r0.force.state == "attached_front",
    "expected Force in state 'attached_front' before launch measurement, got '"
      .. tostring(r0.force and r0.force.state)
      .. "'"
  )
  H.post("input_force", {})
  local ticks = 0
  local limit = max_ticks or 120
  while ticks < limit do
    local r = H.advance(1, context_note)
    ticks = ticks + 1
    if r.force and r.force.state == "detached" then
      return ticks, r
    end
  end
  H.fail("Force did not reach 'detached' state within " .. tostring(limit) .. " ticks after input_force")
  return ticks, nil
end

function H.find_enemies(report, kind)
  local out = {}
  local list = (report and report.enemies) or {}
  for i = 1, #list do
    if kind == nil or list[i].kind == kind then
      out[#out + 1] = list[i]
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Resource, file and save-directory helpers
---------------------------------------------------------------------------

function H.read_project_file(path)
  local rel = string.gsub(path, "^/", "")
  local f = io.open(rel, "rb")
  if f == nil then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local WALKABLE_SCENE_EXTS = {
  collection = true,
  go = true,
  factory = true,
  collectionfactory = true,
  sprite = true,
  tilemap = true,
  gui = true,
  model = true,
}

-- Walk Defold scene descriptors from `root_path` without ever reading *.lua or *.script.
-- Matches resource paths regardless of nested Protobuf Text backslash-quote escaping.
function H.collect_scene_files(root_path)
  local start = string.sub(root_path, 1, 1) == "/" and root_path or ("/" .. root_path)
  local queue = { start }
  local visited = {}
  local blobs = {}
  local by_ext = {}

  while #queue > 0 do
    local current = table.remove(queue, 1)
    if not visited[current] then
      visited[current] = true
      local text = H.read_project_file(current)
      if text then
        blobs[#blobs + 1] = text
        local ext = string.match(current, "%.([A-Za-z0-9_]+)$")
        if ext then
          by_ext[ext] = by_ext[ext] or {}
          by_ext[ext][#by_ext[ext] + 1] = text
        end
        for ref_path, ref_ext in string.gmatch(text, "(/[A-Za-z0-9_%-%./]+%.([A-Za-z0-9_]+))") do
          if WALKABLE_SCENE_EXTS[ref_ext] and not visited[ref_path] then
            queue[#queue + 1] = ref_path
          end
        end
      end
    end
  end

  return {
    all_text = table.concat(blobs, "\n"),
    by_ext = by_ext,
  }
end

function H.count_plain(haystack, needle)
  if type(haystack) ~= "string" or type(needle) ~= "string" or needle == "" then
    return 0
  end
  local total = 0
  local cursor = 1
  while true do
    local s, e = string.find(haystack, needle, cursor, true)
    if s == nil then
      return total
    end
    total = total + 1
    cursor = e + 1
  end
end

local function list_save_dir_paths()
  local paths = {}
  local seen = {}
  for i = 1, #H.SAVE_CANDIDATES do
    local ok, p = pcall(sys.get_save_file, H.SAVE_APP, H.SAVE_CANDIDATES[i])
    if ok and type(p) == "string" and not seen[p] then
      seen[p] = true
      paths[#paths + 1] = p
    end
  end
  if io and io.popen and #paths > 0 then
    local dir = string.match(paths[1], "^(.*)[/\\][^/\\]+$")
    if dir and not string.find(dir, '"', 1, true) then
      local ok_p, pipe = pcall(io.popen, 'ls -1 "' .. dir .. '" 2>/dev/null')
      if ok_p and pipe then
        for entry in pipe:lines() do
          if entry ~= "" and entry ~= "." and entry ~= ".." then
            local ok_f, full = pcall(sys.get_save_file, H.SAVE_APP, entry)
            if ok_f and type(full) == "string" and not seen[full] then
              seen[full] = true
              paths[#paths + 1] = full
            end
          end
        end
        pipe:close()
      end
    end
  end
  return paths
end

function H.seed_saves(score_value)
  local val = score_value or H.SEEDED_HI
  local paths = list_save_dir_paths()
  for i = 1, #paths do
    pcall(sys.save, paths[i], { hi_score = val })
  end
end

function H.read_saved_hi_score()
  local best = nil
  local best_path = nil
  local paths = list_save_dir_paths()
  for i = 1, #paths do
    local ok, tbl = pcall(sys.load, paths[i])
    if ok and type(tbl) == "table" and type(tbl.hi_score) == "number" then
      if best == nil or tbl.hi_score > best then
        best = tbl.hi_score
        best_path = paths[i]
      end
    end
  end
  return best, best_path
end

function H.write_all_saves_raw(raw_bytes)
  local paths = list_save_dir_paths()
  for i = 1, #paths do
    local f = io.open(paths[i], "wb")
    if f then
      f:write(raw_bytes)
      f:close()
    end
  end
end

function H.write_all_saves_table(tbl)
  local paths = list_save_dir_paths()
  for i = 1, #paths do
    pcall(sys.save, paths[i], tbl)
  end
end

-- Seed baseline hi-score as early as module load if sys is already bound.
pcall(H.seed_saves, H.SEEDED_HI)

return H
