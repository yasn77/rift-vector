-- main/sim.lua -- Deterministic 60 Hz simulation core and explicit tween engine
-- for Rift Vector. Pure Lua 5.1: zero module-level mutable state, no wall clock,
-- no math.random and no Defold engine calls. British English (Oxford spelling).

local stages = require "main.stages"

local M = {}

M.DT = 1.0 / 60.0
M.MAX_SCORE = 999999999
M.SHIP_START_X = 64.0
M.SHIP_START_Y = 112.0
M.SHIP_MIN_X = 16.0
M.SHIP_MAX_X = 304.0
M.SHIP_MIN_Y = 32.0
M.SHIP_MAX_Y = 192.0
M.SHIP_HALF_W = 10.0
M.SHIP_HALF_H = 4.0

M.FORCE_RADIUS = 6.0
M.FORCE_ATTACH_OFFSET = 24.0
M.FORCE_HOLD_RIGHT_X = 264.0
M.FORCE_HOLD_LEFT_X = 56.0
M.FORCE_MIDPOINT_X = 160.0
M.FORCE_HYSTERESIS_PX = 16.0
M.FORCE_LAUNCH_SPEED = 200.0
M.FORCE_RECALL_SPEED = 160.0
M.FORCE_MIN_Y = 40.0
M.FORCE_MAX_Y = 184.0

M.PLAYBACK_ONCE_FORWARD = 1
M.PLAYBACK_LOOP_FORWARD = 2
M.PLAYBACK_LOOP_PINGPONG = 3

M.EASING_LINEAR = 1
M.EASING_INOUTSINE = 2

local RNG_MULT = 16807
local RNG_MOD = 2147483647

local KILL_POINTS = {
  drone = 100,
  fighter = 200,
  carrier = 500,
  turret = 300,
  worm_segment = 150,
  mine = 50,
  dop = 250,
  crawler = 200,
}

local WAVE_DAMAGE = { [1] = 8, [2] = 20, [3] = 48 }
local WAVE_HEIGHT = { [1] = 8.0, [2] = 16.0, [3] = 24.0 }

---------------------------------------------------------------------------
-- Pure math and explicit tween helpers
---------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function seed_rng(seed)
  local folded = (seed or 20261118) % (RNG_MOD - 1)
  if folded < 0 then
    folded = folded + (RNG_MOD - 1)
  end
  return folded + 1
end

local function next_rand(sim)
  sim.rng = (RNG_MULT * sim.rng) % RNG_MOD
  return sim.rng / RNG_MOD
end

function M.tween_new(from_val, to_val, duration, playback, easing)
  return {
    from = from_val,
    to = to_val,
    duration = math.max(0.0, duration or 0.0),
    playback = playback or M.PLAYBACK_ONCE_FORWARD,
    easing = easing or M.EASING_LINEAR,
    elapsed = 0.0,
    done = (duration or 0.0) <= 0.0 and (playback == nil or playback == M.PLAYBACK_ONCE_FORWARD),
  }
end

function M.tween_eval(tw)
  if tw == nil then
    return 0.0
  end
  if tw.duration <= 1e-9 then
    return tw.to
  end
  local t = 0.0
  if tw.playback == M.PLAYBACK_ONCE_FORWARD then
    t = tw.elapsed / tw.duration
    if t >= 1.0 then
      t = 1.0
    end
  elseif tw.playback == M.PLAYBACK_LOOP_FORWARD then
    t = (tw.elapsed / tw.duration) % 1.0
  elseif tw.playback == M.PLAYBACK_LOOP_PINGPONG then
    local leg = (tw.elapsed / tw.duration) % 2.0
    if leg <= 1.0 then
      t = leg
    else
      t = 2.0 - leg
    end
  end
  local u = t
  if tw.easing == M.EASING_INOUTSINE then
    u = 0.5 * (1.0 - math.cos(math.pi * t))
  end
  return tw.from + (tw.to - tw.from) * u
end

function M.tween_step(tw, dt)
  if tw == nil then
    return 0.0
  end
  tw.elapsed = tw.elapsed + dt
  if tw.playback == M.PLAYBACK_ONCE_FORWARD and tw.elapsed >= tw.duration then
    tw.elapsed = tw.duration
    tw.done = true
  end
  return M.tween_eval(tw)
end

local function aabb_overlap(ax, ay, ahw, ahh, bx, by, bhw, bhh)
  return math.abs(ax - bx) <= (ahw + bhw) and math.abs(ay - by) <= (ahh + bhh)
end

---------------------------------------------------------------------------
-- Event queue helpers
---------------------------------------------------------------------------

local function push_event(sim, name, payload)
  sim.events[#sim.events + 1] = { name = name, payload = payload or {} }
end

local function request_audio(sim, cue_id)
  push_event(sim, "audio_request", { cue_id = cue_id })
end

local function emit_force_state(sim)
  local f = sim.force
  push_event(sim, "force_state", {
    state = f.level > 0 and f.state or "unacquired",
    level = f.level,
    weapon = f.weapon,
  })
end

local function emit_wave_charge(sim, tier, fraction)
  push_event(sim, "wave_charge", {
    tier = tier,
    fraction = fraction,
  })
end

local function add_score(sim, amount, reason, award_id)
  if type(amount) ~= "number" or amount <= 0 then
    return false
  end
  local pts = math.floor(amount)
  if award_id ~= nil and award_id ~= "" then
    if sim.reward_ledger[award_id] then
      return false
    end
    sim.reward_ledger[award_id] = true
  end
  sim.score = math.min(M.MAX_SCORE, sim.score + pts)
  if sim.score > sim.hi_score then
    sim.hi_score = sim.score
    sim.hi_score_dirty = true
  end
  push_event(sim, "score_add", {
    amount = pts,
    reason = reason or "score",
    award_id = award_id or ("aw-" .. tostring(sim.next_uid)),
  })
  sim.next_uid = sim.next_uid + 1
  return true
end

local function cancel_fire_and_charge(sim)
  local was_charging = sim.fire_held or sim.charge_sound_played or sim.charge_tier > 0 or sim.charge_time > 0
  sim.fire_held = false
  sim.charge_time = 0.0
  sim.charge_tier = 0
  sim.charge_fraction = 0.0
  sim.charge_sound_played = false
  if was_charging then
    sim.stop_charge_audio = true
    emit_wave_charge(sim, 0, 0.0)
  end
end

local function set_screen(sim, new_screen)
  if sim.screen == new_screen then
    push_event(sim, "screen_changed", { screen = new_screen })
    return
  end
  cancel_fire_and_charge(sim)
  sim.screen = new_screen
  push_event(sim, "screen_changed", { screen = new_screen })
end

---------------------------------------------------------------------------
-- Starfield initialisation (18 stars across 3 parallax depth layers)
---------------------------------------------------------------------------

local function init_stars(sim)
  sim.stars = {}
  local speeds = { 4.0, 8.0, 12.0 }
  for layer = 1, 3 do
    local spd = speeds[layer]
    for idx = 1, 6 do
      local base_x = ((idx - 1) * 53 + layer * 19) % 320
      local base_y = 44 + ((idx * 23 + layer * 31) % 136)
      local dur = 320.0 / spd
      local tw = M.tween_new(320.0, 0.0, dur, M.PLAYBACK_LOOP_FORWARD, M.EASING_LINEAR)
      tw.elapsed = ((320.0 - base_x) / 320.0) * dur
      sim.stars[#sim.stars + 1] = {
        id = (layer - 1) * 6 + idx,
        layer = layer,
        x = M.tween_eval(tw),
        y = base_y,
        tw = tw,
      }
    end
  end
end

---------------------------------------------------------------------------
-- Ship & Force target tween management
---------------------------------------------------------------------------

local function ship_speed(sim)
  return 80.0 + 16.0 * clamp(sim.speed_level, 0, 3)
end

local function retarget_ship_tweens(sim)
  local dx = sim.move_dx
  local dy = sim.move_dy
  local mag = math.sqrt(dx * dx + dy * dy)
  local nx, ny = dx, dy
  if mag > 1.0 then
    nx = dx / mag
    ny = dy / mag
  end
  local spd = ship_speed(sim)
  local vx = nx * spd
  local vy = ny * spd

  if math.abs(vx) < 1e-6 then
    sim.ship.tw_x = nil
  else
    local target_x = vx > 0 and M.SHIP_MAX_X or M.SHIP_MIN_X
    local dist_x = math.abs(target_x - sim.ship.x)
    sim.ship.tw_x = M.tween_new(sim.ship.x, target_x, dist_x / math.abs(vx), M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
  end

  if math.abs(vy) < 1e-6 then
    sim.ship.tw_y = nil
  else
    local target_y = vy > 0 and M.SHIP_MAX_Y or M.SHIP_MIN_Y
    local dist_y = math.abs(target_y - sim.ship.y)
    sim.ship.tw_y = M.tween_new(sim.ship.y, target_y, dist_y / math.abs(vy), M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
  end
end

local function update_force_hold_side(sim)
  local f = sim.force
  if sim.ship.x > (M.FORCE_MIDPOINT_X + M.FORCE_HYSTERESIS_PX) then
    f.hold_side = "left"
  elseif sim.ship.x < (M.FORCE_MIDPOINT_X - M.FORCE_HYSTERESIS_PX) then
    f.hold_side = "right"
  end
end

local function retarget_force_tween(sim, speed)
  local f = sim.force
  local tx = (f.hold_side == "left") and M.FORCE_HOLD_LEFT_X or M.FORCE_HOLD_RIGHT_X
  local ty = clamp(sim.ship.y, M.FORCE_MIN_Y, M.FORCE_MAX_Y)
  if f.target_x == tx and f.target_y == ty and f.tw_x ~= nil and f.tw_y ~= nil and f.tw_speed == speed then
    return
  end
  f.target_x = tx
  f.target_y = ty
  f.tw_speed = speed
  local dx = tx - f.x
  local dy = ty - f.y
  local dist = math.sqrt(dx * dx + dy * dy)
  local dur = dist / speed
  f.tw_x = M.tween_new(f.x, tx, dur, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
  f.tw_y = M.tween_new(f.y, ty, dur, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
end

local function sync_attached_support(sim)
  local f = sim.force
  if f.level > 0 then
    if f.state == "attached_front" then
      f.x = sim.ship.x + M.FORCE_ATTACH_OFFSET
      f.y = sim.ship.y
    elseif f.state == "attached_rear" then
      f.x = sim.ship.x - M.FORCE_ATTACH_OFFSET
      f.y = sim.ship.y
    end
  end
  sim.bit_positions[1].x = sim.ship.x
  sim.bit_positions[1].y = sim.ship.y + 20.0
  sim.bit_positions[2].x = sim.ship.x
  sim.bit_positions[2].y = sim.ship.y - 20.0
end

---------------------------------------------------------------------------
-- Stage & checkpoint setup
---------------------------------------------------------------------------

local function build_stage_attempt(sim, start_scroll_px, invuln_s)
  local st = stages.get_stage(sim.stage)
  sim.scroll_px = start_scroll_px
  local rem_px = math.max(0.0, stages.STAGE_LENGTH_PX - start_scroll_px)
  sim.scroll_tw = M.tween_new(
    start_scroll_px,
    stages.STAGE_LENGTH_PX,
    rem_px / stages.SCROLL_SPEED,
    M.PLAYBACK_ONCE_FORWARD,
    M.EASING_LINEAR
  )
  sim.scroll_time = start_scroll_px / stages.SCROLL_SPEED
  sim.boss_locked = false
  sim.stage_cleared = false
  sim.death_timer = 0.0
  sim.invuln_timer = invuln_s or 0.0
  sim.missile_cd = 0.0
  sim.aimed_cd = 0.8

  sim.ship.x = M.SHIP_START_X
  sim.ship.y = M.SHIP_START_Y
  sim.ship.alive = true
  retarget_ship_tweens(sim)

  sim.enemies = {}
  sim.pending_spawns = {}
  sim.player_shots = {}
  sim.enemy_bullets = {}
  sim.pickups = {}
  sim.explosions = {}
  sim.boss = nil

  -- Deterministic spawn counters aligned to start_scroll_px
  sim.formation_index = math.floor(sim.scroll_time / st.spawn_s)
  sim.next_formation_time = (sim.formation_index + 1) * st.spawn_s
  sim.carrier_slot = math.floor(sim.scroll_time / 12.0)
  sim.next_carrier_time = (sim.carrier_slot + 1) * 12.0

  if sim.force.acquired and sim.force.level > 0 then
    if sim.force.state == "launching" or sim.force.state == "detached" or sim.force.state == "recalling" then
      sim.force.state = "attached_front"
      sim.force.tw_x = nil
      sim.force.tw_y = nil
    end
  end
  sync_attached_support(sim)
  cancel_fire_and_charge(sim)
end

local function enter_stage_fresh(sim, stage_num)
  sim.stage = clamp(math.floor(stage_num or 1), 1, 10)
  sim.checkpoint_reached = false
  sim.stage_had_death = false
  sim.rng = seed_rng(20261118 + sim.stage * 7919)
  build_stage_attempt(sim, 0.0, 0.0)
  local st = stages.get_stage(sim.stage)
  request_audio(sim, st.bgm)
end

---------------------------------------------------------------------------
-- Lifecycle & public constructor
---------------------------------------------------------------------------

function M.new(initial_hi_score)
  local sim = {
    screen = "title",
    test_mode = false,
    seed = 20261118,
    rng = seed_rng(20261118),
    tick = 0,
    stage = 1,
    score = 0,
    hi_score = math.max(0, math.floor(initial_hi_score or 0)),
    hi_score_dirty = false,
    lives = 3,
    checkpoint_reached = false,
    stage_had_death = false,
    stage_cleared = false,
    boss_locked = false,
    scroll_px = 0.0,
    scroll_tw = nil,
    scroll_time = 0.0,
    death_timer = 0.0,
    invuln_timer = 0.0,
    missile_cd = 0.0,
    aimed_cd = 0.0,

    move_dx = 0.0,
    move_dy = 0.0,
    fire_held = false,
    charge_time = 0.0,
    charge_tier = 0,
    charge_fraction = 0.0,
    charge_sound_played = false,
    stop_charge_audio = false,

    speed_level = 0,
    bits = 0,
    has_missiles = false,
    bit_positions = {
      { x = M.SHIP_START_X, y = M.SHIP_START_Y + 20.0 },
      { x = M.SHIP_START_X, y = M.SHIP_START_Y - 20.0 },
    },

    ship = {
      x = M.SHIP_START_X,
      y = M.SHIP_START_Y,
      alive = true,
      tw_x = nil,
      tw_y = nil,
    },

    force = {
      acquired = false,
      level = 0,
      state = "unacquired",
      weapon = "vulcan",
      hold_side = "right",
      x = M.SHIP_START_X + M.FORCE_ATTACH_OFFSET,
      y = M.SHIP_START_Y,
      target_x = nil,
      target_y = nil,
      tw_x = nil,
      tw_y = nil,
      tw_speed = 0.0,
      ram_cds = {},
    },

    stars = {},
    enemies = {},
    pending_spawns = {},
    player_shots = {},
    enemy_bullets = {},
    pickups = {},
    explosions = {},
    boss = nil,
    reward_ledger = {},
    events = {},
    next_uid = 1,
    formation_index = 0,
    next_formation_time = 2.40,
    carrier_slot = 0,
    next_carrier_time = 12.0,
  }
  init_stars(sim)
  return sim
end

function M.reset_to_title(sim, disk_hi_score)
  if type(disk_hi_score) == "number" and disk_hi_score > sim.hi_score then
    sim.hi_score = math.floor(disk_hi_score)
  end
  sim.rng = seed_rng(sim.seed)
  sim.tick = 0
  sim.stage = 1
  sim.score = 0
  sim.lives = 3
  sim.checkpoint_reached = false
  sim.stage_had_death = false
  sim.stage_cleared = false
  sim.boss_locked = false
  sim.scroll_px = 0.0
  sim.scroll_tw = nil
  sim.scroll_time = 0.0
  sim.death_timer = 0.0
  sim.invuln_timer = 0.0
  sim.missile_cd = 0.0
  sim.move_dx = 0.0
  sim.move_dy = 0.0
  sim.speed_level = 0
  sim.bits = 0
  sim.has_missiles = false
  sim.force = {
    acquired = false,
    level = 0,
    state = "unacquired",
    weapon = "vulcan",
    hold_side = "right",
    x = M.SHIP_START_X + M.FORCE_ATTACH_OFFSET,
    y = M.SHIP_START_Y,
    target_x = nil,
    target_y = nil,
    tw_x = nil,
    tw_y = nil,
    tw_speed = 0.0,
    ram_cds = {},
  }
  sim.enemies = {}
  sim.pending_spawns = {}
  sim.player_shots = {}
  sim.enemy_bullets = {}
  sim.pickups = {}
  sim.explosions = {}
  sim.boss = nil
  sim.reward_ledger = {}
  sim.next_uid = 1
  init_stars(sim)
  cancel_fire_and_charge(sim)
  sim.screen = "title"
  push_event(sim, "screen_changed", { screen = "title" })
  request_audio(sim, "bgm_title")
end

function M.drain_events(sim)
  local out = sim.events
  sim.events = {}
  return out
end

---------------------------------------------------------------------------
-- Spawning: explosions, projectiles, pickups, enemies, and 10 bosses
---------------------------------------------------------------------------

local function spawn_explosion(sim, x, y, big)
  sim.explosions[#sim.explosions + 1] = {
    id = "fx-" .. tostring(sim.next_uid),
    x = x,
    y = y,
    big = (big == true),
    ttl = 0.25,
  }
  sim.next_uid = sim.next_uid + 1
end

local function add_player_shot(sim, spec)
  local vx = spec.vx or 240.0
  local vy = spec.vy or 0.0
  local ttl = spec.ttl or 2.0
  local sx = spec.x
  local sy = spec.y
  local shot = {
    id = "ps-" .. tostring(sim.next_uid),
    kind = spec.kind or "vulcan",
    anim = spec.anim or "player_shot_fly",
    x = sx,
    y = sy,
    vx = vx,
    vy = vy,
    tw_x = M.tween_new(sx, sx + vx * ttl, ttl, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    tw_y = M.tween_new(sy, sy + vy * ttl, ttl, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    helix_tw = spec.helix_sign and M.tween_new(-4.0 * spec.helix_sign, 4.0 * spec.helix_sign, 0.4, M.PLAYBACK_LOOP_PINGPONG, M.EASING_INOUTSINE) or nil,
    dmg = spec.dmg or 1,
    hw = (spec.w or 8.0) * 0.5,
    hh = (spec.h or 8.0) * 0.5,
    scale_y = spec.scale_y or 1.0,
    pierce = (spec.pierce == true),
    hit_ids = {},
    hit_cds = {},
    bounces_left = spec.bounces_left or 0,
    crawl_dir = spec.crawl_dir or 1,
    crawling = false,
    tick_cd = 0.0,
    heading = spec.heading or 0.0,
    rot_tw = nil,
    steer_timer = 0.0,
    ttl = ttl,
    age = 0.0,
    hflip = (spec.hflip == true),
  }
  sim.next_uid = sim.next_uid + 1
  sim.player_shots[#sim.player_shots + 1] = shot
end

local function add_enemy_bullet(sim, x, y, vx, vy, orb)
  if #sim.enemy_bullets >= 10 then
    return false
  end
  local ttl = 6.0
  sim.enemy_bullets[#sim.enemy_bullets + 1] = {
    id = "eb-" .. tostring(sim.next_uid),
    anim = orb and "enemy_orb_pulse" or "enemy_shot_fly",
    x = x,
    y = y,
    vx = vx,
    vy = vy,
    tw_x = M.tween_new(x, x + vx * ttl, ttl, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    tw_y = M.tween_new(y, y + vy * ttl, ttl, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    hw = orb and 5.0 or 3.0,
    hh = orb and 5.0 or 3.0,
    ttl = ttl,
  }
  sim.next_uid = sim.next_uid + 1
  return true
end

local function fire_aimed_enemy_bullet(sim, ex, ey, speed, orb, offset_sign)
  if sim.aimed_cd > 0.0 or #sim.enemy_bullets >= 10 then
    return false
  end
  local _ = offset_sign
  local ty = (ey >= 112.0) and 148.0 or 76.0
  local dx = sim.ship.x - ex
  local dy = ty - ey
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < 48.0 then
    return false
  end
  sim.aimed_cd = 1.05
  return add_enemy_bullet(sim, ex, ey, (dx / dist) * speed, (dy / dist) * speed, orb)
end

local function effective_pickup_kind(sim, raw_kind)
  if raw_kind == "bit" and sim.bits >= 2 then
    return "red"
  end
  if raw_kind == "speed" and sim.speed_level >= 3 then
    return "blue"
  end
  return raw_kind
end

local PICKUP_ANIMS = {
  red = "crystal_red_pulse",
  blue = "crystal_blue_pulse",
  yellow = "crystal_yellow_pulse",
  bit = "pickup_bit_pulse",
  speed = "pickup_speed_pulse",
  missile = "pickup_missile_pulse",
}

local function spawn_pickup(sim, x, y, kind, spawn_id)
  local actual = effective_pickup_kind(sim, kind)
  local ttl = (x + 32.0) / 24.0
  sim.pickups[#sim.pickups + 1] = {
    spawn_id = spawn_id or ("pk-" .. tostring(sim.next_uid)),
    kind = actual,
    anim = PICKUP_ANIMS[actual] or "crystal_red_pulse",
    x = x,
    y = clamp(y, 48.0, 176.0),
    tw_x = M.tween_new(x, -32.0, ttl, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    hw = 10.0,
    hh = 8.0,
  }
  sim.next_uid = sim.next_uid + 1
end

function M.collect_powerup(sim, raw_kind, spawn_id)
  local valid = {
    red = true, blue = true, yellow = true,
    bit = true, speed = true, missile = true,
  }
  if not valid[raw_kind] then
    return
  end
  local kind = effective_pickup_kind(sim, raw_kind)
  local sid = spawn_id or ("pk-" .. tostring(sim.next_uid))
  sim.next_uid = sim.next_uid + 1

  if kind == "red" or kind == "blue" or kind == "yellow" then
    if not sim.force.acquired or sim.force.level == 0 then
      sim.force.acquired = true
      sim.force.level = 1
      sim.force.state = "attached_front"
      sim.force.weapon = kind
      sync_attached_support(sim)
    else
      sim.force.level = math.min(3, sim.force.level + 1)
      sim.force.weapon = kind
    end
    request_audio(sim, "pickup_crystal")
    emit_force_state(sim)
  elseif kind == "bit" then
    sim.bits = math.min(2, sim.bits + 1)
    request_audio(sim, "pickup_power")
  elseif kind == "speed" then
    sim.speed_level = math.min(3, sim.speed_level + 1)
    retarget_ship_tweens(sim)
    request_audio(sim, "pickup_power")
  elseif kind == "missile" then
    sim.has_missiles = true
    request_audio(sim, "pickup_power")
  end

  push_event(sim, "powerup_collected", {
    kind = kind,
    spawn_id = sid,
  })
end

local function spawn_enemy_entity(sim, spec)
  local stats = stages.ENEMY_STATS[spec.kind] or stages.ENEMY_STATS.drone
  local x0 = spec.x or 344.0
  local y0 = spec.y or 112.0
  local speed_x = spec.speed_x or 48.0
  local dur_x = (x0 + 24.0) / speed_x
  local bob_tw = nil
  if spec.kind == "carrier" then
    bob_tw = M.tween_new(y0, y0 + 16.0, 0.6, M.PLAYBACK_LOOP_PINGPONG, M.EASING_INOUTSINE)
  elseif spec.bob_amp and spec.bob_amp ~= 0 then
    bob_tw = M.tween_new(y0, y0 + spec.bob_amp, 1.4, M.PLAYBACK_LOOP_PINGPONG, M.EASING_INOUTSINE)
  end

  sim.enemies[#sim.enemies + 1] = {
    spawn_id = spec.spawn_id,
    kind = spec.kind,
    anim = stats.anim,
    hp = stats.hp,
    max_hp = stats.hp,
    x = x0,
    y = y0,
    anchor_y = y0,
    wall_side = spec.wall_side, -- "bottom" or "top" for turret/crawler
    drop_kind = spec.drop_kind,
    tw_x = M.tween_new(x0, -24.0, dur_x, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR),
    tw_y = bob_tw,
    hw = stats.w * 0.5,
    hh = (spec.kind == "carrier") and 11.0 or (stats.h * 0.5),
    fire_timer = spec.fire_delay or 1.1,
    fall_lane = spec.fall_lane,
    tell_timer = spec.tell_timer or 0.0,
  }
end

local function schedule_formation(sim)
  local st = stages.get_stage(sim.stage)
  sim.formation_index = sim.formation_index + 1
  local f_idx = sim.formation_index
  local mix = st.mix
  local kind = mix[((f_idx - 1) % #mix) + 1]

  -- Formation count 1..3; first formation on every stage is 3 aligned units.
  local count_pattern = { 3, 1, 2, 3 }
  local count = count_pattern[((f_idx - 1) % #count_pattern) + 1]
  if kind == "turret" or kind == "crawler" then
    count = (f_idx % 2 == 1) and 2 or 1
  end

  -- Authored upper/lower/mid lanes; keeps Stage 3 & Stage 6 mid-lane fair and keeps carrier windows open.
  local near_carrier = false
  local mod12 = sim.scroll_time % 12.0
  if mod12 > 7.5 or mod12 < 5.0 then
    near_carrier = true
  end

  local lanes = { 66.0, 134.0, 62.0, 138.0 }
  if near_carrier then
    lanes = { 54.0, 56.0 }
  end
  local base_y = lanes[((f_idx - 1) % #lanes) + 1]

  for m = 1, count do
    local sid = string.format("s%d-f%d-%d", sim.stage, f_idx, m)
    local wall_side = nil
    local y0 = base_y
    local speed_x = 48.0
    local bob_amp = 24.0
    local x0 = 344.0

    if kind == "turret" then
      wall_side = (near_carrier or ((f_idx + m) % 2 == 0)) and "bottom" or "top"
      speed_x = stages.SCROLL_SPEED
      bob_amp = 0.0
      x0 = 332.0
      y0 = (wall_side == "bottom") and 50.0 or 174.0
    elseif kind == "crawler" then
      wall_side = (near_carrier or ((f_idx + m) % 2 == 0)) and "bottom" or "top"
      speed_x = 40.0
      bob_amp = 0.0
      x0 = 336.0
      y0 = (wall_side == "bottom") and 48.0 or 176.0
    elseif kind == "mine" then
      speed_x = 38.0
      bob_amp = 10.0
    end

    sim.pending_spawns[#sim.pending_spawns + 1] = {
      due_time = sim.scroll_time + (m - 1) * 0.20,
      spec = {
        spawn_id = sid,
        kind = kind,
        x = x0,
        y = y0,
        speed_x = speed_x,
        bob_amp = bob_amp,
        wall_side = wall_side,
        fire_delay = 0.7 + 0.35 * m,
      },
    }
  end
end

local function spawn_stage_boss(sim)
  local st = stages.get_stage(sim.stage)
  local b = {
    stage = sim.stage,
    id = st.boss_id,
    anim = st.boss_anim,
    name = st.boss_name,
    hp = st.boss_hp,
    max_hp = st.boss_hp,
    x = st.boss_x,
    y = st.boss_y,
    base_x = st.boss_x,
    base_y = st.boss_y,
    core_dx = st.core_dx,
    core_dy = st.core_dy,
    core_x = st.boss_x + st.core_dx,
    core_y = st.boss_y + st.core_dy,
    expose_s = st.expose_s,
    cycle_s = st.cycle_s,
    clock = 0.0,
    cycle_index = 0,
    exposed = false,
    phase = 1,
    did_cycle_attack = false,
    tell_active = false,
    orbit_tw = M.tween_new(0.0, 360.0, 6.0, M.PLAYBACK_LOOP_FORWARD, M.EASING_LINEAR),
    core_scale_tw = M.tween_new(1.0, 1.0625, 0.4, M.PLAYBACK_LOOP_PINGPONG, M.EASING_INOUTSINE),
    lunge_offset_x = 0.0,
    parts = {},
    shell_cleared = (sim.stage ~= 5),
    next_shed_time = 1.6,
  }

  if sim.stage == 4 then
    -- Three orbiting compiler lobes
    for i = 1, 3 do
      b.parts[#b.parts + 1] = {
        id = "lobe-" .. tostring(i),
        kind = "lobe",
        anim = st.boss_anim,
        angle_offset = (i - 1) * 120.0,
        radius = 28.0,
        x = b.x,
        y = b.y,
        hp = 9999,
        indestructible = true,
      }
    end
  elseif sim.stage == 5 then
    -- Bellmite Matron: six 2-HP shell cells across front arc
    local ys = { 76.0, 90.0, 104.0, 120.0, 134.0, 148.0 }
    for i = 1, 6 do
      b.parts[#b.parts + 1] = {
        id = "bell-cell-" .. tostring(i),
        kind = "cell",
        anim = "mine_arm",
        x = b.x - 28.0,
        y = ys[i],
        hw = 9.0,
        hh = 9.0,
        hp = 2,
        indestructible = false,
      }
    end
  elseif sim.stage == 7 then
    -- Dop Regent: four 3-HP dop clones in off-axis guard lanes
    local ys = { 68.0, 90.0, 134.0, 156.0 }
    for i = 1, 4 do
      b.parts[#b.parts + 1] = {
        id = "regent-dop-0-" .. tostring(i),
        kind = "dop_clone",
        anim = "dop_guard",
        x = b.x - 36.0,
        y = ys[i],
        hw = 10.0,
        hh = 10.0,
        hp = 3,
        indestructible = false,
      }
    end
  end

  sim.boss = b
  request_audio(sim, "boss_alert")
  request_audio(sim, sim.stage == 10 and "bgm_final_boss" or "bgm_boss")
end

---------------------------------------------------------------------------
-- Boss defeat & player hit / continue / kill helpers
---------------------------------------------------------------------------

function M.award_enemy_kill(sim, spawn_id, kind, stage_num, emit_killed_msg)
  local pts = KILL_POINTS[kind] or 0
  local stg = math.floor(stage_num or sim.stage)
  local sid = tostring(spawn_id or ("ek-" .. tostring(sim.next_uid)))
  if emit_killed_msg then
    push_event(sim, "enemy_killed", {
      spawn_id = sid,
      kind = kind,
      stage = stg,
    })
  end
  if pts > 0 then
    local award_id = tostring(stg) .. ":" .. sid
    add_score(sim, pts, "enemy:" .. tostring(kind), award_id)
  end
end

function M.defeat_boss(sim, stage_override)
  if sim.screen ~= "play" or sim.stage_cleared then
    return
  end
  local stg = math.floor(stage_override or sim.stage)
  if stg ~= sim.stage then
    return
  end
  sim.stage_cleared = true
  if sim.boss then
    spawn_explosion(sim, sim.boss.x, sim.boss.y, true)
    sim.boss = nil
  end
  sim.enemy_bullets = {}
  sim.enemies = {}
  sim.pending_spawns = {}

  request_audio(sim, "explosion_big")
  local boss_pts = 5000 + 1000 * stg
  add_score(sim, boss_pts, "boss", string.format("boss:%d", stg))
  if not sim.stage_had_death then
    add_score(sim, 10000, "no_miss", string.format("nomiss:%d", stg))
  end

  push_event(sim, "boss_defeated", { stage = stg })
  if stg >= 10 then
    request_audio(sim, "jingle_victory")
    set_screen(sim, "victory")
  else
    push_event(sim, "stage_clear", { stage = stg })
    request_audio(sim, "jingle_stage_clear")
    set_screen(sim, "stage_clear")
  end
end

function M.trigger_player_hit(sim, source_id)
  if sim.screen ~= "play" or not sim.ship.alive then
    return false
  end
  if sim.death_timer > 0.0 or sim.invuln_timer > 0.0 then
    return false
  end

  sim.ship.alive = false
  sim.stage_had_death = true
  sim.lives = math.max(0, sim.lives - 1)
  sim.death_timer = 1.0
  cancel_fire_and_charge(sim)
  spawn_explosion(sim, sim.ship.x, sim.ship.y, true)

  push_event(sim, "player_hit", { source_id = tostring(source_id or "hazard") })
  request_audio(sim, "player_die")
  return true
end

local function apply_death_equipment_reset(sim)
  sim.speed_level = 0
  sim.bits = 0
  sim.has_missiles = false
  if sim.force.acquired then
    sim.force.level = 1
    sim.force.state = "attached_front"
    sim.force.weapon = "vulcan"
    sim.force.tw_x = nil
    sim.force.tw_y = nil
  else
    sim.force.level = 0
    sim.force.state = "unacquired"
    sim.force.weapon = "vulcan"
  end
end

---------------------------------------------------------------------------
-- Weapon firing on press edge & wave beam on release edge
---------------------------------------------------------------------------

local function fire_press_weapons(sim)
  -- 1. Nose vulcan
  add_player_shot(sim, {
    kind = "vulcan",
    anim = "player_shot_fly",
    x = sim.ship.x + 14.0,
    y = sim.ship.y,
    vx = 240.0,
    vy = 0.0,
    dmg = 1,
    w = 8.0,
    h = 8.0,
    ttl = 2.0,
  })
  request_audio(sim, "shot")

  -- 2. Force pod weapons
  local f = sim.force
  if f.level >= 1 then
    if f.state == "attached_front" or f.state == "attached_rear" then
      local dir = (f.state == "attached_front") and 1.0 or -1.0
      local flip = (dir < 0.0)
      if f.weapon == "vulcan" then
        add_player_shot(sim, {
          kind = "force_bolt",
          anim = "player_shot_fly",
          x = f.x + dir * 10.0,
          y = f.y,
          vx = dir * 240.0,
          vy = 0.0,
          dmg = 1,
          w = 8.0,
          h = 8.0,
          ttl = 2.0,
          hflip = flip,
        })
      elseif f.weapon == "red" then
        for s = -1, 1, 2 do
          add_player_shot(sim, {
            kind = "laser_red",
            anim = "laser_red_surge",
            x = f.x + dir * 12.0,
            y = f.y + s * 4.0,
            vx = dir * 220.0,
            vy = 0.0,
            dmg = f.level,
            w = 24.0,
            h = (f.level >= 3) and 12.0 or 8.0,
            helix_sign = (f.level >= 3) and s or nil,
            ttl = 2.0,
            hflip = flip,
          })
        end
      elseif f.weapon == "blue" then
        local angles = { 0.0, math.pi * 0.25, -math.pi * 0.25 }
        for i = 1, #angles do
          local a = angles[i]
          local vx = dir * math.cos(a) * 220.0
          local vy = math.sin(a) * 220.0
          add_player_shot(sim, {
            kind = "laser_blue",
            anim = "laser_blue_surge",
            x = f.x + dir * 10.0,
            y = f.y,
            vx = vx,
            vy = vy,
            dmg = f.level,
            w = 16.0,
            h = 8.0,
            pierce = true,
            bounces_left = 2,
            ttl = 1.2,
            heading = math.atan2(vy, vx),
            hflip = false,
          })
        end
      elseif f.weapon == "yellow" then
        for s = -1, 1, 2 do
          add_player_shot(sim, {
            kind = "laser_yellow",
            anim = "laser_yellow_surge",
            x = f.x,
            y = f.y + s * 8.0,
            vx = 0.0,
            vy = s * 220.0,
            dmg = f.level,
            w = 12.0,
            h = 20.0,
            pierce = true,
            crawl_dir = dir,
            ttl = 0.8,
            hflip = flip,
          })
        end
      end
    else
      -- Detached / launching / recalling Force shot patterns by level
      if f.level == 1 then
        add_player_shot(sim, {
          kind = "force_bolt",
          anim = "player_shot_fly",
          x = f.x + 8.0,
          y = f.y,
          vx = 240.0,
          vy = 0.0,
          dmg = 1,
          w = 8.0,
          h = 8.0,
          ttl = 2.0,
        })
      else
        local c30 = math.cos(math.pi / 6.0) * 240.0
        local s30 = 120.0
        add_player_shot(sim, {
          kind = "force_bolt", anim = "player_shot_fly",
          x = f.x + 6.0, y = f.y + 4.0, vx = c30, vy = s30, dmg = 1, w = 8.0, h = 8.0, ttl = 2.0,
        })
        add_player_shot(sim, {
          kind = "force_bolt", anim = "player_shot_fly",
          x = f.x + 6.0, y = f.y - 4.0, vx = c30, vy = -s30, dmg = 1, w = 8.0, h = 8.0, ttl = 2.0,
        })
        if f.level >= 3 then
          add_player_shot(sim, {
            kind = "force_bolt", anim = "player_shot_fly",
            x = f.x, y = f.y + 8.0, vx = 0.0, vy = 240.0, dmg = 1, w = 8.0, h = 8.0, ttl = 2.0,
          })
          add_player_shot(sim, {
            kind = "force_bolt", anim = "player_shot_fly",
            x = f.x, y = f.y - 8.0, vx = 0.0, vy = -240.0, dmg = 1, w = 8.0, h = 8.0, ttl = 2.0,
          })
        end
      end
    end
  end

  -- 3. Bits: fire one 1-damage red bolt ONLY while red weapon is equipped
  if sim.bits >= 1 and f.level >= 1 and f.weapon == "red" then
    for b = 1, sim.bits do
      local bp = sim.bit_positions[b]
      add_player_shot(sim, {
        kind = "bit_bolt",
        anim = "player_shot_fly",
        x = bp.x + 8.0,
        y = bp.y,
        vx = 240.0,
        vy = 0.0,
        dmg = 1,
        w = 8.0,
        h = 6.0,
        ttl = 2.0,
      })
    end
  end

  -- 4. Homing missiles: 2 missiles (3 damage each) on 0.80 s shared cooldown
  if sim.has_missiles and sim.missile_cd <= 1e-6 then
    sim.missile_cd = 0.80
    for s = -1, 1, 2 do
      add_player_shot(sim, {
        kind = "missile",
        anim = "missile_fly",
        x = sim.ship.x,
        y = sim.ship.y + s * 6.0,
        vx = 160.0,
        vy = 0.0,
        dmg = 3,
        w = 16.0,
        h = 8.0,
        ttl = 2.0,
        heading = 0.0,
      })
    end
  end
end

local function release_wave_beam(sim, tier)
  local dmg = WAVE_DAMAGE[tier]
  local h = WAVE_HEIGHT[tier]
  if not dmg or not h then
    return
  end
  add_player_shot(sim, {
    kind = "wave",
    anim = "wave_beam_surge",
    x = sim.ship.x + 18.0,
    y = sim.ship.y,
    vx = 280.0,
    vy = 0.0,
    dmg = dmg,
    w = 32.0,
    h = h,
    scale_y = h / 16.0,
    pierce = true,
    ttl = 2.0,
  })
  request_audio(sim, "wave_fire")
end

---------------------------------------------------------------------------
-- Input command handlers (shared by keyboard and bot)
---------------------------------------------------------------------------

function M.input_move(sim, dx, dy)
  if sim.screen ~= "play" then
    return
  end
  local ndx = tonumber(dx) or 0.0
  local ndy = tonumber(dy) or 0.0
  if ndx == sim.move_dx and ndy == sim.move_dy then
    return
  end
  sim.move_dx = ndx
  sim.move_dy = ndy
  retarget_ship_tweens(sim)
end

function M.input_fire_press(sim)
  if sim.screen ~= "play" or not sim.ship.alive or sim.death_timer > 0.0 then
    return
  end
  if sim.fire_held then
    return
  end
  sim.fire_held = true
  sim.charge_time = 0.0
  sim.charge_tier = 0
  sim.charge_fraction = 0.0
  sim.charge_sound_played = false
  fire_press_weapons(sim)
end

function M.input_fire_release(sim)
  if not sim.fire_held then
    return
  end
  local tier = sim.charge_tier
  local can_fire = (sim.screen == "play" and sim.ship.alive and sim.death_timer <= 0.0)
  cancel_fire_and_charge(sim)
  if can_fire and tier >= 1 then
    release_wave_beam(sim, tier)
  end
end

function M.input_force(sim)
  if sim.screen ~= "play" or not sim.ship.alive or sim.death_timer > 0.0 then
    return
  end
  local f = sim.force
  if not f.acquired or f.level <= 0 then
    return
  end
  if f.state == "attached_front" or f.state == "attached_rear" then
    f.hold_side = (sim.ship.x < M.FORCE_MIDPOINT_X) and "right" or "left"
    local tx = (f.hold_side == "left") and M.FORCE_HOLD_LEFT_X or M.FORCE_HOLD_RIGHT_X
    local ty = clamp(sim.ship.y, M.FORCE_MIN_Y, M.FORCE_MAX_Y)
    f.state = "launching"
    f.target_x = nil
    f.target_y = nil
    retarget_force_tween(sim, M.FORCE_LAUNCH_SPEED)
    local _ = tx, ty
    request_audio(sim, "force_launch")
    emit_force_state(sim)
  elseif f.state == "detached" or f.state == "launching" then
    f.state = "recalling"
    f.tw_x = nil
    f.tw_y = nil
    emit_force_state(sim)
  end
end

function M.input_start(sim)
  if sim.screen == "title" then
    sim.score = 0
    sim.lives = 3
    sim.speed_level = 0
    sim.bits = 0
    sim.has_missiles = false
    sim.reward_ledger = {}
    sim.force.acquired = false
    sim.force.level = 0
    sim.force.state = "unacquired"
    sim.force.weapon = "vulcan"
    request_audio(sim, "ui_select")
    enter_stage_fresh(sim, 1)
    set_screen(sim, "play")
  elseif sim.screen == "stage_clear" then
    request_audio(sim, "ui_select")
    enter_stage_fresh(sim, math.min(10, sim.stage + 1))
    set_screen(sim, "play")
  elseif sim.screen == "game_over" then
    request_audio(sim, "ui_select")
    sim.score = 0
    sim.lives = 3
    sim.reward_ledger = {}
    sim.stage_had_death = true
    apply_death_equipment_reset(sim)
    local start_px = sim.checkpoint_reached and stages.CHECKPOINT_PX or 0.0
    build_stage_attempt(sim, start_px, 2.0)
    local st = stages.get_stage(sim.stage)
    request_audio(sim, st.bgm)
    emit_force_state(sim)
    set_screen(sim, "play")
  elseif sim.screen == "victory" then
    request_audio(sim, "ui_select")
    M.reset_to_title(sim, nil)
  end
end

function M.input_pause(sim)
  if sim.screen == "play" then
    sim.move_dx = 0.0
    sim.move_dy = 0.0
    sim.ship.tw_x = nil
    sim.ship.tw_y = nil
    cancel_fire_and_charge(sim)
    set_screen(sim, "pause")
    return "paused"
  elseif sim.screen == "pause" then
    sim.move_dx = 0.0
    sim.move_dy = 0.0
    sim.ship.tw_x = nil
    sim.ship.tw_y = nil
    cancel_fire_and_charge(sim)
    set_screen(sim, "play")
    return "resumed"
  end
  return nil
end

function M.test_set_stage(sim, stage_num)
  if not sim.test_mode then
    return
  end
  local target = clamp(math.floor(tonumber(stage_num) or 1), 1, 10)
  enter_stage_fresh(sim, target)
  if sim.screen ~= "play" then
    set_screen(sim, "play")
  end
end

---------------------------------------------------------------------------
-- Per-tick simulation stepping (60 Hz)
---------------------------------------------------------------------------

local function find_nearest_missile_target(sim, mx, my)
  local best_x, best_y = nil, nil
  local best_d2 = math.huge
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.hp > 0 then
      local dx = e.x - mx
      local dy = e.y - my
      local d2 = dx * dx + dy * dy
      if d2 < best_d2 then
        best_d2 = d2
        best_x = e.x
        best_y = e.y
      end
    end
  end
  if sim.boss and sim.boss.hp > 0 then
    for i = 1, #sim.boss.parts do
      local p = sim.boss.parts[i]
      if not p.indestructible and p.hp > 0 then
        local dx = p.x - mx
        local dy = p.y - my
        local d2 = dx * dx + dy * dy
        if d2 < best_d2 then
          best_d2 = d2
          best_x = p.x
          best_y = p.y
        end
      end
    end
    local cx = sim.boss.core_x
    local cy = sim.boss.core_y
    local dx = cx - mx
    local dy = cy - my
    local d2 = dx * dx + dy * dy
    if d2 < best_d2 then
      best_x = cx
      best_y = cy
    end
  end
  return best_x, best_y
end

local function step_player_shots(sim, dt)
  local kept = {}
  for i = 1, #sim.player_shots do
    local s = sim.player_shots[i]
    s.age = s.age + dt
    local alive = (s.age <= s.ttl + 1e-6)

    for tid, cd in pairs(s.hit_cds) do
      local rem = cd - dt
      if rem <= 0.0 then
        s.hit_cds[tid] = nil
      else
        s.hit_cds[tid] = rem
      end
    end
    if s.tick_cd > 0.0 then
      s.tick_cd = s.tick_cd - dt
    end

    if alive then
      if s.kind == "missile" then
        s.steer_timer = s.steer_timer - dt
        if s.steer_timer <= 1e-6 or s.tw_x == nil then
          s.steer_timer = 0.05
          local tx, ty = find_nearest_missile_target(sim, s.x, s.y)
          local old_h = s.heading
          local new_h = old_h
          if tx ~= nil then
            local desired = math.atan2(ty - s.y, tx - s.x)
            local diff = (desired - old_h + math.pi) % (2.0 * math.pi) - math.pi
            local max_turn = math.pi * 0.05 -- 180 deg/s over 0.05 s retarget window
            diff = clamp(diff, -max_turn, max_turn)
            new_h = old_h + diff
          end
          s.heading = new_h
          s.vx = math.cos(new_h) * 160.0
          s.vy = math.sin(new_h) * 160.0
          s.tw_x = M.tween_new(s.x, s.x + s.vx * 0.05, 0.05, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
          s.tw_y = M.tween_new(s.y, s.y + s.vy * 0.05, 0.05, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
          s.rot_tw = M.tween_new(old_h, new_h, 0.05, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
        end
        s.x = M.tween_step(s.tw_x, dt)
        s.y = M.tween_step(s.tw_y, dt)
        if s.rot_tw then
          s.heading = M.tween_step(s.rot_tw, dt)
        end
      elseif s.kind == "laser_yellow" then
        local world_x = sim.scroll_px + s.x
        local floor_y, ceil_y = stages.terrain_bounds(sim.stage, world_x)
        if not s.crawling then
          s.y = M.tween_step(s.tw_y, dt)
          if s.vy > 0 and s.y >= (ceil_y - 6.0) then
            s.crawling = true
            s.wall = "top"
            s.y = ceil_y - 6.0
            local rem = math.max(0.01, s.ttl - s.age)
            s.tw_x = M.tween_new(s.x, s.x + s.crawl_dir * 80.0 * rem, rem, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
          elseif s.vy < 0 and s.y <= (floor_y + 6.0) then
            s.crawling = true
            s.wall = "bottom"
            s.y = floor_y + 6.0
            local rem = math.max(0.01, s.ttl - s.age)
            s.tw_x = M.tween_new(s.x, s.x + s.crawl_dir * 80.0 * rem, rem, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
          end
        else
          s.x = M.tween_step(s.tw_x, dt)
          local wx2 = sim.scroll_px + s.x
          local fy2, cy2 = stages.terrain_bounds(sim.stage, wx2)
          s.y = (s.wall == "top") and (cy2 - 6.0) or (fy2 + 6.0)
        end
      elseif s.kind == "laser_blue" then
        local prev_x, prev_y = s.x, s.y
        s.x = M.tween_step(s.tw_x, dt)
        s.y = M.tween_step(s.tw_y, dt)
        local wx = sim.scroll_px + s.x
        if stages.is_solid(sim.stage, wx, s.y) then
          if s.bounces_left > 0 then
            s.bounces_left = s.bounces_left - 1
            local prev_wx = sim.scroll_px + prev_x
            local hit_vert = not stages.is_solid(sim.stage, prev_wx, s.y)
            local hit_horiz = not stages.is_solid(sim.stage, wx, prev_y)
            if hit_vert and not hit_horiz then
              s.vx = -s.vx
              s.x = prev_x
            else
              s.vy = -s.vy
              s.y = prev_y
            end
            s.heading = math.atan2(s.vy, s.vx)
            local rem = math.max(0.01, s.ttl - s.age)
            s.tw_x = M.tween_new(s.x, s.x + s.vx * rem, rem, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
            s.tw_y = M.tween_new(s.y, s.y + s.vy * rem, rem, M.PLAYBACK_ONCE_FORWARD, M.EASING_LINEAR)
          else
            alive = false
          end
        end
      else
        s.x = M.tween_step(s.tw_x, dt)
        local base_y = M.tween_step(s.tw_y, dt)
        if s.helix_tw then
          s.y = base_y + M.tween_step(s.helix_tw, dt)
        else
          s.y = base_y
        end
        -- Wave, vulcan, red lasers stop on solid terrain
        local wx = sim.scroll_px + s.x
        if stages.is_solid(sim.stage, wx, s.y) then
          alive = false
        end
      end

      if s.x < -32.0 or s.x > 352.0 or s.y < 16.0 or s.y > 208.0 then
        alive = false
      end
    end

    if alive then
      kept[#kept + 1] = s
    end
  end
  sim.player_shots = kept
end

local function step_boss(sim, dt)
  local b = sim.boss
  if b == nil then
    return
  end
  local st = stages.get_stage(sim.stage)
  b.clock = b.clock + dt
  M.tween_step(b.orbit_tw, dt)
  M.tween_step(b.core_scale_tw, dt)

  if b.stage == 10 and b.hp <= 150 then
    b.phase = 2
  end

  -- Stage 5 Bellmite sequential shell cell shedding & clearance check
  if b.stage == 5 and not b.shell_cleared then
    if b.clock >= b.next_shed_time then
      b.next_shed_time = b.next_shed_time + 1.5
      for i = 1, #b.parts do
        if b.parts[i].hp > 0 then
          b.parts[i].hp = 0
          break
        end
      end
    end
    local alive_cells = 0
    for i = 1, #b.parts do
      if b.parts[i].hp > 0 then
        alive_cells = alive_cells + 1
      end
    end
    if alive_cells == 0 then
      b.shell_cleared = true
      -- Align clock to start of closed->open cycle cleanly once shell clears
      b.clock = (b.cycle_s - b.expose_s) - 0.10
    end
  end

  local cycle_idx = math.floor(b.clock / b.cycle_s)
  local cycle_pos = b.clock - cycle_idx * b.cycle_s
  local closed_dur = b.cycle_s - b.expose_s

  if cycle_idx ~= b.cycle_index then
    b.cycle_index = cycle_idx
    b.did_cycle_attack = false
    if b.stage == 7 then
      -- Recall surviving Dop clones before next cycle and deploy fresh cycle-indexed clones
      b.parts = {}
      local ys = { 68.0, 90.0, 134.0, 156.0 }
      for i = 1, 4 do
        b.parts[#b.parts + 1] = {
          id = string.format("regent-dop-%d-%d", cycle_idx, i),
          kind = "dop_clone",
          anim = "dop_guard",
          x = b.x - 36.0,
          y = ys[i],
          hw = 10.0,
          hh = 10.0,
          hp = 3,
          indestructible = false,
        }
      end
    end
  end

  -- Telegraph window (>= 0.60 s before any attack emission at cycle_pos = 1.00 s)
  b.tell_active = (cycle_pos >= 0.20 and cycle_pos < 1.00)

  -- Stage 6 Transit Piston retract + telegraphed lane lunge
  if b.stage == 6 then
    if cycle_pos >= 0.25 and cycle_pos < 1.00 then
      b.lunge_offset_x = 12.0 -- visible retract tell
      b.y = (cycle_idx % 2 == 0) and 144.0 or 80.0
    elseif cycle_pos >= 1.00 and cycle_pos < 2.10 then
      local u = math.sin(((cycle_pos - 1.00) / 1.10) * math.pi)
      b.lunge_offset_x = -88.0 * u
    else
      b.lunge_offset_x = 0.0
      b.y = b.base_y
    end
    b.x = b.base_x + b.lunge_offset_x
  end

  b.core_x = b.x + b.core_dx
  b.core_y = b.y + b.core_dy

  if b.stage == 4 then
    local deg = M.tween_eval(b.orbit_tw)
    for i = 1, #b.parts do
      local p = b.parts[i]
      local rad = ((deg + p.angle_offset) * math.pi) / 180.0
      p.x = b.x + math.cos(rad) * p.radius
      p.y = b.y + math.sin(rad) * p.radius
    end
  end

  -- Exposure state
  if b.shell_cleared and cycle_pos >= closed_dur then
    b.exposed = true
  else
    b.exposed = false
  end

  -- Damaging boss attack pattern emitted after >= 0.80 s visible telegraph
  if not b.did_cycle_attack and cycle_pos >= 1.00 then
    b.did_cycle_attack = true
    local spd = st.bullet_px_s
    local angles = { -0.54, 0.54 }
    if b.stage == 5 then
      angles = { -0.78, 0.78 }
    elseif b.stage == 3 or b.stage == 9 then
      angles = { -0.45, -0.22, 0.22, 0.45 }
    elseif b.stage == 8 then
      -- Hatch Warden drops 3 debris spores from marked ceiling lanes
      local xs = { 148.0, 184.0, 220.0 }
      for i = 1, #xs do
        add_enemy_bullet(sim, xs[i], 172.0, -8.0, -spd * 0.85, true)
      end
      angles = {}
    elseif b.stage == 10 and b.phase == 2 then
      angles = { -0.48, -0.24, 0.24, 0.48 }
      local sweep_y = (cycle_idx % 2 == 0) and 148.0 or 76.0
      add_enemy_bullet(sim, b.core_x, sweep_y, -spd * 1.1, 0.0, true)
    end
    for i = 1, #angles do
      local a = math.pi + angles[i]
      add_enemy_bullet(sim, b.core_x, b.core_y, math.cos(a) * spd, math.sin(a) * spd, (i % 2 == 0))
    end
  end
end

local function step_enemies_and_spawns(sim, dt)
  local st = stages.get_stage(sim.stage)

  if not sim.boss_locked then
    sim.scroll_px = M.tween_step(sim.scroll_tw, dt)
    sim.scroll_time = sim.scroll_time + dt

    if not sim.checkpoint_reached and sim.scroll_px >= stages.CHECKPOINT_PX - 1e-6 then
      sim.checkpoint_reached = true
      push_event(sim, "checkpoint_reached", {
        stage = sim.stage,
        scroll_px = 1152,
      })
    end

    -- Guaranteed 12 s carriers (12, 24, 36, 48, 60, 72 s)
    if sim.carrier_slot < 6 and sim.scroll_time >= sim.next_carrier_time - 1e-6 then
      sim.carrier_slot = sim.carrier_slot + 1
      local slot = sim.carrier_slot
      sim.next_carrier_time = (slot + 1) * 12.0
      local drop = stages.CARRIER_DROPS[((slot - 1) % #stages.CARRIER_DROPS) + 1]
      if #sim.enemies >= 8 then
        -- Make room if at cap so guaranteed carrier always arrives on schedule
        table.remove(sim.enemies, 1)
      end
      spawn_enemy_entity(sim, {
        spawn_id = string.format("s%d-carrier-%d", sim.stage, slot),
        kind = "carrier",
        x = 276.0,
        y = 146.0,
        speed_x = 48.0,
        drop_kind = drop,
        fire_delay = 999.0,
      })
    end

    -- Ordinary formations on stage delta_spawn schedule
    if sim.scroll_time >= sim.next_formation_time - 1e-6 and sim.scroll_px < (stages.STAGE_LENGTH_PX - 72.0) then
      sim.next_formation_time = sim.next_formation_time + st.spawn_s
      schedule_formation(sim)
    end

    -- Flush due formation spawns while respecting <= 8 simultaneous ordinary enemies cap
    local rem_pending = {}
    local reserve = ((sim.next_carrier_time - sim.scroll_time) <= 1.2 and sim.carrier_slot < 6) and 1 or 0
    for i = 1, #sim.pending_spawns do
      local item = sim.pending_spawns[i]
      if sim.scroll_time >= item.due_time - 1e-6 then
        if #sim.enemies < (8 - reserve) then
          spawn_enemy_entity(sim, item.spec)
        else
          item.due_time = sim.scroll_time + 0.25
          rem_pending[#rem_pending + 1] = item
        end
      else
        rem_pending[#rem_pending + 1] = item
      end
    end
    sim.pending_spawns = rem_pending

    if sim.scroll_px >= stages.STAGE_LENGTH_PX - 1e-6 then
      sim.scroll_px = stages.STAGE_LENGTH_PX
      sim.boss_locked = true
      sim.pending_spawns = {}
      sim.enemies = {}
      sim.enemy_bullets = {}
      spawn_stage_boss(sim)
    end
  end

  -- Step active ordinary enemies
  local kept = {}
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.hp > 0 then
      e.x = M.tween_step(e.tw_x, dt)
      if e.wall_side ~= nil then
        local wx = sim.scroll_px + e.x
        local fy, cy = stages.terrain_bounds(sim.stage, wx)
        if e.kind == "turret" then
          e.y = (e.wall_side == "bottom") and (fy + 10.0) or (cy - 10.0)
        else
          e.y = (e.wall_side == "bottom") and (fy + 8.0) or (cy - 8.0)
        end
      elseif e.tw_y ~= nil then
        e.y = M.tween_step(e.tw_y, dt)
      end

      if (e.kind == "fighter" or e.kind == "turret" or e.kind == "dop") and e.x > 140.0 and e.x < 308.0 then
        e.fire_timer = e.fire_timer - dt
        if e.fire_timer <= 0.0 then
          e.fire_timer = 2.2
          local sign = (i % 2 == 0) and 1.0 or -1.0
          fire_aimed_enemy_bullet(sim, e.x, e.y, st.bullet_px_s, false, sign)
        end
      end

      if e.x >= -22.0 then
        kept[#kept + 1] = e
      end
    end
  end
  sim.enemies = kept
end

local function step_enemy_bullets_and_pickups(sim, dt)
  local kept_b = {}
  for i = 1, #sim.enemy_bullets do
    local b = sim.enemy_bullets[i]
    b.ttl = b.ttl - dt
    b.x = M.tween_step(b.tw_x, dt)
    b.y = M.tween_step(b.tw_y, dt)
    local alive = (b.ttl > 0.0 and b.x >= -16.0 and b.x <= 336.0 and b.y >= 24.0 and b.y <= 200.0)
    if alive and not sim.boss_locked then
      local wx = sim.scroll_px + b.x
      if stages.is_solid(sim.stage, wx, b.y) then
        alive = false
      end
    end
    -- Indestructible Force pod and Bits block enemy bullets
    if alive and sim.force.acquired and sim.force.level > 0 then
      if aabb_overlap(b.x, b.y, b.hw, b.hh, sim.force.x, sim.force.y, 8.0, 8.0) then
        alive = false
      end
    end
    if alive and sim.bits >= 1 then
      for idx = 1, sim.bits do
        local bp = sim.bit_positions[idx]
        if aabb_overlap(b.x, b.y, b.hw, b.hh, bp.x, bp.y, 8.0, 8.0) then
          alive = false
          break
        end
      end
    end
    if alive then
      kept_b[#kept_b + 1] = b
    end
  end
  sim.enemy_bullets = kept_b

  local kept_p = {}
  for i = 1, #sim.pickups do
    local p = sim.pickups[i]
    p.x = M.tween_step(p.tw_x, dt)
    local collected = false
    if sim.ship.alive and aabb_overlap(sim.ship.x, sim.ship.y, M.SHIP_HALF_W + 4.0, M.SHIP_HALF_H + 6.0, p.x, p.y, p.hw, p.hh) then
      M.collect_powerup(sim, p.kind, p.spawn_id)
      collected = true
    end
    if not collected and p.x >= -20.0 then
      kept_p[#kept_p + 1] = p
    end
  end
  sim.pickups = kept_p

  local kept_fx = {}
  for i = 1, #sim.explosions do
    local fx = sim.explosions[i]
    fx.ttl = fx.ttl - dt
    if fx.ttl > 0.0 then
      kept_fx[#kept_fx + 1] = fx
    end
  end
  sim.explosions = kept_fx
end

local function resolve_combat(sim, dt)
  -- Tick Force ram cooldowns
  local f = sim.force
  for eid, cd in pairs(f.ram_cds) do
    local rem = cd - dt
    if rem <= 0.0 then
      f.ram_cds[eid] = nil
    else
      f.ram_cds[eid] = rem
    end
  end

  -- 1. Force ram damage against ordinary enemies (4 dmg per 0.25 s; bits deal 0 ram damage)
  if f.acquired and f.level > 0 then
    for i = 1, #sim.enemies do
      local e = sim.enemies[i]
      if e.hp > 0 and f.ram_cds[e.spawn_id] == nil then
        if aabb_overlap(f.x, f.y, M.FORCE_RADIUS + 2.0, M.FORCE_RADIUS + 2.0, e.x, e.y, e.hw, e.hh) then
          f.ram_cds[e.spawn_id] = 0.25
          e.hp = e.hp - 4
          if e.hp <= 0 then
            spawn_explosion(sim, e.x, e.y, false)
            request_audio(sim, "explosion_small")
            if e.drop_kind then
              spawn_pickup(sim, e.x, e.y, e.drop_kind, e.spawn_id .. "-drop")
            end
            M.award_enemy_kill(sim, e.spawn_id, e.kind, sim.stage, true)
          else
            request_audio(sim, "enemy_hit")
          end
        end
      end
    end
  end

  -- 2. Player shots vs ordinary enemies, boss parts, and exposed boss core
  local kept_shots = {}
  for s_idx = 1, #sim.player_shots do
    local s = sim.player_shots[s_idx]
    local consumed = false

    -- Check ordinary enemies
    for e_idx = 1, #sim.enemies do
      local e = sim.enemies[e_idx]
      if e.hp > 0 and not consumed then
        local can_hit = true
        if s.kind == "wave" and s.hit_ids[e.spawn_id] then
          can_hit = false
        elseif s.kind == "laser_blue" and s.hit_cds[e.spawn_id] ~= nil then
          can_hit = false
        elseif s.kind == "laser_yellow" and s.hit_cds[e.spawn_id] ~= nil then
          can_hit = false
        end
        -- Dop front-core hemisphere rule: vulnerable on front (left-facing) side
        if can_hit and e.kind == "dop" and not s.pierce and s.x > (e.x + 8.0) then
          can_hit = false
        end

        if can_hit and aabb_overlap(s.x, s.y, s.hw, s.hh, e.x, e.y, e.hw, e.hh) then
          e.hp = e.hp - s.dmg
          if s.kind == "wave" then
            s.hit_ids[e.spawn_id] = true
          elseif s.kind == "laser_blue" then
            s.hit_cds[e.spawn_id] = 0.10
          elseif s.kind == "laser_yellow" then
            s.hit_cds[e.spawn_id] = 0.20
          else
            consumed = true
          end

          if e.hp <= 0 then
            spawn_explosion(sim, e.x, e.y, false)
            request_audio(sim, "explosion_small")
            if e.drop_kind then
              spawn_pickup(sim, e.x, e.y, e.drop_kind, e.spawn_id .. "-drop")
            end
            M.award_enemy_kill(sim, e.spawn_id, e.kind, sim.stage, true)
          else
            request_audio(sim, "enemy_hit")
          end
        end
      end
    end

    -- Check active boss & destructible boss parts
    local b = sim.boss
    if b ~= nil and b.hp > 0 and not consumed then
      for p_idx = 1, #b.parts do
        local p = b.parts[p_idx]
        if not p.indestructible and p.hp > 0 and not consumed then
          local can_hit_p = not (s.kind == "wave" and s.hit_ids[p.id])
            and not (s.hit_cds[p.id] ~= nil)
          if can_hit_p and aabb_overlap(s.x, s.y, s.hw, s.hh, p.x, p.y, p.hw or 8.0, p.hh or 8.0) then
            p.hp = p.hp - s.dmg
            if s.kind == "wave" then
              s.hit_ids[p.id] = true
            elseif s.kind == "laser_blue" then
              s.hit_cds[p.id] = 0.10
            elseif s.kind == "laser_yellow" then
              s.hit_cds[p.id] = 0.20
            else
              consumed = true
            end
            if p.hp <= 0 then
              spawn_explosion(sim, p.x, p.y, false)
              request_audio(sim, "explosion_small")
            else
              request_audio(sim, "enemy_hit")
            end
          end
        end
      end

      -- Boss core: accepts player attacks ONLY while exposed
      if not consumed then
        local core_hh = 18.0
        if b.stage == 1 then
          core_hh = 11.0
        elseif b.stage == 5 then
          core_hh = 38.0
        elseif b.stage == 10 then
          core_hh = 36.0
        end
        local core_hit = aabb_overlap(s.x, s.y, s.hw, s.hh, b.core_x, b.core_y, 12.0, core_hh)
        if core_hit then
          if b.exposed then
            local cid = "boss-core"
            local can_hit_c = not (s.kind == "wave" and s.hit_ids[cid])
              and not (s.hit_cds[cid] ~= nil)
            if can_hit_c then
              b.hp = math.max(0, b.hp - s.dmg)
              if s.kind == "wave" then
                s.hit_ids[cid] = true
              elseif s.kind == "laser_blue" then
                s.hit_cds[cid] = 0.10
              elseif s.kind == "laser_yellow" then
                s.hit_cds[cid] = 0.20
              else
                consumed = true
              end
              request_audio(sim, "enemy_hit")
              if b.hp <= 0 then
                M.defeat_boss(sim, sim.stage)
                b = nil
              end
            end
          else
            -- Closed armour absorbs non-piercing shots for 0 damage
            if not s.pierce then
              consumed = true
            end
          end
        end
      end
    end

    if not consumed then
      kept_shots[#kept_shots + 1] = s
    end
  end
  sim.player_shots = kept_shots

  -- 3. Lethal hazards vs Lance (terrain, enemy bullets, ordinary enemies, boss body)
  if sim.screen == "play" and sim.ship.alive and sim.invuln_timer <= 0.0 and sim.death_timer <= 0.0 then
    local sx, sy = sim.ship.x, sim.ship.y
    local wx = sim.scroll_px + sx
    if not sim.boss_locked and (stages.is_solid(sim.stage, wx, sy + M.SHIP_HALF_H) or stages.is_solid(sim.stage, wx, sy - M.SHIP_HALF_H)) then
      M.trigger_player_hit(sim, "terrain")
      return
    end
    for i = 1, #sim.enemy_bullets do
      local eb = sim.enemy_bullets[i]
      if aabb_overlap(sx, sy, M.SHIP_HALF_W, M.SHIP_HALF_H, eb.x, eb.y, eb.hw, eb.hh) then
        M.trigger_player_hit(sim, eb.id)
        return
      end
    end
    for i = 1, #sim.enemies do
      local e = sim.enemies[i]
      if e.hp > 0 and aabb_overlap(sx, sy, M.SHIP_HALF_W, M.SHIP_HALF_H, e.x, e.y, e.hw - 2.0, e.hh - 2.0) then
        M.trigger_player_hit(sim, e.spawn_id)
        return
      end
    end
    if sim.boss and sim.boss.hp > 0 then
      local b = sim.boss
      if b.stage == 3 then
        -- Iron Vesper allows flying past upper/lower clearance to rear bay
        if aabb_overlap(sx, sy, M.SHIP_HALF_W, M.SHIP_HALF_H, b.x - 16.0, b.y, 28.0, 24.0) then
          M.trigger_player_hit(sim, b.id)
          return
        end
      else
        if aabb_overlap(sx, sy, M.SHIP_HALF_W, M.SHIP_HALF_H, b.x + 8.0, b.y, 20.0, 22.0) then
          M.trigger_player_hit(sim, b.id)
          return
        end
      end
    end
  end
end

local function step_ship_force_and_charge(sim, dt)
  -- Step starfield visually during active play
  for i = 1, #sim.stars do
    local st = sim.stars[i]
    st.x = M.tween_step(st.tw, dt)
  end

  if sim.invuln_timer > 0.0 then
    sim.invuln_timer = math.max(0.0, sim.invuln_timer - dt)
  end
  if sim.missile_cd > 0.0 then
    sim.missile_cd = math.max(0.0, sim.missile_cd - dt)
  end
  if sim.aimed_cd > 0.0 then
    sim.aimed_cd = math.max(0.0, sim.aimed_cd - dt)
  end

  if not sim.ship.alive then
    sim.death_timer = sim.death_timer - dt
    if sim.death_timer <= 1e-6 then
      sim.death_timer = 0.0
      if sim.lives <= 0 then
        push_event(sim, "game_over", {
          stage = sim.stage,
          score = sim.score,
        })
        request_audio(sim, "jingle_game_over")
        set_screen(sim, "game_over")
      else
        apply_death_equipment_reset(sim)
        local start_px = sim.checkpoint_reached and stages.CHECKPOINT_PX or 0.0
        build_stage_attempt(sim, start_px, 2.0)
        local st = stages.get_stage(sim.stage)
        request_audio(sim, st.bgm)
        emit_force_state(sim)
      end
    end
    return
  end

  -- Ship movement via explicit clamped linear tweens
  if sim.ship.tw_x ~= nil then
    sim.ship.x = clamp(M.tween_step(sim.ship.tw_x, dt), M.SHIP_MIN_X, M.SHIP_MAX_X)
    if sim.ship.tw_x.done then
      sim.ship.tw_x = nil
    end
  end
  if sim.ship.tw_y ~= nil then
    sim.ship.y = clamp(M.tween_step(sim.ship.tw_y, dt), M.SHIP_MIN_Y, M.SHIP_MAX_Y)
    if sim.ship.tw_y.done then
      sim.ship.tw_y = nil
    end
  end

  -- Force movement & state machine
  local f = sim.force
  if f.acquired and f.level > 0 then
    if f.state == "attached_front" or f.state == "attached_rear" then
      sync_attached_support(sim)
    elseif f.state == "launching" then
      update_force_hold_side(sim)
      retarget_force_tween(sim, M.FORCE_LAUNCH_SPEED)
      f.x = M.tween_step(f.tw_x, dt)
      f.y = clamp(M.tween_step(f.tw_y, dt), M.FORCE_MIN_Y, M.FORCE_MAX_Y)
      if f.tw_x.done and f.tw_y.done then
        f.state = "detached"
        f.target_x = nil
        f.target_y = nil
        emit_force_state(sim)
      end
    elseif f.state == "detached" then
      update_force_hold_side(sim)
      retarget_force_tween(sim, M.FORCE_RECALL_SPEED)
      f.x = M.tween_step(f.tw_x, dt)
      f.y = clamp(M.tween_step(f.tw_y, dt), M.FORCE_MIN_Y, M.FORCE_MAX_Y)
    elseif f.state == "recalling" then
      local dx = sim.ship.x - f.x
      local dy = sim.ship.y - f.y
      local dist = math.sqrt(dx * dx + dy * dy)
      local step_d = M.FORCE_RECALL_SPEED * dt
      if dist <= M.FORCE_ATTACH_OFFSET or dist <= step_d then
        f.state = (f.x < sim.ship.x) and "attached_rear" or "attached_front"
        f.tw_x = nil
        f.tw_y = nil
        sync_attached_support(sim)
        request_audio(sim, "force_attach")
        emit_force_state(sim)
      else
        f.x = f.x + (dx / dist) * step_d
        f.y = f.y + (dy / dist) * step_d
      end
    end
  end
  sim.bit_positions[1].x = sim.ship.x
  sim.bit_positions[1].y = sim.ship.y + 20.0
  sim.bit_positions[2].x = sim.ship.x
  sim.bit_positions[2].y = sim.ship.y - 20.0

  -- Continuous Wave Cannon hold charge
  if sim.fire_held then
    sim.charge_time = sim.charge_time + dt
    if sim.charge_time >= 0.30 - 1e-6 then
      if not sim.charge_sound_played then
        sim.charge_sound_played = true
        request_audio(sim, "charge_rise")
      end
      local new_tier = 0
      if sim.charge_time >= 1.80 - 1e-6 then
        new_tier = 3
      elseif sim.charge_time >= 1.10 - 1e-6 then
        new_tier = 2
      elseif sim.charge_time >= 0.60 - 1e-6 then
        new_tier = 1
      end
      local new_frac = clamp(sim.charge_time / 1.80, 0.0, 1.0)
      if new_tier ~= sim.charge_tier or math.abs(new_frac - sim.charge_fraction) >= 0.04 then
        sim.charge_tier = new_tier
        sim.charge_fraction = new_frac
        emit_wave_charge(sim, new_tier, new_frac)
      end
    end
  end
end

function M.step_tick(sim)
  sim.tick = sim.tick + 1
  if sim.screen ~= "play" then
    -- Pause and non-play screens freeze gameplay simulation completely
    return
  end
  local dt = M.DT
  step_ship_force_and_charge(sim, dt)
  if sim.screen ~= "play" then
    return
  end
  if sim.ship.alive then
    step_enemies_and_spawns(sim, dt)
    step_boss(sim, dt)
    step_player_shots(sim, dt)
    step_enemy_bullets_and_pickups(sim, dt)
    resolve_combat(sim, dt)
  end
end

function M.step_ticks(sim, count)
  local n = math.max(0, math.floor(tonumber(count) or 0))
  for _ = 1, n do
    M.step_tick(sim)
  end
end

function M.build_spawn_report(sim)
  local enemies = {}
  for i = 1, #sim.enemies do
    local e = sim.enemies[i]
    if e.hp > 0 then
      enemies[#enemies + 1] = {
        spawn_id = e.spawn_id,
        kind = e.kind,
        x = e.x,
        y = e.y,
        hp = e.hp,
      }
    end
  end
  local boss_info = nil
  if sim.boss ~= nil and sim.boss.hp > 0 then
    boss_info = {
      hp = sim.boss.hp,
      exposed = (sim.boss.exposed == true),
    }
  end
  return {
    scroll_px = sim.scroll_px,
    enemies = enemies,
    hostile_bullets = #sim.enemy_bullets,
    boss = boss_info,
    force = {
      state = sim.force.level > 0 and sim.force.state or "unacquired",
      level = sim.force.level,
      weapon = sim.force.weapon,
    },
    score = sim.score,
    lives = sim.lives,
    screen = sim.screen,
  }
end

return M
