--[[
  bot_driver.lua -- deterministic scripted input for Rift Vector bot runs.

  Adapted from the shipped studio template (defold-studio templates/bot_driver.lua):
  preserves the Park-Miller minimal-standard generator, the control-character JSON
  quoter, the silent `sequence` anti-flooding helper and the `bot_input` telemetry
  schema on `next`. Pure Lua 5.1: zero module-level mutable state, no wall clock,
  no Defold engine API calls and no `math.random`.

  Contract
  --------
  local driver = require "bot_driver"
  local bot = driver.new({ seed = 20261117 })

  driver.next(bot) -> action, frame
      Advances one frame, emits exactly one line on the telemetry channel:
      `STUDIO_TELEMETRY {"event":"bot_input","frame":N,"action":"..."}`
      and returns `action, frame` (one-based).

  driver.sequence(bot, count) -> table
      Advances `count` frames along the identical seeded stream while emitting
      zero telemetry lines (anti-flooding contract).

  driver.reset(bot)
      Restores the bot to its initial seed and frame zero.

  driver.inject(bot, action, frames)
      Schedules `action` for `frames` frames ahead of the planned stream (used by
      the wrapper script if an initial `start` precedes title readiness).

  driver.scripted_done(bot) -> boolean
      True once the deterministic scripted showcase segment (start, movement and
      distinct vulcan taps, one >=1.80 s Tier-3 wave charge + release, Force
      launch and Force recall) has completed.

  driver.message(action) -> message_id, payload
      Maps an action token to the published `/game#controller` input message name
      and a fresh payload table, sharing the keyboard's exact command path.

  Telemetry discipline
  --------------------
  ONLY `bot_input` is ever emitted here. Audio events belong exclusively to the
  game's mixer (`audio.lua`), deftest summaries use the test runner channel, and
  bot diagnostics use `RIFT_BOT_DIAG` in `test/bot.script`.
]]

local M = {}

M.MULTIPLIER = 16807
M.MODULUS = 2147483647

local COMMANDS = {
  start = { "input_start", {} },
  stop = { "input_move", { dx = 0, dy = 0 } },
  move_up = { "input_move", { dx = 0, dy = 1 } },
  move_down = { "input_move", { dx = 0, dy = -1 } },
  move_left = { "input_move", { dx = -1, dy = 0 } },
  move_right = { "input_move", { dx = 1, dy = 0 } },
  move_up_right = { "input_move", { dx = 1, dy = 1 } },
  move_up_left = { "input_move", { dx = -1, dy = 1 } },
  move_down_right = { "input_move", { dx = 1, dy = -1 } },
  move_down_left = { "input_move", { dx = -1, dy = -1 } },
  fire_press = { "input_fire_press", {} },
  fire_release = { "input_fire_release", {} },
  force = { "input_force", {} },
}

M.ACTIONS = {
  "start",
  "stop",
  "move_up",
  "move_down",
  "move_left",
  "move_right",
  "move_up_right",
  "move_up_left",
  "move_down_right",
  "move_down_left",
  "fire_press",
  "fire_release",
  "force",
}

-- Balanced sweep pairs keep vertical excursion inside y=68..156 around start
-- y=112 so Lance sweeps enemy lanes without flying into y=24..40 / y=184..200 terrain.
local SWEEP_PAIRS = {
  { "move_up", "move_down" },
  { "move_down", "move_up" },
  { "move_up_right", "move_down_left" },
  { "move_down_right", "move_up_left" },
}

local JSON_SHORT_ESCAPES = {
  [8] = "\\b",
  [9] = "\\t",
  [10] = "\\n",
  [12] = "\\f",
  [13] = "\\r",
}

function M.quote(value)
  local text = tostring(value)
  local escaped = {}
  for index = 1, #text do
    local byte = string.byte(text, index)
    local short = JSON_SHORT_ESCAPES[byte]
    if short then
      escaped[index] = short
    elseif byte == 34 then
      escaped[index] = '\\"'
    elseif byte == 92 then
      escaped[index] = "\\\\"
    elseif byte < 32 then
      escaped[index] = string.format("\\u%04x", byte)
    else
      escaped[index] = string.char(byte)
    end
  end
  return '"' .. table.concat(escaped) .. '"'
end

local function emit(payload)
  print("STUDIO_TELEMETRY " .. payload)
end

local function seeded_state(seed)
  local folded = seed % (M.MODULUS - 1)
  if folded < 0 then
    folded = folded + (M.MODULUS - 1)
  end
  return folded + 1
end

local function draw(bot, count)
  bot.rng = (M.MULTIPLIER * bot.rng) % M.MODULUS
  return (bot.rng % count) + 1
end

function M.message(action)
  local entry = COMMANDS[action]
  if entry == nil then
    return nil
  end
  local payload = {}
  for key, value in pairs(entry[2]) do
    payload[key] = value
  end
  return entry[1], payload
end

local function add(plan, action, frames)
  plan[#plan + 1] = { action = action, frames = frames }
end

local function add_tap(plan, pause_frames)
  add(plan, "fire_press", 1)
  add(plan, "fire_release", pause_frames or 2)
end

local function add_balanced_sweep_with_taps(bot, plan)
  local pair = SWEEP_PAIRS[draw(bot, #SWEEP_PAIRS)]
  local span = 14 + draw(bot, 10) -- 15..24 frames (~20..32 px excursion at 80 px/s)
  add(plan, pair[1], span)
  add_tap(plan, 2)
  add(plan, "stop", 2)
  add_tap(plan, 2)
  add(plan, pair[2], span)
  add_tap(plan, 2)
  add(plan, "stop", 2)
end

-- Scripted play showcase (~560 frames / ~9.3 s):
--   1. Start from title into Stage 1 play.
--   2. Six seeded balanced vertical sweeps with distinct vulcan taps (covers the
--      first enemy formations entering from t=2.40 s onward).
--   3. One full >=1.80 s wave-cannon charge (116 hold frames = 1.93 s) while
--      performing a balanced safe sweep, then release for a Tier-3 wave beam.
--   4. Force launch edge, active sweep + taps, Force recall edge, settle + taps.
local function build_script(bot)
  local plan = {}
  add(plan, "start", 1)
  add(plan, "stop", 12)
  for _ = 1, 6 do
    add_balanced_sweep_with_taps(bot, plan)
  end
  -- Begin continuous fire hold (no fire_release for 116 frames = 1.93 s > 1.80 s)
  add(plan, "fire_press", 1)
  add(plan, "move_up", 24)
  add(plan, "stop", 34)
  add(plan, "move_down", 24)
  add(plan, "stop", 34)
  add(plan, "fire_release", 4)
  -- Exercise Force launch and recall edges
  add(plan, "force", 1)
  add_balanced_sweep_with_taps(bot, plan)
  add(plan, "force", 1)
  add_balanced_sweep_with_taps(bot, plan)
  add(plan, "stop", 6)
  return plan
end

local function build_free_play(bot)
  local plan = {}
  for _ = 1, 4 do
    add_balanced_sweep_with_taps(bot, plan)
  end
  -- Periodic Tier-1 wave shot (43 hold frames = 0.72 s >= 0.60 s) with zero net Y drift
  add(plan, "fire_press", 1)
  add(plan, "move_down", 18)
  add(plan, "stop", 6)
  add(plan, "move_up", 18)
  add(plan, "stop", 1)
  add(plan, "fire_release", 4)
  return plan
end

function M.new(config)
  local settings = config or {}
  local seed = settings.seed or 20261117
  assert(type(seed) == "number", "seed must be a number")
  local bot = {
    seed = seed,
    rng = seeded_state(seed),
    frame = 0,
    plan = nil,
    index = 1,
    remaining = 0,
    action = nil,
    scripted_entries = 0,
    injected = nil,
  }
  bot.plan = build_script(bot)
  bot.scripted_entries = #bot.plan
  return bot
end

local function step(bot)
  if bot.remaining == 0 then
    if bot.injected ~= nil then
      bot.action = bot.injected.action
      bot.remaining = bot.injected.frames
      bot.injected = nil
    else
      if bot.index > #bot.plan then
        local extra = build_free_play(bot)
        for i = 1, #extra do
          bot.plan[#bot.plan + 1] = extra[i]
        end
      end
      local entry = bot.plan[bot.index]
      bot.index = bot.index + 1
      bot.action = entry.action
      bot.remaining = entry.frames
    end
  end
  bot.remaining = bot.remaining - 1
  bot.frame = bot.frame + 1
  return bot.action, bot.frame
end

function M.next(bot)
  local action, frame = step(bot)
  emit(
    '{"event":"bot_input","frame":'
      .. string.format("%d", frame)
      .. ',"action":'
      .. M.quote(action)
      .. "}"
  )
  return action, frame
end

function M.sequence(bot, count)
  assert(type(count) == "number" and count >= 0, "count must be a non-negative number")
  local actions = {}
  for index = 1, count do
    actions[index] = step(bot)
  end
  return actions
end

function M.inject(bot, action, frames)
  assert(COMMANDS[action] ~= nil, "unknown bot action: " .. tostring(action))
  local n = frames or 1
  assert(type(n) == "number" and n >= 1, "frames must be at least 1")
  bot.injected = { action = action, frames = math.floor(n) }
end

function M.scripted_done(bot)
  if bot.injected ~= nil and bot.index <= bot.scripted_entries then
    return false
  end
  return bot.index > (bot.scripted_entries + 1)
    or (bot.index == (bot.scripted_entries + 1) and bot.remaining == 0)
end

function M.reset(bot)
  bot.rng = seeded_state(bot.seed)
  bot.frame = 0
  bot.remaining = 0
  bot.action = nil
  bot.index = 1
  bot.injected = nil
  bot.plan = build_script(bot)
  bot.scripted_entries = #bot.plan
end

return M
