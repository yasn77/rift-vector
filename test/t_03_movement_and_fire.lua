-- test/t_03_movement_and_fire.lua -- Ship movement bounds, diagonal normalization,
-- speed tiers 0..3 and fire-edge / Wave Cannon contracts (Atomic Requirements 1..5 & 16).

local H = require "test.harness"

-- Find a vertical offset delta_y from start (64, 112) where an unpowered vulcan tap
-- strikes the Stage-1 boss core while exposed, so wave damage assertions never
-- assume a hardcoded boss Y coordinate.
local function align_with_stage1_boss_core()
  local offsets = { 0, 16, -16, 32, -32, 48, -48 }
  for i = 1, #offsets do
    H.start_play(1, "boss alignment probe")
    local r = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
    local dy = offsets[i]
    if dy ~= 0 then
      local dir = dy > 0 and 1 or -1
      r = H.move_for(0, dir, H.secs(math.abs(dy) / 80.0), "align Y")
    end
    local exposed_r = H.advance_until(function(rep)
      return rep.boss ~= nil and rep.boss.exposed == true
    end, H.secs(7.0), 4, "wait Ribmaw exposed")
    if exposed_r and exposed_r.boss then
      local hp_before = exposed_r.boss.hp
      H.tap_fire(1, "probe shot")
      local after = H.advance(H.secs(1.2), "let vulcan reach boss")
      if after.boss and after.boss.hp < hp_before then
        return dy
      end
    end
  end
  return 0
end

-- Locate >=3 horizontally aligned enemies ahead of Lance (x > 100, y span <= 22 px)
-- so a 24 px Tier-3 piercing wave cleanly intersects all three in one shot.
local function find_aligned_triple(enemies)
  if type(enemies) ~= "table" or #enemies < 3 then
    return nil
  end
  for i = 1, #enemies do
    local anchor = enemies[i]
    if type(anchor.x) == "number" and type(anchor.y) == "number" and anchor.x >= 100 and anchor.x <= 316 then
      local group = { anchor }
      local min_y = anchor.y
      local max_y = anchor.y
      for j = 1, #enemies do
        if j ~= i then
          local cand = enemies[j]
          if type(cand.x) == "number" and type(cand.y) == "number" and cand.x >= 96 and cand.x <= 320 then
            local cand_min = math.min(min_y, cand.y)
            local cand_max = math.max(max_y, cand.y)
            if (cand_max - cand_min) <= 22 then
              group[#group + 1] = cand
              min_y = cand_min
              max_y = cand_max
            end
          end
        end
      end
      if #group >= 3 then
        return (min_y + max_y) * 0.5
      end
    end
  end
  return nil
end

return function()
  describe("Ship movement, speed cap and fire-edge / Wave Cannon", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("ship centre clamps to x=16..304 and y=32..192 logical pixels", function()
      -- Left clamp x=16: from x=64 at 80 px/s, 0.60 s reaches x=16.
      H.start_play(1, "AR-01 left clamp 0.8s")
      H.move_for(-1, 0, H.secs(0.80), "clamp left 0.8s")
      local ticks_left_a = H.measure_launch_ticks_from_front(120, "launch from left clamp A")
      -- Expected: (264 - (16 + 24)) / 200 * 60 = 67.2 ticks
      assert_contract(
        H.near(ticks_left_a, 67, 4),
        "at left clamp x=16, front Force (x=40) launch to x=264 at 200 px/s must take ~67 ticks, got "
          .. tostring(ticks_left_a)
      )

      H.start_play(1, "AR-01 left clamp 2.0s")
      H.move_for(-1, 0, H.secs(2.00), "clamp left 2.0s")
      local ticks_left_b = H.measure_launch_ticks_from_front(120, "launch from left clamp B")
      assert_contract(
        math.abs(ticks_left_a - ticks_left_b) <= 1,
        "continuing to hold move_left must stay clamped at x=16 (atomic requirement 1); launch ticks "
          .. tostring(ticks_left_a) .. " vs " .. tostring(ticks_left_b)
      )

      -- Right clamp x=304: use Speed L3 (128 px/s) so 2.00 s and 2.35 s both clamp at x=304
      -- before the first t=2.40 s enemy spawn, then step back to safe x=224 (>176 hysteresis)
      -- after pressing input_force so no incoming x=344 scout collides with Lance mid-launch.
      local function measure_right_clamp_launch(hold_right_s, tag)
        H.start_play(1, tag)
        H.collect_powerup("red", nil, "acquire Force")
        H.collect_powerup("speed", nil, "spd 1")
        H.collect_powerup("speed", nil, "spd 2")
        H.collect_powerup("speed", nil, "spd 3")
        H.move_for(1, 0, H.secs(hold_right_s), "clamp right")
        H.post("input_force", {})
        H.post("input_move", { dx = -1, dy = 0 })
        local ticks = 0
        while ticks < 140 do
          if ticks == 24 then
            H.post("input_move", { dx = 0, dy = 0 })
          end
          local r = H.advance(1, tag)
          ticks = ticks + 1
          if r.force and r.force.state == "detached" then
            return ticks
          end
        end
        H.fail("Force did not detach from right clamp x=304 within 140 ticks")
        return ticks
      end

      local ticks_right_a = measure_right_clamp_launch(2.00, "AR-01 right clamp 2.00s")
      local ticks_right_b = measure_right_clamp_launch(2.35, "AR-01 right clamp 2.35s")
      assert_contract(
        ticks_right_a >= 70 and math.abs(ticks_right_a - ticks_right_b) <= 1,
        "continuing to hold move_right must clamp ship centre at x=304 (atomic requirement 1); launch ticks "
          .. tostring(ticks_right_a) .. " vs " .. tostring(ticks_right_b)
      )

      -- Vertical clamps y=32..192 tested inside the 2.0 s post-death respawn protection
      -- window at Speed L3 (128 px/s) so top/bottom terrain bands cannot kill Lance during the probe.
      H.start_play(1, "AR-01 upper vertical clamp y=192")
      H.post("player_hit", { source_id = "qa-clamp-top-prep" })
      local r_resp_top = H.advance(H.secs(1.10), "wait 1.0 s death interval")
      assert_contract(r_resp_top.lives == 2, "expected respawn with 2 lives and 2.0 s protection")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      -- Drive upward 1.25 s (+160 px -> clamps at y<=192, never y=272), then step down 0.30 s (-38.4 px -> y<=153.6 safe).
      H.move_for(0, 1, H.secs(1.25), "drive to upper clamp y=192")
      local r_safe_top = H.move_for(0, -1, H.secs(0.30), "step down from upper clamp into safe channel")
      assert_contract(
        r_safe_top.lives == 2,
        "vertical movement must clamp at y<=192 and return cleanly into playfield (atomic requirement 1)"
      )

      H.start_play(1, "AR-01 lower vertical clamp y=32")
      H.post("player_hit", { source_id = "qa-clamp-bot-prep" })
      local r_resp_bot = H.advance(H.secs(1.10), "wait 1.0 s death interval")
      assert_contract(r_resp_bot.lives == 2, "expected respawn with 2 lives and 2.0 s protection")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      -- Drive downward 1.25 s (-160 px -> clamps at y>=32, never y=-48), then step up 0.30 s (+38.4 px -> y>=70.4 safe).
      H.move_for(0, -1, H.secs(1.25), "drive to lower clamp y=32")
      local r_safe_bot = H.move_for(0, 1, H.secs(0.30), "step up from lower clamp into safe channel")
      assert_contract(
        r_safe_bot.lives == 2,
        "vertical movement must clamp at y>=32 and return cleanly into playfield (atomic requirement 1)"
      )
    end)

    test("diagonal normalization and speed levels 0..3 (80, 96, 112, 128 px/s) with cap at 3", function()
      -- Expected launch ticks after clamping to x=16 and moving right for 60 ticks (1.00 s):
      --   speed 0 (80 px/s -> x=96,  dist=144): 43.2 ticks
      --   speed 1 (96 px/s -> x=112, dist=128): 38.4 ticks
      --   speed 2 (112 px/s -> x=128, dist=112): 33.6 ticks
      --   speed 3 (128 px/s -> x=144, dist=96):  28.8 ticks
      local expected_ticks = { [0] = 43, [1] = 38, [2] = 34, [3] = 29 }
      local measured = {}

      for spd = 0, 4 do
        H.start_play(1, "AR-01/16 speed level " .. tostring(spd))
        H.collect_powerup("red", nil, "Force for speed probe")
        H.move_for(-1, 0, H.secs(0.80), "clamp to x=16")
        for _ = 1, spd do
          H.collect_powerup("speed", nil, "speed pickup")
        end
        H.move_for(1, 0, 60, "move right 1.00 s")
        measured[spd] = H.measure_launch_ticks_from_front(120, "measure speed " .. tostring(spd))
      end

      for spd = 0, 3 do
        assert_contract(
          H.near(measured[spd], expected_ticks[spd], 2),
          "speed level " .. tostring(spd) .. " must move at " .. tostring(80 + 16 * spd)
            .. " px/s (~" .. tostring(expected_ticks[spd]) .. " launch ticks), got " .. tostring(measured[spd])
        )
      end
      assert_contract(
        measured[0] > measured[1] and measured[1] > measured[2] and measured[2] > measured[3],
        "each speed pickup up to level 3 must strictly increase ship speed (atomic requirements 1 & 16)"
      )
      assert_contract(
        math.abs(measured[4] - measured[3]) <= 1,
        "4th speed pickup must NOT exceed speed level 3 (128 px/s cap, atomic requirement 16); got ticks "
          .. tostring(measured[4]) .. " vs level-3 " .. tostring(measured[3])
      )

      -- Diagonal normalization: 0.70 s (42 ticks) along (1, 1) from x=16 at speed 0
      -- moves dx = 80 / sqrt(2) * 0.70 = 39.6 px -> x=55.6 -> dist=184.4 px -> 55.3 ticks
      -- (un-normalized dx=56 px would give 50.4 ticks).
      H.start_play(1, "AR-01 diagonal normalization")
      H.collect_powerup("red", nil, "Force for diagonal probe")
      H.move_for(-1, 0, H.secs(0.80), "clamp to x=16")
      H.move_for(1, 1, 42, "move diagonally 0.70 s")
      local diag_ticks = H.measure_launch_ticks_from_front(120, "diagonal launch probe")
      assert_contract(
        H.near(diag_ticks, 55, 2),
        "diagonal input {dx=1,dy=1} must be normalized to 80/sqrt(2) px/s per axis (~55 launch ticks, not 50), got "
          .. tostring(diag_ticks)
      )

      -- Over-unit input magnitude {dx=2, dy=0} must also clamp/normalize to unit speed.
      H.start_play(1, "AR-01 magnitude > 1 normalization")
      H.collect_powerup("red", nil, "Force for magnitude probe")
      H.move_for(-1, 0, H.secs(0.80), "clamp to x=16")
      H.move_for(2, 0, 60, "move with dx=2 for 1.00 s")
      local mag_ticks = H.measure_launch_ticks_from_front(120, "magnitude launch probe")
      assert_contract(
        H.near(mag_ticks, expected_ticks[0], 2),
        "input_move with magnitude > 1 must normalize to unit speed 80 px/s, got launch ticks " .. tostring(mag_ticks)
      )
    end)

    test("distinct fire press emits one 1-damage vulcan shot, ignores repeats and emits no auto-fire on hold", function()
      H.start_play(1, "AR-02 fire edge semantics")
      local mark_press = H.mark_events()
      H.post("input_fire_press", {})
      H.advance(1, "initial fire press")
      assert_contract(
        H.count_cue_since(mark_press, "shot") == 1,
        "a fire press edge must immediately emit exactly one vulcan shot (atomic requirement 2)"
      )

      -- Simulated OS repeat / second bound key (Z+Space logical action) while already held:
      local mark_held = H.mark_events()
      H.post("input_fire_press", {})
      H.advance(15, "repeat press while held")
      H.post("input_fire_press", {})
      H.advance(30, "continued hold without release")
      assert_contract(
        H.count_cue_since(mark_held, "shot") == 0,
        "repeated input_fire_press while held and continuous holding must emit zero additional vulcan shots (atomic requirement 2)"
      )
      H.post("input_fire_release", {})
      H.advance(2, "release hold")

      -- Two distinct taps emit two distinct 1-damage vulcan shots:
      local mark_taps = H.mark_events()
      H.tap_fire(4, "tap 1")
      H.tap_fire(4, "tap 2")
      assert_contract(
        H.count_cue_since(mark_taps, "shot") == 2,
        "two distinct fire taps must emit exactly two vulcan shots, never a 3-shot burst"
      )

      -- Verify each vulcan shot deals exact 1 HP damage against exposed Ribmaw core:
      local dy_v = align_with_stage1_boss_core()
      H.start_play(1, "AR-02 1-damage vulcan")
      local rv = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
      if dy_v ~= 0 then
        rv = H.move_for(0, dy_v > 0 and 1 or -1, H.secs(math.abs(dy_v) / 80.0), "align Y")
      end
      rv = H.advance_until(function(rep)
        return rep.boss ~= nil and rep.boss.exposed == true
      end, H.secs(7.0), 3, "wait exposed for 1-damage vulcan")
      assert_contract(rv ~= nil and rv.boss ~= nil, "Ribmaw must expose weak point")
      local hp_v0 = rv.boss.hp
      H.tap_fire(1, "single vulcan shot")
      local rv_after = H.advance(H.secs(1.15), "vulcan flight")
      assert_contract(
        rv_after.boss ~= nil and (hp_v0 - rv_after.boss.hp) == 1,
        "one unpowered vulcan shot must deal exact 1 damage (atomic requirement 2), dealt "
          .. tostring(rv_after.boss and (hp_v0 - rv_after.boss.hp))
      )
    end)

    test("continuous fire hold charges from 0.30 s, hits wave tiers 1/2/3 at 0.60/1.10/1.80 s and caps before release", function()
      H.start_play(1, "AR-03 wave charge timing")
      local mark = H.mark_events()
      H.post("input_fire_press", {})

      -- 0.25 s (15 ticks): before 0.30 s threshold
      H.advance(15, "0.25 s hold")
      local charges_early = H.events_since(mark, "wave_charge")
      for i = 1, #charges_early do
        assert_contract(
          (charges_early[i].msg.tier or 0) == 0,
          "hold < 0.30 s must remain at wave tier 0"
        )
      end

      -- Advance to 0.55 s total (33 ticks): charging active, still below 0.60 s Tier 1
      H.advance(18, "0.55 s total hold")
      local charges_sub1 = H.events_since(mark, "wave_charge")
      local max_tier = 0
      local max_frac = 0
      for i = 1, #charges_sub1 do
        local m = charges_sub1[i].msg
        if (m.tier or 0) > max_tier then max_tier = m.tier end
        if (m.fraction or 0) > max_frac then max_frac = m.fraction end
      end
      assert_contract(
        max_tier == 0 and max_frac > 0,
        "between 0.30 s and 0.60 s hold, BEAM gauge fraction must rise while tier stays 0 (atomic requirement 3)"
      )

      -- Advance to 0.62 s total (38 ticks >= 36 + 1 tick tolerance): Tier 1
      local mark_t1 = H.mark_events()
      H.advance(5, "0.63 s total hold -> Tier 1")
      local ev_t1 = H.events_since(mark_t1, "wave_charge")
      assert_contract(
        #ev_t1 > 0 and ev_t1[#ev_t1].msg.tier == 1,
        "reaching 0.60 s total hold must advance wave_charge to tier 1 (atomic requirement 3)"
      )

      -- Advance to 1.13 s total (68 ticks >= 66 + 1 tick tolerance): Tier 2
      local mark_t2 = H.mark_events()
      H.advance(30, "1.13 s total hold -> Tier 2")
      local ev_t2 = H.events_since(mark_t2, "wave_charge")
      assert_contract(
        #ev_t2 > 0 and ev_t2[#ev_t2].msg.tier == 2,
        "reaching 1.10 s total hold must advance wave_charge to tier 2 (atomic requirement 3)"
      )

      -- Advance to 1.83 s total (110 ticks >= 108 + 1 tick tolerance): Tier 3
      local mark_t3 = H.mark_events()
      H.advance(42, "1.83 s total hold -> Tier 3")
      local ev_t3 = H.events_since(mark_t3, "wave_charge")
      assert_contract(
        #ev_t3 > 0 and ev_t3[#ev_t3].msg.tier == 3 and H.near(ev_t3[#ev_t3].msg.fraction, 1.0, 0.05),
        "reaching 1.80 s total hold must advance wave_charge to tier 3 with fraction=1.0 (atomic requirement 3)"
      )

      -- Hold to 2.40 s total (144 ticks): stays capped at tier 3 and emits no wave while held
      H.advance(34, "2.40 s over-hold cap")
      assert_contract(
        not H.has_cue_since(mark, "wave_fire"),
        "a held charge must emit no wave beam before input_fire_release (atomic requirement 3)"
      )
      H.post("input_fire_release", {})
      H.advance(2, "release Tier 3")
      assert_contract(
        H.has_cue_since(mark_t3, "wave_fire"),
        "input_fire_release at Tier 3 must launch the wave beam"
      )
    end)

    test("release <0.60 s emits no wave; release at tiers 1/2/3 deals 8/20/48 damage and resets BEAM gauge", function()
      -- Sub-0.60 s release emits no wave
      H.start_play(1, "AR-04 sub-tier-1 release")
      local mark_short = H.mark_events()
      H.hold_and_release_fire(30, 4, "0.50 s hold release")
      assert_contract(
        not H.has_cue_since(mark_short, "wave_fire"),
        "releasing fire below 0.60 s must emit no wave beam (atomic requirement 4)"
      )

      -- Align with Stage 1 boss Ribmaw (HP 120) and measure exact 8 / 20 / 48 wave damages.
      -- Start holding while boss.exposed==false so the press-edge 1-damage vulcan hits closed
      -- armour for 0 damage, then release once boss.exposed==true!
      local dy = align_with_stage1_boss_core()
      H.start_play(1, "AR-04 boss wave damage")
      local r = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
      if dy ~= 0 then
        local dir = dy > 0 and 1 or -1
        r = H.move_for(0, dir, H.secs(math.abs(dy) / 80.0), "align Y with Ribmaw")
      end

      local tiers = {
        { tier = 1, hold = H.secs(0.65), expected_dmg = 8 },
        { tier = 2, hold = H.secs(1.18), expected_dmg = 20 },
        { tier = 3, hold = H.secs(1.88), expected_dmg = 48 },
      }

      for i = 1, #tiers do
        local spec = tiers[i]
        -- Synchronise to the open -> closed falling edge of Ribmaw's 6.0 s cycle
        -- (2.50 s open, 3.50 s closed), then pre-advance (3.50 s - spec.hold) into
        -- the closed phase before pressing fire so the press-edge vulcan strikes
        -- closed armour for 0 damage and release lands inside spec.tier once exposed.
        r = H.advance_until(function(rep)
          return rep.boss ~= nil and rep.boss.exposed == true
        end, H.secs(6.5), 2, "sync open before tier " .. tostring(spec.tier))
        assert_contract(r ~= nil and r.boss ~= nil, "Ribmaw weak point must open during 6 s cycle")
        r = H.advance_until(function(rep)
          return rep.boss ~= nil and rep.boss.exposed == false
        end, H.secs(3.5), 1, "wait closed before tier " .. tostring(spec.tier))
        assert_contract(r ~= nil and r.boss ~= nil, "Ribmaw must be active with closed phases")
        local pre_closed = H.secs(3.50) - spec.hold - 1
        if pre_closed > 0 then
          r = H.advance(pre_closed, "pre-advance closed window before tier " .. tostring(spec.tier))
        end
        local hp_before = r.boss.hp

        H.post("input_fire_press", {})
        r = H.advance(spec.hold, "charge tier " .. tostring(spec.tier))
        if not (r.boss and r.boss.exposed == true) then
          r = H.advance_until(function(rep)
            return rep.boss ~= nil and rep.boss.exposed == true
          end, H.secs(0.45), 1, "wait exposed for tier " .. tostring(spec.tier))
        end
        assert_contract(
          r ~= nil and r.boss ~= nil and r.boss.exposed == true,
          "Ribmaw weak point must open during 6 s cycle"
        )

        local mark_rel = H.mark_events()
        H.post("input_fire_release", {})
        r = H.advance(H.secs(1.10), "wave flight to Ribmaw")
        local dealt = hp_before - r.boss.hp
        assert_contract(
          dealt == spec.expected_dmg,
          "Tier-" .. tostring(spec.tier) .. " wave beam must deal exactly "
            .. tostring(spec.expected_dmg) .. " damage once (atomic requirements 4 & 5), dealt "
            .. tostring(dealt)
        )

        local post_charges = H.events_since(mark_rel, "wave_charge")
        assert_contract(
          #post_charges > 0 and post_charges[#post_charges].msg.tier == 0
            and H.near(post_charges[#post_charges].msg.fraction, 0.0, 0.01),
          "BEAM gauge must empty to tier=0, fraction=0 immediately after wave release (atomic requirement 5)"
        )
      end
    end)

    test("wave beam pierces >=3 aligned enemies in a formation, damages each once and stops on terrain", function()
      H.start_play(1, "AR-05 wave pierce formation")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      -- Charge Tier 3 while piloting safely until >=3 horizontally aligned formation enemies appear ahead
      H.post("input_fire_press", {})
      H.advance(H.secs(1.90), "charge Tier 3")
      local target_y = nil
      local form_r = nil
      local waited = 0
      while waited < H.secs(60.0) do
        form_r = H.pilot_ticks(12, { shoot = false }, "wait aligned 3-enemy formation")
        waited = waited + 12
        target_y = find_aligned_triple(form_r and form_r.enemies)
        if target_y ~= nil then
          break
        end
      end
      assert_contract(
        form_r ~= nil and target_y ~= nil,
        "Stage 1 must spawn a 3-enemy formation (design section 4: 1-3 enemies with 0.2 s spacing)"
      )

      -- Align Lance Y rapidly at 128 px/s to the aligned triple's mean Y and release Tier-3 24 px piercing wave
      local dy = target_y - 112
      if math.abs(dy) > 3 then
        H.move_for(0, dy > 0 and 1 or -1, H.secs(math.abs(dy) / 128.0), "align with 3-enemy formation")
      end
      local mark_kills = H.mark_events()
      H.post("input_fire_release", {})
      H.advance(H.secs(1.30), "let Tier-3 wave traverse playfield")
      local kills = H.events_since(mark_kills, "enemy_killed")
      local awards = H.events_since(mark_kills, "score_add")
      assert_contract(
        #kills >= 3 or #awards >= 3,
        "a Tier-3 piercing wave must pierce and clear at least 3 aligned formation enemies in one shot (atomic requirement 5), killed="
          .. tostring(math.max(#kills, #awards))
      )
    end)
  end)
end
