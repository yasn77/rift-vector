-- main/stages.lua -- Deterministic 10-stage schedule, terrain geometry and
-- enemy formation templates for Rift Vector. Pure Lua 5.1, read-only helpers.

local M = {}

M.SCROLL_SPEED = 24.0
M.STAGE_LENGTH_PX = 1920.0
M.CHECKPOINT_PX = 1152.0
M.PLAYFIELD_MIN_Y = 24.0
M.PLAYFIELD_MAX_Y = 200.0
M.BASE_FLOOR_Y = 40.0
M.BASE_CEIL_Y = 184.0
M.TILE_SIZE = 16
M.TILE_COLS = 140
M.TILE_ROWS = 11

M.CARRIER_DROPS = { "red", "blue", "bit", "yellow", "missile", "speed" }

M.ENEMY_STATS = {
  drone = { hp = 1, points = 100, w = 16, h = 16, anim = "drone_fly" },
  fighter = { hp = 2, points = 200, w = 24, h = 16, anim = "fighter_fly" },
  carrier = { hp = 2, points = 500, w = 24, h = 16, anim = "carrier_hop" },
  turret = { hp = 4, points = 300, w = 24, h = 24, anim = "turret_aim" },
  worm_segment = { hp = 2, points = 150, w = 16, h = 16, anim = "worm_segment_writhe" },
  crawler = { hp = 3, points = 200, w = 24, h = 16, anim = "crawler_crawl" },
  mine = { hp = 1, points = 50, w = 16, h = 16, anim = "mine_arm" },
  dop = { hp = 3, points = 250, w = 24, h = 24, anim = "dop_guard" },
}

M.STAGES = {
  {
    stage = 1,
    name = "Breach Wake",
    tileset = "metal",
    bgm = "bgm_stage_a",
    spawn_s = 2.40,
    bullet_px_s = 36.0,
    boss_id = "boss_01_ribmaw",
    boss_anim = "boss_01_ribmaw_attack",
    boss_name = "Ribmaw",
    boss_hp = 120,
    expose_s = 2.5,
    cycle_s = 6.0,
    boss_x = 224.0,
    boss_y = 112.0,
    core_dx = -24.0,
    core_dy = 0.0,
    mix = { "drone", "fighter", "drone", "turret" },
  },
  {
    stage = 2,
    name = "Living Throat",
    tileset = "flesh",
    bgm = "bgm_stage_b",
    spawn_s = 2.30,
    bullet_px_s = 39.0,
    boss_id = "boss_02_oculocyst",
    boss_anim = "boss_02_oculocyst_attack",
    boss_name = "Oculocyst",
    boss_hp = 140,
    expose_s = 2.4,
    cycle_s = 6.0,
    boss_x = 256.0,
    boss_y = 112.0,
    core_dx = -24.0,
    core_dy = 0.0,
    mix = { "drone", "worm_segment", "crawler", "drone" },
  },
  {
    stage = 3,
    name = "Vesper Broadside",
    tileset = "metal",
    bgm = "bgm_stage_c",
    spawn_s = 2.20,
    bullet_px_s = 42.0,
    boss_id = "boss_03_iron_vesper",
    boss_anim = "boss_03_iron_vesper_attack",
    boss_name = "Iron Vesper",
    boss_hp = 160,
    expose_s = 2.3,
    cycle_s = 6.0,
    boss_x = 224.0,
    boss_y = 112.0,
    core_dx = 24.0,
    core_dy = 0.0,
    mix = { "turret", "mine", "fighter", "turret" },
  },
  {
    stage = 4,
    name = "Broken Compiler",
    tileset = "ruins",
    bgm = "bgm_stage_a",
    spawn_s = 2.10,
    bullet_px_s = 45.0,
    boss_id = "boss_04_trifold",
    boss_anim = "boss_04_trifold_attack",
    boss_name = "Trifold Compiler",
    boss_hp = 180,
    expose_s = 2.2,
    cycle_s = 6.0,
    boss_x = 248.0,
    boss_y = 112.0,
    core_dx = 0.0,
    core_dy = 0.0,
    mix = { "fighter", "crawler", "drone", "fighter" },
  },
  {
    stage = 5,
    name = "Bell Nursery",
    tileset = "flesh",
    bgm = "bgm_stage_b",
    spawn_s = 2.00,
    bullet_px_s = 48.0,
    boss_id = "boss_05_bellmite",
    boss_anim = "boss_05_bellmite_attack",
    boss_name = "Bellmite Matron",
    boss_hp = 200,
    expose_s = 2.2,
    cycle_s = 6.0,
    boss_x = 204.0,
    boss_y = 112.0,
    core_dx = -24.0,
    core_dy = 0.0,
    mix = { "mine", "worm_segment", "drone", "mine" },
  },
  {
    stage = 6,
    name = "Transit Artery",
    tileset = "metal",
    bgm = "bgm_stage_c",
    spawn_s = 1.90,
    bullet_px_s = 51.0,
    boss_id = "boss_06_piston_worm",
    boss_anim = "boss_06_piston_worm_attack",
    boss_name = "Transit Piston",
    boss_hp = 220,
    expose_s = 2.1,
    cycle_s = 6.0,
    boss_x = 252.0,
    boss_y = 112.0,
    core_dx = -24.0,
    core_dy = 0.0,
    mix = { "crawler", "turret", "worm_segment", "crawler" },
  },
  {
    stage = 7,
    name = "Mirror Brood",
    tileset = "ruins",
    bgm = "bgm_stage_a",
    spawn_s = 1.80,
    bullet_px_s = 54.0,
    boss_id = "boss_07_dop_regent",
    boss_anim = "boss_07_dop_regent_attack",
    boss_name = "Dop Regent",
    boss_hp = 240,
    expose_s = 2.0,
    cycle_s = 6.0,
    boss_x = 256.0,
    boss_y = 112.0,
    core_dx = -16.0,
    core_dy = 0.0,
    mix = { "dop", "fighter", "drone", "dop" },
  },
  {
    stage = 8,
    name = "Falling Cathedral",
    tileset = "ruins",
    bgm = "bgm_stage_b",
    spawn_s = 1.70,
    bullet_px_s = 57.0,
    boss_id = "boss_08_hatch_warden",
    boss_anim = "boss_08_hatch_warden_attack",
    boss_name = "Hatch Warden",
    boss_hp = 260,
    expose_s = 1.9,
    cycle_s = 6.0,
    boss_x = 244.0,
    boss_y = 148.0,
    core_dx = -8.0,
    core_dy = -16.0,
    mix = { "turret", "mine", "crawler", "mine" },
  },
  {
    stage = 9,
    name = "Citadel Heart",
    tileset = "core",
    bgm = "bgm_stage_c",
    spawn_s = 1.60,
    bullet_px_s = 60.0,
    boss_id = "boss_09_guarded_core",
    boss_anim = "boss_09_guarded_core_attack",
    boss_name = "Citadel Heart",
    boss_hp = 280,
    expose_s = 1.8,
    cycle_s = 6.0,
    boss_x = 252.0,
    boss_y = 112.0,
    core_dx = -16.0,
    core_dy = 0.0,
    mix = { "dop", "worm_segment", "turret", "dop" },
  },
  {
    stage = 10,
    name = "Rift Sovereign",
    tileset = "core",
    bgm = "bgm_stage_c",
    spawn_s = 1.50,
    bullet_px_s = 63.0,
    boss_id = "boss_10_overmind",
    boss_anim = "boss_10_overmind_attack",
    boss_name = "Vorn Overmind",
    boss_hp = 300,
    expose_s = 1.8,
    cycle_s = 6.0,
    boss_x = 228.0,
    boss_y = 112.0,
    core_dx = -28.0,
    core_dy = 0.0,
    mix = { "fighter", "dop", "mine", "fighter" },
  },
}

function M.get_stage(stage_num)
  local idx = math.max(1, math.min(10, math.floor(stage_num or 1)))
  return M.STAGES[idx]
end

-- Deterministic column intrusion check (1-based col in 1..140).
-- Keeps launch region (cols 1..14) and boss-lock arena (cols 113..140) clear,
-- and always leaves >= 112 px (>= 64 px required) central clear vertical passage.
function M.col_intrusions(stage_num, col)
  if col < 15 or col > 112 then
    return false, false
  end
  local s = math.max(1, math.min(10, math.floor(stage_num or 1)))
  local period = 14 - math.floor(s / 3)
  local phase = (col + s * 3) % period
  local has_bottom = (phase == 1 or phase == 2)
  local has_top = (phase == math.floor(period / 2) or phase == math.floor(period / 2) + 1)
  if s == 1 then
    -- Breach Wake: outer dock floor structures with wide clear upper sky for tutorial carrier
    has_top = false
  elseif s == 3 then
    -- Vesper Broadside: alternating battleship deck superstructures on bottom, clear sky
    has_top = (phase == 7)
  elseif s == 8 then
    -- Falling Cathedral: vaulted ceiling buttresses
    has_top = (phase == 1 or phase == 2 or phase == 3)
    has_bottom = (phase == 8)
  end
  return has_bottom, has_top
end

function M.terrain_bounds(stage_num, world_x)
  local col = math.floor((world_x or 0) / M.TILE_SIZE) + 1
  local has_bot, has_top = M.col_intrusions(stage_num, col)
  local floor_y = has_bot and (M.BASE_FLOOR_Y + M.TILE_SIZE) or M.BASE_FLOOR_Y
  local ceil_y = has_top and (M.BASE_CEIL_Y - M.TILE_SIZE) or M.BASE_CEIL_Y
  return floor_y, ceil_y
end

function M.is_solid(stage_num, world_x, y)
  if y < M.PLAYFIELD_MIN_Y or y > M.PLAYFIELD_MAX_Y then
    return true
  end
  local floor_y, ceil_y = M.terrain_bounds(stage_num, world_x)
  return (y <= floor_y) or (y >= ceil_y)
end

-- Returns 1-based tile index (1..8) for (col 1..140, row 1..11), or 0 for empty space.
-- Strip tile order per design.md:
-- 1=plate/body, 2=pipe/rib, 3=vent/sac, 4=cable/vein, 5=upper lip, 6=lower lip, 7=inner corner, 8=endcap
function M.tile_at(stage_num, col, row)
  local has_bot, has_top = M.col_intrusions(stage_num, col)
  local prev_bot, prev_top = M.col_intrusions(stage_num, col - 1)
  local next_bot, next_top = M.col_intrusions(stage_num, col + 1)

  if row == 1 then
    if has_bot then
      return ((col + stage_num) % 4) + 1
    end
    local variant = (col + stage_num) % 6
    if variant == 0 then return 2 end
    if variant == 3 then return 3 end
    return 5 -- upper lip facing playfield
  elseif row == 2 then
    if not has_bot then
      return 0
    end
    if not prev_bot or not next_bot then
      return 8 -- endcap
    end
    return 7 -- inner corner / raised structure
  elseif row == 11 then
    if has_top then
      return ((col + stage_num + 1) % 4) + 1
    end
    local variant = (col + stage_num + 2) % 6
    if variant == 0 then return 4 end
    if variant == 3 then return 2 end
    return 6 -- lower lip facing playfield
  elseif row == 10 then
    if not has_top then
      return 0
    end
    if not prev_top or not next_top then
      return 8 -- endcap
    end
    return 7
  end
  return 0
end

return M
