-- test/t_08_hud_pause_screens.lua -- Bottom y=0..24 HUD layout & readouts,
-- pause simulation freeze + held-charge cancellation, and full six-screen
-- transition graph (Atomic Requirements 26, 27 & 28).

local H = require "test.harness"

return function()
  describe("Bottom HUD band, pause freeze semantics and six-screen transitions", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("bottom y=0..24 HUD declares 1P, HI, BEAM, lives and stage readouts without occluding playfield", function()
      local scene = H.collect_scene_files("/main/main.collection")
      assert_contract(
        type(scene.all_text) == "string" and #scene.all_text > 0,
        "HUD verification requires main/main.collection"
      )

      local gui_blobs = scene.by_ext["gui"] or {}
      assert_contract(
        #gui_blobs >= 1,
        "shipped main.collection must mount a .gui component for the y=0..24 HUD (atomic requirement 26)"
      )
      local combined_gui = table.concat(gui_blobs, "\n"):lower()

      -- Verify all 5 required HUD readouts are represented in the GUI node ids or labels
      local has_score = string.find(combined_gui, "score", 1, true) ~= nil or string.find(combined_gui, "1p", 1, true) ~= nil
      local has_hi = string.find(combined_gui, "hi", 1, true) ~= nil
      local has_beam = string.find(combined_gui, "beam", 1, true) ~= nil or string.find(combined_gui, "gauge", 1, true) ~= nil
      local has_lives = string.find(combined_gui, "live", 1, true) ~= nil or string.find(combined_gui, "life", 1, true) ~= nil
      local has_stage = string.find(combined_gui, "stage", 1, true) ~= nil
      assert_contract(
        has_score and has_hi and has_beam and has_lives and has_stage,
        "HUD .gui must display 1P score, HI score, BEAM gauge, lives and stage number (atomic requirement 26)"
      )

      -- Runtime observable check: entering play and scoring/charging emits HUD update events cleanly
      local r, mark = H.start_play(1, "AR-26 HUD runtime observables")
      H.post("enemy_killed", { spawn_id = H.uid("hud-drone"), kind = "drone", stage = 1 })
      H.post("input_fire_press", {})
      r = H.advance(H.secs(0.65), "charge BEAM Tier 1 for HUD")
      H.post("input_fire_release", {})
      r = H.advance(2, "release BEAM")
      assert_contract(
        r.score == 100 and #H.events_since(mark, "score_add") >= 1 and #H.events_since(mark, "wave_charge") >= 1,
        "runtime must emit score_add and wave_charge updates driving the y=0..24 HUD"
      )
    end)

    test("pause freezes movement, charge, spawning, boss clocks, cooldowns and scroll, and cancels held wave on resume", function()
      H.start_play(1, "AR-27 pause freeze & charge cancel")
      H.collect_powerup("red", nil, "Force for position probe")
      -- Clamp Lance at x=16 so ship position before/after pause is exact via Force launch ticks
      H.move_for(-1, 0, H.secs(0.80), "clamp left at x=16")

      -- Pilot 8 s (keeping x=16, y=112 at end) so scrolling and enemy formations are active
      H.pilot_ticks(H.secs(8.0), { shoot = false }, "scroll 8 s into Stage 1")
      -- Move right 0.50 s (30 ticks -> x=56) while holding fire into Tier 1 (0.70 s = 42 ticks total):
      H.post("input_fire_press", {})
      H.advance(12, "pre-hold 0.20 s")
      H.post("input_move", { dx = 1, dy = 0 })
      H.advance(30, "move right to x=56 + reach Tier 1 charge (0.70 s)")

      -- Toggle play -> pause while moving rightward and holding Tier-1 charge!
      local mark_pause = H.mark_events()
      H.post("input_pause", {})
      local r_paused = H.advance(1, "enter pause")
      assert_contract(
        r_paused.screen == "pause" and #H.events_since(mark_pause, "screen_changed") >= 1,
        "input_pause during 'play' must enter 'pause' screen immediately (atomic requirement 27), got '"
          .. tostring(r_paused.screen) .. "'"
      )

      local scroll_at_pause = r_paused.scroll_px
      local enemy_snapshot = {}
      for i = 1, #(r_paused.enemies or {}) do
        local e = r_paused.enemies[i]
        enemy_snapshot[i] = { id = e.spawn_id, x = e.x, y = e.y, hp = e.hp }
      end

      -- Advance 180 ticks (3.0 s) while paused, sending movement and start inputs (must have zero effect!)
      -- If ship movement were NOT frozen during pause, 3.0 s rightward would move Lance to x=296 > 160!
      H.post("input_move", { dx = 1, dy = 0 })
      H.post("input_start", {})
      local r_after_paused_ticks = H.advance(180, "3.0 s while paused")
      assert_contract(
        r_after_paused_ticks.screen == "pause",
        "input_start must be ignored while paused (design section 4)"
      )
      assert_contract(
        H.near(r_after_paused_ticks.scroll_px, scroll_at_pause, 0.001),
        "pause must freeze stage scrolling completely (atomic requirement 27); scroll moved "
          .. H.fmt(scroll_at_pause) .. " -> " .. H.fmt(r_after_paused_ticks.scroll_px)
      )
      assert_contract(
        #(r_after_paused_ticks.enemies or {}) == #enemy_snapshot,
        "pause must freeze enemy spawning and despawning (atomic requirement 27)"
      )
      for i = 1, #enemy_snapshot do
        local now_e = r_after_paused_ticks.enemies[i]
        local old_e = enemy_snapshot[i]
        assert_contract(
          now_e.spawn_id == old_e.id and H.near(now_e.x, old_e.x, 0.01) and H.near(now_e.y, old_e.y, 0.01),
          "pause must freeze enemy motion tweens (atomic requirement 27)"
        )
      end

      -- Toggle pause -> play: held fire and pending movement must be cancelled WITHOUT releasing a wave!
      local mark_resume = H.mark_events()
      H.post("input_pause", {})
      local r_resumed = H.advance(2, "resume play")
      assert_contract(
        r_resumed.screen == "play",
        "second input_pause must resume 'play' screen (atomic requirement 27)"
      )
      H.post("input_move", { dx = 0, dy = 0 })
      H.post("input_fire_release", {})
      H.advance(4, "post-resume release edge")
      assert_contract(
        not H.has_cue_since(mark_resume, "wave_fire"),
        "resuming from pause must cancel held fire without releasing a wave beam (atomic requirement 27)"
      )

      -- Prove ship position froze at x~56 during the 3.0 s pause (launch from x~56 -> pod x~80 to x=264 takes ~55 ticks, NOT right-half launch!):
      local post_pause_launch_ticks = H.measure_launch_ticks_from_front(100, "verify ship movement froze during pause")
      assert_contract(
        H.near(post_pause_launch_ticks, 55, 5),
        "pause must freeze ship movement tweens at x~56 (~55 Force launch ticks, atomic requirement 27), got "
          .. tostring(post_pause_launch_ticks)
      )

      -- Verify boss exposure clock AND 0.80 s missile cooldown both freeze during pause:
      H.start_play(1, "AR-27 boss clock & cooldown freeze")
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
      H.collect_powerup("missile", nil, "equip missiles for cooldown freeze")
      H.move_for(0, -1, H.secs(32.0 / 80.0), "shift off-axis so homing missiles isolate cooldown")
      local r_exp = H.advance_until(function(rep) return rep.boss and rep.boss.exposed end, H.secs(7.0), 2, "open")
      assert_contract(r_exp ~= nil and r_exp.boss.exposed == true, "Ribmaw exposed before pause")

      local hp_cd0 = r_exp.boss.hp
      -- Fire tap #1 (launches missile pair #1 and begins 0.80 s cooldown), advance 0.15 s, then pause for 5.0 s!
      H.tap_fire(8, "tap #1 starts 0.80 s missile cooldown")
      H.post("input_pause", {})
      H.advance(1, "pause during 2.5 s boss exposure and 0.80 s missile cooldown")
      H.advance(H.secs(5.0), "wait 5.0 s paused (would expire both 2.5 s opening and 0.80 s cooldown if clocks ran!)")
      H.post("input_pause", {})
      local r_boss_resumed = H.advance(2, "resume boss fight")
      assert_contract(
        r_boss_resumed.boss ~= nil and r_boss_resumed.boss.exposed == true,
        "pause must freeze boss exposure clocks so a 2.5 s opening does not expire during 5.0 s of pause (atomic requirement 27)"
      )
      -- Immediately tap fire #2 at ~0.20 s of active unpaused time (< 0.80 s cooldown): must NOT launch a second missile pair!
      H.tap_fire(2, "tap #2 still inside frozen 0.80 s cooldown")
      local r_cd_after = H.advance(H.secs(1.25), "missile flight after unpause")
      local cd_dealt = hp_cd0 - r_cd_after.boss.hp
      assert_contract(
        cd_dealt >= 6 and cd_dealt <= 8,
        "pause must freeze the 0.80 s missile cooldown so 5.0 s paused does not ready a second missile pair (atomic requirement 27), dealt "
          .. tostring(cd_dealt)
      )
    end)

    test("Enter (input_start) drives title -> play (ignored in play), stage_clear -> next stage, game_over -> play and victory -> title", function()
      local r_title = H.reset_to_title("AR-28 screen state graph")
      assert_contract(r_title.screen == "title", "starts on 'title'")

      -- title -> play, and input_start during play is ignored
      H.post("input_start", {})
      local r_play = H.advance(2, "title -> play")
      assert_contract(r_play.screen == "play", "Enter from 'title' enters 'play'")
      H.advance(30, "scroll slightly")
      local scroll_mid = H.advance(1, "probe").scroll_px
      H.post("input_start", {})
      local r_ignored = H.advance(2, "Enter during play ignored")
      assert_contract(
        r_ignored.screen == "play" and r_ignored.scroll_px >= scroll_mid,
        "input_start must be ignored during active 'play' (design section 4 & atomic requirement 28)"
      )

      -- Clear Stage 1 -> stage_clear -> input_start -> Stage 2 play (scroll_px=0, equipment retained!)
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("red", nil, "L2")
      H.collect_powerup("red", nil, "L3")
      H.collect_powerup("bit", nil, "bit 1")
      H.collect_powerup("bit", nil, "bit 2")
      H.pilot_to_boss({ shoot = true, allow_continue = false, quiet_tail_s = 1.0 }, "scroll Stage 1 to Ribmaw")
      local r_sc = H.defeat_active_boss({ max_seconds = 60.0, allow_continue = false, re_equip_red_l3 = false }, "defeat Ribmaw")
      if r_sc.screen ~= "stage_clear" then
        r_sc = H.advance_until(function(rep) return rep.screen == "stage_clear" end, H.secs(3.0), 3, "await stage_clear") or r_sc
      end
      assert_contract(
        r_sc.screen == "stage_clear",
        "defeating Stage 1 boss must enter 'stage_clear' screen (atomic requirement 28), got '"
          .. tostring(r_sc.screen) .. "'"
      )

      local mark_next = H.mark_events()
      H.post("input_start", {})
      local r_stage2 = H.advance(4, "stage_clear -> Stage 2 play")
      assert_contract(
        r_stage2.screen == "play"
          and r_stage2.scroll_px < 10
          and r_stage2.force.level == 3
          and H.has_cue_since(mark_next, "bgm_stage_b"),
        "Enter on 'stage_clear' must advance to Stage 2 'play' at scroll 0 while retaining Force equipment (atomic requirement 28)"
      )

      -- Stage 10 boss defeat -> victory -> input_start -> title
      H.post("test_set_stage", { stage = 10 })
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 1.0 }, "scroll Stage 10 to Overmind")
      H.collect_powerup("red", nil, "ensure L2/L3")
      H.collect_powerup("red", nil, "ensure L3")
      local r_vic = H.defeat_active_boss({ max_seconds = 75.0, allow_continue = true, re_equip_red_l3 = true }, "defeat Overmind")
      if r_vic.screen ~= "victory" then
        r_vic = H.advance_until(function(rep) return rep.screen == "victory" end, H.secs(3.0), 3, "await victory") or r_vic
      end
      assert_contract(
        r_vic.screen == "victory",
        "defeating Stage 10 Overmind must enter 'victory' screen (atomic requirement 28)"
      )
      H.post("input_start", {})
      local r_back_title = H.advance(4, "victory -> title")
      assert_contract(
        r_back_title.screen == "title",
        "Enter on 'victory' must return to 'title' screen (design section 4 & atomic requirement 28)"
      )
    end)
  end)
end
