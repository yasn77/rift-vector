--[[
  audio.lua -- SFX trigger gate, one-shot audio unlock and RMS telemetry.

  This file is a template for generated projects. It is pure Lua 5.1: it keeps
  no module-level mutable state, it never calls the Defold sound API, and it
  never sends or handles a `play_sound` message. Every mutable field lives in a
  state table the caller owns, so a unit test, a headless bot and the running
  game each drive their own copy without interfering.

  Contract
  --------
  local audio = dofile("audio.lua")            -- or require it as a module
  local state = audio.new({
      cooldown = 0.08,                         -- optional, seconds
      on_play = function(cue) end,             -- optional, called on a pass
      on_unlock = function() end,              -- optional, called once
  })

  audio.trigger(state, cue, now) -> boolean
      Returns true when the caller should play `cue` at time `now` and false
      when the same cue was already triggered inside the cooldown window.
      Suppression is per cue, so a footstep does not silence a jump. The caller
      plays the sound through its own sound component: the runtime decides how
      a cue reaches Defold, which is why this module sends no message.

  audio.unlock(state, now) -> boolean
      Performs the HTML5 WebAudio unlock exactly once. The first call returns
      true and fires `on_unlock`; every later call returns false and emits
      `audio_unlock_skipped`, so a burst of input handlers still opens the audio
      context only once. The unlock itself is injected through `on_unlock`
      because `html5.run` exists only in the HTML5 build: a shared Lua module
      that called it directly would break every desktop and mobile build.

  audio.record_rms(state, rms) -> number
      Stores the latest mixer RMS, clamped to 0..1, and raises the session peak.

  audio.report_rms(state, now) -> number
      Emits the RMS telemetry event and returns the stored RMS.

  audio.reset(state, now)
      Clears the cooldown table, the unlock flag and the RMS meters. The
      configured cooldown and the callbacks are kept.

  Telemetry
  ---------
  Each observable event is one line of the form
  `STUDIO_TELEMETRY {"event":"...", ...}` holding a valid JSON object. Fractional
  values such as `at`, `window`, `rms` and `peak_rms` use six decimal places,
  integer counters such as `calls` are written as plain integers, and strings are
  JSON-escaped, control characters included. Events: audio_play,
  audio_cooldown_suppressed, audio_unlock, audio_unlock_skipped, audio_rms and
  audio_reset. The bots and the headless harness parse these lines; a shipped
  game ignores them.
]]

local M = {}

--: Cooldown used when the caller configures none, in seconds.
M.DEFAULT_COOLDOWN = 0.08

--: Short JSON escapes for the five control characters that have one.
local JSON_SHORT_ESCAPES = {
  [8] = "\\b",
  [9] = "\\t",
  [10] = "\\n",
  [12] = "\\f",
  [13] = "\\r",
}

local function quote(value)
  local escaped = {}
  for index = 1, #value do
    local byte = string.byte(value, index)
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

local function fixed(value)
  return string.format("%.6f", value)
end

local function emit(payload)
  print("STUDIO_TELEMETRY " .. payload)
end

--- Return a fresh state table for one audio owner.
function M.new(config)
  local settings = config or {}
  return {
    cooldown = settings.cooldown or M.DEFAULT_COOLDOWN,
    last_trigger = {},
    unlocked = false,
    unlock_calls = 0,
    rms = 0,
    peak_rms = 0,
    on_play = settings.on_play,
    on_unlock = settings.on_unlock,
  }
end

--- Return true when `cue` may play at `now`, false inside its cooldown.
function M.trigger(state, cue, now)
  assert(type(cue) == "string" and cue ~= "", "cue must be a non-empty string")
  assert(type(now) == "number", "now must be a number")

  local previous = state.last_trigger[cue]
  if previous ~= nil and (now - previous) < state.cooldown then
    emit(
      '{"event":"audio_cooldown_suppressed","cue":'
        .. quote(cue)
        .. ',"at":'
        .. fixed(now)
        .. ',"window":'
        .. fixed(state.cooldown)
        .. "}"
    )
    return false
  end

  state.last_trigger[cue] = now
  emit('{"event":"audio_play","cue":' .. quote(cue) .. ',"at":' .. fixed(now) .. "}")
  if state.on_play then
    state.on_play(cue)
  end
  return true
end

--- Perform the audio unlock once; return false on every later call.
function M.unlock(state, now)
  assert(type(now) == "number", "now must be a number")

  if state.unlocked then
    emit('{"event":"audio_unlock_skipped","at":' .. fixed(now) .. "}")
    return false
  end

  state.unlocked = true
  state.unlock_calls = state.unlock_calls + 1
  emit('{"event":"audio_unlock","at":' .. fixed(now) .. ',"calls":1}')
  if state.on_unlock then
    state.on_unlock()
  end
  return true
end

--- Store the latest mixer RMS, clamped to 0..1, and raise the session peak.
function M.record_rms(state, rms)
  assert(type(rms) == "number", "rms must be a number")

  local clamped = rms
  if clamped < 0 then
    clamped = 0
  end
  if clamped > 1 then
    clamped = 1
  end

  state.rms = clamped
  if clamped > state.peak_rms then
    state.peak_rms = clamped
  end
  return clamped
end

--- Emit the RMS telemetry event and return the stored RMS.
function M.report_rms(state, now)
  assert(type(now) == "number", "now must be a number")

  emit(
    '{"event":"audio_rms","at":'
      .. fixed(now)
      .. ',"rms":'
      .. fixed(state.rms)
      .. ',"peak_rms":'
      .. fixed(state.peak_rms)
      .. "}"
  )
  return state.rms
end

--- Clear cooldowns, the unlock flag and the meters, keeping the configuration.
function M.reset(state, now)
  assert(type(now) == "number", "now must be a number")

  state.last_trigger = {}
  state.unlocked = false
  state.unlock_calls = 0
  state.rms = 0
  state.peak_rms = 0
  emit('{"event":"audio_reset","at":' .. fixed(now) .. "}")
end

return M
