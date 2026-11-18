-- main/mixer.lua -- Audio mixer policy wrapping main/audio.lua for Rift Vector.
-- Enforces 0.06 s per-cue cooldown, bgm/sfx/ui group gains (0.45/0.80/0.80),
-- pause BGM ducking (0.15), 8-voice SFX cap with death/alert priority over shot,
-- charge_rise cancellation, native vs web real-gesture unlock, and RMS telemetry.
-- Strict Lua 5.1, British English.

local audio = require "main.audio"
local C = require "main.constants"

local M = {}

M.GAIN_BGM = 0.45
M.GAIN_BGM_DUCK = 0.15
M.GAIN_SFX = 0.80
M.GAIN_UI = 0.80
M.MAX_SFX_VOICES = 8

local CUE_META = {
  shot = { kind = "sfx", dur = 0.14, prio = 1 },
  enemy_hit = { kind = "sfx", dur = 0.09, prio = 1 },
  wave_fire = { kind = "sfx", dur = 0.65, prio = 2 },
  charge_rise = { kind = "sfx", dur = 1.65, prio = 2 },
  explosion_small = { kind = "sfx", dur = 0.50, prio = 2 },
  pickup_crystal = { kind = "sfx", dur = 0.70, prio = 2 },
  pickup_power = { kind = "sfx", dur = 0.35, prio = 2 },
  force_attach = { kind = "sfx", dur = 0.25, prio = 2 },
  force_launch = { kind = "sfx", dur = 0.25, prio = 2 },
  explosion_big = { kind = "sfx", dur = 1.65, prio = 3 },
  boss_alert = { kind = "sfx", dur = 1.00, prio = 3 },
  player_die = { kind = "sfx", dur = 2.10, prio = 3 },
  ui_select = { kind = "ui", dur = 0.18, prio = 2 },
  jingle_stage_clear = { kind = "jingle", dur = 4.00, prio = 3 },
  jingle_game_over = { kind = "jingle", dur = 5.34, prio = 3 },
  jingle_victory = { kind = "jingle", dur = 8.73, prio = 3 },
  bgm_title = { kind = "bgm", dur = 0, prio = 3 },
  bgm_stage_a = { kind = "bgm", dur = 0, prio = 3 },
  bgm_stage_b = { kind = "bgm", dur = 0, prio = 3 },
  bgm_stage_c = { kind = "bgm", dur = 0, prio = 3 },
  bgm_boss = { kind = "bgm", dur = 0, prio = 3 },
  bgm_final_boss = { kind = "bgm", dur = 0, prio = 3 },
}

local ALL_BGMS = {
  "bgm_title",
  "bgm_stage_a",
  "bgm_stage_b",
  "bgm_stage_c",
  "bgm_boss",
  "bgm_final_boss",
}

local ALL_JINGLES = {
  "jingle_stage_clear",
  "jingle_game_over",
  "jingle_victory",
}

local WEB_UNLOCK_JS = table.concat({
  "try{",
  "var ctx=(typeof Module!=='undefined'&&Module.SDL2&&Module.SDL2.audioContext)",
  "||(typeof DM Sound!=='undefined'&&DMSound.context)||null;",
  "if(ctx&&ctx.state==='suspended'){ctx.resume();}",
  "}catch(e){}",
})

local function safe_sound_play(url)
  local ok, play_id = pcall(sound.play, url)
  if ok then
    return play_id
  end
  return nil
end

local function safe_sound_stop(url, props)
  if props then
    pcall(sound.stop, url, props)
  else
    pcall(sound.stop, url)
  end
end

local function apply_group_gains(paused)
  pcall(sound.set_group_gain, C.GROUP_BGM, paused and M.GAIN_BGM_DUCK or M.GAIN_BGM)
  pcall(sound.set_group_gain, C.GROUP_SFX, M.GAIN_SFX)
  pcall(sound.set_group_gain, C.GROUP_UI, M.GAIN_UI)
end

local function prune_sfx_voices(state, now)
  local kept = {}
  for i = 1, #state.sfx_voices do
    local v = state.sfx_voices[i]
    if v.until_at > now then
      kept[#kept + 1] = v
    end
  end
  state.sfx_voices = kept
end

local function allocate_sfx_slot(state, prio, now)
  prune_sfx_voices(state, now)
  if #state.sfx_voices < M.MAX_SFX_VOICES then
    return true
  end
  local victim_idx = nil
  local victim_prio = 99
  local victim_started = math.huge
  for i = 1, #state.sfx_voices do
    local v = state.sfx_voices[i]
    if v.prio < victim_prio or (v.prio == victim_prio and v.started_at < victim_started) then
      victim_idx = i
      victim_prio = v.prio
      victim_started = v.started_at
    end
  end
  if victim_idx == nil then
    return false
  end
  -- High-priority cues (death/alert/big blast) always pre-empt shot/low-priority voices;
  -- low-priority shot never pre-empts higher-priority voices.
  if prio < victim_prio then
    return false
  end
  if prio == 1 and victim_prio > 1 then
    return false
  end
  local victim = state.sfx_voices[victim_idx]
  if victim.play_id ~= nil then
    safe_sound_stop(victim.url, { play_id = victim.play_id })
  else
    safe_sound_stop(victim.url)
  end
  table.remove(state.sfx_voices, victim_idx)
  return true
end

function M.new()
  local state = {
    audio_state = nil,
    current_bgm = nil,
    charge_play_id = nil,
    sfx_voices = {},
    played_in_batch = {},
    paused = false,
    is_web = (html5 ~= nil),
  }
  state.audio_state = audio.new({
    cooldown = 0.06,
    on_unlock = function()
      if html5 ~= nil and html5.run ~= nil then
        pcall(html5.run, WEB_UNLOCK_JS)
      end
    end,
  })
  apply_group_gains(false)
  return state
end

function M.is_known_cue(cue_id)
  return type(cue_id) == "string" and CUE_META[cue_id] ~= nil
end

function M.stop_all_bgm(state)
  for i = 1, #ALL_BGMS do
    safe_sound_stop("#snd_" .. ALL_BGMS[i])
  end
  for i = 1, #ALL_JINGLES do
    safe_sound_stop("#snd_" .. ALL_JINGLES[i])
  end
  state.current_bgm = nil
end

function M.stop_charge(state)
  if state.charge_play_id ~= nil then
    safe_sound_stop("#snd_charge_rise", { play_id = state.charge_play_id })
    state.charge_play_id = nil
  else
    safe_sound_stop("#snd_charge_rise")
  end
  local kept = {}
  for i = 1, #state.sfx_voices do
    if state.sfx_voices[i].cue_id ~= "charge_rise" then
      kept[#kept + 1] = state.sfx_voices[i]
    end
  end
  state.sfx_voices = kept
end

function M.set_paused(state, paused)
  state.paused = (paused == true)
  if state.test_mode then
    return
  end
  if state.paused then
    M.stop_charge(state)
  end
  apply_group_gains(state.paused)
end

function M.set_test_mode(state, enabled)
  local flag = (enabled == true)
  if state.test_mode == flag then
    return
  end
  if flag and not state.ever_silenced then
    state.ever_silenced = true
    M.stop_charge(state)
    M.stop_all_bgm(state)
  end
  state.test_mode = flag
end

function M.end_batch(state)
  state.played_in_batch = {}
end

function M.play(state, cue_id, now)
  local meta = CUE_META[cue_id]
  if meta == nil then
    return false
  end
  local url = "#snd_" .. cue_id

  if meta.kind == "bgm" then
    if state.current_bgm == cue_id then
      return true
    end
    audio.trigger(state.audio_state, cue_id, now)
    if not state.test_mode then
      M.stop_all_bgm(state)
      safe_sound_play(url)
    end
    state.current_bgm = cue_id
    return true
  end

  if meta.kind == "jingle" then
    if not state.test_mode then
      M.stop_all_bgm(state)
      M.stop_charge(state)
    else
      state.current_bgm = nil
    end
    audio.trigger(state.audio_state, cue_id, now)
    if not state.test_mode then
      safe_sound_play(url)
    end
    return true
  end

  if meta.kind == "ui" then
    if not audio.trigger(state.audio_state, cue_id, now) then
      return false
    end
    if not state.test_mode then
      safe_sound_play(url)
    end
    return true
  end

  -- SFX cue: enforce 0.06 s cooldown gate first, then 8-voice priority pool.
  if not audio.trigger(state.audio_state, cue_id, now) then
    return false
  end
  if cue_id == "charge_rise" and not state.test_mode then
    M.stop_charge(state)
  end
  if not allocate_sfx_slot(state, meta.prio, now) then
    return false
  end
  local play_id = nil
  if not state.test_mode and not state.played_in_batch[cue_id] then
    state.played_in_batch[cue_id] = true
    safe_sound_stop(url)
    play_id = safe_sound_play(url)
  end
  if cue_id == "charge_rise" then
    state.charge_play_id = play_id
  end
  state.sfx_voices[#state.sfx_voices + 1] = {
    cue_id = cue_id,
    url = url,
    play_id = play_id,
    prio = meta.prio,
    started_at = now,
    until_at = now + meta.dur,
  }
  return true
end

function M.unlock_real_gesture(state, now)
  return audio.unlock(state.audio_state, now)
end

function M.unlock_native_only(state, now)
  if state.is_web then
    return false
  end
  return audio.unlock(state.audio_state, now)
end

-- Periodic RMS sampling: queries Defold's master mixer group over a 0.10 s window,
-- computes stereo root-mean-square sqrt(0.5 * (L^2 + R^2)), records session peak,
-- and emits STUDIO_TELEMETRY audio_rms.
function M.sample_rms(state, now)
  prune_sfx_voices(state, now)
  local ok, left, right = pcall(sound.get_rms, hash("master"), 0.1)
  local measured = 0.0
  if ok and type(left) == "number" then
    local r = type(right) == "number" and right or left
    measured = math.sqrt(0.5 * (left * left + r * r))
  end
  if measured ~= measured or measured < 0 then
    measured = 0.0
  end
  audio.record_rms(state.audio_state, measured)
  return audio.report_rms(state.audio_state, now)
end

function M.reset(state, now)
  M.stop_charge(state)
  M.stop_all_bgm(state)
  state.sfx_voices = {}
  state.paused = false
  apply_group_gains(false)
  audio.reset(state.audio_state, now)
end

return M
