-- test/gdd_data.lua -- frozen specification data from assets/gdd/game.json
-- and design/design.md. Pure Lua 5.1, read-only tables.

local G = {}

G.TITLE = "Rift Vector"
G.SLUG = "rift-vector"
G.PROFILE = "2d_pixel"
G.LOGICAL_W = 320
G.LOGICAL_H = 200
G.WINDOW_W = 960
G.WINDOW_H = 600

G.PALETTE_HEX = {
  "#000000", "#0B0E1A", "#F2F2F2", "#8A9099",
  "#4C525B", "#3FA34D", "#C8372D", "#E04838",
  "#8E2318", "#F2A03D", "#C86A1E", "#3E6EE0",
  "#6FC3F7", "#E8D040", "#D888A0", "#8E4A5E",
}

G.ART_DIRECTION = {
  cohesion_floor = 70.0,
  allow_primitive_placeholders = false,
  palette_count = 14,
}

G.PLATFORMS = {
  {
    platform = "x86_64-linux",
    backends = { "opengl", "vulkan" },
    appmanifest_path = "main/game.appmanifest",
    config_manifest_path = "/main/game.appmanifest",
  },
  {
    platform = "wasm-web",
    backends = { "webgl" },
    appmanifest_path = nil,
  },
}

G.SCREENS = {
  "title", "play", "pause", "stage_clear", "game_over", "victory",
}

G.INPUT_ACTIONS = {
  "move_up", "move_down", "move_left", "move_right",
  "fire", "force", "start", "pause",
}

G.MESSAGE_IDS = {
  "input_move", "input_fire_press", "input_fire_release", "input_force",
  "input_start", "input_pause", "player_hit", "enemy_killed",
  "score_add", "powerup_collected", "stage_clear", "boss_defeated",
  "game_over", "wave_charge", "force_state", "checkpoint_reached",
  "audio_request", "screen_changed", "test_mode", "test_advance",
  "test_spawn_report", "test_set_stage",
}

G.SPRITES = {
  "ship", "force_lv1", "force_lv2", "force_lv3", "bit",
  "player_shot", "wave_beam", "laser_red", "laser_blue", "laser_yellow",
  "missile", "enemy_shot", "enemy_orb",
  "drone", "carrier", "fighter", "worm_segment", "turret", "crawler", "mine", "dop",
  "crystal_red", "crystal_blue", "crystal_yellow",
  "pickup_bit", "pickup_speed", "pickup_missile",
  "explosion_small", "explosion_big",
  "boss_01_ribmaw", "boss_02_oculocyst", "boss_03_iron_vesper", "boss_04_trifold",
  "boss_05_bellmite", "boss_06_piston_worm", "boss_07_dop_regent",
  "boss_08_hatch_warden", "boss_09_guarded_core", "boss_10_overmind",
  "tileset_metal", "tileset_flesh", "tileset_ruins", "tileset_core",
  "star_spark", "hud_panel", "beam_gauge", "life_icon", "boss_core",
}

G.AUDIO_CUES = {
  "shot", "wave_fire", "charge_rise", "enemy_hit",
  "explosion_small", "explosion_big", "player_die",
  "pickup_crystal", "pickup_power", "force_attach", "force_launch",
  "boss_alert", "ui_select",
  "bgm_title", "bgm_stage_a", "bgm_stage_b", "bgm_stage_c",
  "bgm_boss", "bgm_final_boss",
  "jingle_stage_clear", "jingle_game_over", "jingle_victory",
}

G.KILL_POINTS = {
  drone = 100,
  fighter = 200,
  carrier = 500,
  turret = 300,
  worm_segment = 150,
  mine = 50,
  dop = 250,
  crawler = 200,
}

G.CARRIER_DROPS = { "red", "blue", "bit", "yellow", "missile", "speed" }

G.STAGES = {
  { stage = 1, name = "Breach Wake", boss_id = "boss_01_ribmaw", boss_name = "Ribmaw", tileset = "metal", spawn_s = 2.40, bullet_px_s = 36, boss_hp = 120, expose_s = 2.5, cycle_s = 6.0, bgm = "bgm_stage_a" },
  { stage = 2, name = "Living Throat", boss_id = "boss_02_oculocyst", boss_name = "Oculocyst", tileset = "flesh", spawn_s = 2.30, bullet_px_s = 39, boss_hp = 140, expose_s = 2.4, cycle_s = 6.0, bgm = "bgm_stage_b" },
  { stage = 3, name = "Vesper Broadside", boss_id = "boss_03_iron_vesper", boss_name = "Iron Vesper", tileset = "metal", spawn_s = 2.20, bullet_px_s = 42, boss_hp = 160, expose_s = 2.3, cycle_s = 6.0, bgm = "bgm_stage_c" },
  { stage = 4, name = "Broken Compiler", boss_id = "boss_04_trifold", boss_name = "Trifold Compiler", tileset = "ruins", spawn_s = 2.10, bullet_px_s = 45, boss_hp = 180, expose_s = 2.2, cycle_s = 6.0, bgm = "bgm_stage_a" },
  { stage = 5, name = "Bell Nursery", boss_id = "boss_05_bellmite", boss_name = "Bellmite Matron", tileset = "flesh", spawn_s = 2.00, bullet_px_s = 48, boss_hp = 200, expose_s = 2.2, cycle_s = 6.0, bgm = "bgm_stage_b" },
  { stage = 6, name = "Transit Artery", boss_id = "boss_06_piston_worm", boss_name = "Transit Piston", tileset = "metal", spawn_s = 1.90, bullet_px_s = 51, boss_hp = 220, expose_s = 2.1, cycle_s = 6.0, bgm = "bgm_stage_c" },
  { stage = 7, name = "Mirror Brood", boss_id = "boss_07_dop_regent", boss_name = "Dop Regent", tileset = "ruins", spawn_s = 1.80, bullet_px_s = 54, boss_hp = 240, expose_s = 2.0, cycle_s = 6.0, bgm = "bgm_stage_a" },
  { stage = 8, name = "Falling Cathedral", boss_id = "boss_08_hatch_warden", boss_name = "Hatch Warden", tileset = "ruins", spawn_s = 1.70, bullet_px_s = 57, boss_hp = 260, expose_s = 1.9, cycle_s = 6.0, bgm = "bgm_stage_b" },
  { stage = 9, name = "Citadel Heart", boss_id = "boss_09_guarded_core", boss_name = "Citadel Heart", tileset = "core", spawn_s = 1.60, bullet_px_s = 60, boss_hp = 280, expose_s = 1.8, cycle_s = 6.0, bgm = "bgm_stage_c" },
  { stage = 10, name = "Rift Sovereign", boss_id = "boss_10_overmind", boss_name = "Vorn Overmind", tileset = "core", spawn_s = 1.50, bullet_px_s = 63, boss_hp = 300, expose_s = 1.8, cycle_s = 6.0, bgm = "bgm_stage_c" },
}

return G
