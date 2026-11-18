-- test/t_09_touch_controls.lua -- Blind behavioural contracts for the native
-- mobile touch control scheme (Design section 4 addendum & Atomic Requirement 34).
--
-- Exercises viewport_map coordinate mapping, menu tap confirmation & gesture
-- consumption, left-zone 1:1 relative MOVE drag + clamping + anchor rebasing,
-- right-lower FIRE vulcan edge & wave-charge tiers 1..3, zone-ownership capture,
-- right-upper FORCE unacquired no-op & launch/recall, top-right pause button
-- priority + simultaneous two-finger tap pause, independent MOVE+FIRE multi-touch
-- with 3rd-finger rejection, pause/death capture cancellation, and post-touch
-- keyboard command-path integrity. Strict Lua 5.1.

local H = require "test.harness"

local DEFAULT_VP = { scale = 3, ox = 0, oy = 0 }

local function sx_of(lx, vp)
  local map = vp or DEFAULT_VP
  return lx * map.scale + map.ox
end

local function sy_of(ly, vp)
  local map = vp or DEFAULT_VP
  return ly * map.scale + map.oy
end

local function pt(id, lx, ly, pressed, released, vp)
  return {
    id = id,
    x = sx_of(lx, vp),
    y = sy_of(ly, vp),
    pressed = (pressed == true),
    released = (released == true),
  }
end

local function pt_raw(id, sx, sy, pressed, released)
  return {
    id = id,
    x = sx,
    y = sy,
    pressed = (pressed == true),
    released = (released == true),
  }
end

local function send_touch(points, ticks, note)
  H.post("test_touch", { points = points })
  if ticks ~= nil then
    return H.advance(ticks, note)
  end
  return nil
end

local function tap_logical(id, lx, ly, hold_ticks, settle_ticks, vp, note)
  send_touch({ pt(id, lx, ly, true, false, vp) }, hold_ticks or 1, note)
  return send_touch({ pt(id, lx, ly, false, true, vp) }, settle_ticks or 1, note)
end

local function reset_title_with_vp(vp, note)
  local r = H.reset_to_title(note)
  H.post("viewport_map", vp or DEFAULT_VP)
  r = H.advance(1, note)
  return r
end

-- Enter play via a touch tap on the title screen so touch mode is active from tick 0.
local function start_play_via_touch(stage, vp, note)
  local map = vp or DEFAULT_VP
  reset_title_with_vp(map, note)
  local mark = H.mark_events()
  local r = tap_logical(1, 100, 100, 1, 1, map, note)
  H.check(
    r ~= nil and r.screen == "play",
    "single touch tap on 'title' must send input_start and enter 'play' (atomic requirement 34), got '"
      .. tostring(r and r.screen) .. "'"
  )
  if stage ~= nil then
    r = H.set_stage(stage, note)
    H.post("viewport_map", map)
    r = H.advance(1, note)
  end
  return r, mark
end

-- Measure right-half Force launch ticks when ship.x >= 176 (launches left to x=56),
-- stepping Lance safely away from x=304 after launch press so incoming x=344 scouts
-- cannot collide mid-measurement.
local function measure_launch_ticks_from_right_half(max_ticks, note)
  local r0 = H.advance(1, note)
  if not r0.force or r0.force.level == 0 then
    r0 = H.collect_powerup("red", nil, note)
  end
  H.check(
    r0.force ~= nil and r0.force.state == "attached_front",
    "expected Force in 'attached_front' before right-half launch probe, got '"
      .. tostring(r0.force and r0.force.state) .. "'"
  )
  H.post("input_force", {})
  local ticks = 0
  local limit = max_ticks or 140
  while ticks < limit do
    local r = H.advance(1, note)
    ticks = ticks + 1
    if r.force and r.force.state == "detached" then
      return ticks, r
    end
  end
  H.fail("Force did not reach 'detached' state within " .. tostring(limit) .. " ticks from right half")
  return ticks, nil
end

return function()
  describe("Native mobile touch controls and viewport mapping", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("test_touch is ignored outside test_mode and emits zero disallowed STUDIO_TELEMETRY events", function()
      local ALLOWED_TELEMETRY = {
        bot_input = true,
        audio_play = true,
        audio_cooldown_suppressed = true,
        audio_unlock = true,
        audio_unlock_skipped = true,
        audio_rms = true,
        audio_reset = true,
      }
      local telemetry_lines = {}
      local real_print = _G.print
      _G.print = function(...)
        local parts = {}
        local n = select("#", ...)
        for i = 1, n do
          parts[i] = tostring(select(i, ...))
        end
        local line = table.concat(parts, "\t")
        if string.sub(line, 1, 17) == "STUDIO_TELEMETRY " then
          telemetry_lines[#telemetry_lines + 1] = line
        end
        real_print(...)
      end

      local ok, err = pcall(function()
        local r_t0 = reset_title_with_vp(DEFAULT_VP, "AR-34 test_touch outside test_mode")
        assert_contract(r_t0.screen == "title", "precondition: on 'title' before disabling test_mode")

        -- Disable test_mode and post a touch tap that would transition title -> play if accepted
        H.post("test_mode", { enabled = false })
        H.sleep_frames(2)
        local mark_off = H.mark_events()
        H.post("test_touch", { points = { pt(1, 160, 100, true, false, DEFAULT_VP) } })
        H.sleep_frames(2)
        H.post("test_touch", { points = { pt(1, 160, 100, false, true, DEFAULT_VP) } })
        H.sleep_frames(2)

        -- Re-enable test_mode and inspect live controller screen via test_spawn_report
        H.post("test_mode", { enabled = true })
        H.sleep_frames(1)
        local r_still_title = H.advance(1, "probe screen after test_mode=false touch")
        assert_contract(
          r_still_title.screen == "title",
          "test_touch must be ignored while test_mode is disabled (design section 4 addendum), got screen='"
            .. tostring(r_still_title.screen) .. "'"
        )
        local changes_off = H.events_since(mark_off, "screen_changed")
        for i = 1, #changes_off do
          assert_contract(
            changes_off[i].msg.screen ~= "play",
            "test_touch must not emit play transition while test_mode is disabled"
          )
        end

        -- Re-enable test_mode and run a touch tap + fire tap to verify telemetry silence
        start_play_via_touch(1, DEFAULT_VP, "AR-34 telemetry check")
        tap_logical(1, 240, 60, 1, 2, DEFAULT_VP, "touch fire tap")
      end)
      _G.print = real_print
      if not ok then
        error(err)
      end

      for i = 1, #telemetry_lines do
        local line = telemetry_lines[i]
        local ev = string.match(line, '"event"%s*:%s*"([^"]+)"')
        assert_contract(
          ev ~= nil and ALLOWED_TELEMETRY[ev] == true,
          "neither viewport_map nor test_touch may add a STUDIO_TELEMETRY event (design section 4 addendum), got: "
            .. tostring(line)
        )
      end
    end)

    test("menu screens confirm on any single tap and consume the gesture across screen transition", function()
      reset_title_with_vp(DEFAULT_VP, "AR-34 menu tap & gesture consumption")
      local mark_title = H.mark_events()

      -- Tap-press on 'title' inside the coordinates of play's right-lower FIRE zone (240, 60),
      -- keep holding for 0.75 s (45 ticks) into 'play', then release: must confirm title -> play
      -- once and consume the gesture without firing vulcan or charging/releasing a wave!
      local r_play = send_touch({ pt(1, 240, 60, true, false, DEFAULT_VP) }, 2, "title tap press in fire coords")
      assert_contract(
        r_play.screen == "play" and #H.events_since(mark_title, "screen_changed") >= 1,
        "any single tap on 'title' must emit input_start and enter 'play' (atomic requirement 34), got '"
          .. tostring(r_play.screen) .. "'"
      )
      send_touch({ pt(1, 240, 60, false, false, DEFAULT_VP) }, H.secs(0.75), "hold consumed menu gesture")
      send_touch({ pt(1, 240, 60, false, true, DEFAULT_VP) }, 3, "release consumed menu gesture")
      assert_contract(
        H.count_cue_since(mark_title, "shot") == 0 and not H.has_cue_since(mark_title, "wave_fire"),
        "menu tap gesture must be consumed so holding/releasing into 'play' emits neither vulcan shot nor wave_fire (design section 4 addendum)"
      )

      -- Exhaust 3 lives -> game_over -> single tap confirms continue into play with 3 lives & score 0
      H.post("enemy_killed", { spawn_id = H.uid("menu-drone"), kind = "drone", stage = 1 })
      H.advance(1, "score 100 before game_over")
      for life = 1, 3 do
        H.post("player_hit", { source_id = "qa-menu-go-" .. tostring(life) })
        if life < 3 then
          H.advance(H.secs(3.15), "wait 1.0 s death + 2.0 s respawn protection")
        else
          H.advance(H.secs(1.20), "enter game_over")
        end
      end
      local r_go = H.advance(1, "verify game_over")
      assert_contract(r_go.screen == "game_over", "expected 'game_over' after losing 3 lives, got '" .. tostring(r_go.screen) .. "'")

      local r_cont = tap_logical(2, 50, 150, 1, 2, DEFAULT_VP, "tap continue on game_over")
      assert_contract(
        r_cont.screen == "play" and r_cont.lives == 3 and r_cont.score == 0,
        "any tap on 'game_over' must send input_start to continue with 3 lives and score 0 (atomic requirement 34)"
      )

      -- Clear Stage 1 -> stage_clear -> single tap advances to Stage 2 play
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("red", nil, "L2")
      H.collect_powerup("red", nil, "L3")
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 1.0 }, "scroll Stage 1 to Ribmaw")
      local r_sc = H.defeat_active_boss({ max_seconds = 60.0, allow_continue = true, re_equip_red_l3 = true }, "defeat Ribmaw")
      if r_sc.screen ~= "stage_clear" then
        r_sc = H.advance_until(function(rep) return rep.screen == "stage_clear" end, H.secs(3.0), 3, "await stage_clear") or r_sc
      end
      assert_contract(r_sc.screen == "stage_clear", "expected 'stage_clear' after Stage 1 boss defeat")

      local mark_sc = H.mark_events()
      local r_s2 = tap_logical(3, 80, 90, 1, 3, DEFAULT_VP, "tap advance on stage_clear")
      assert_contract(
        r_s2.screen == "play" and r_s2.scroll_px < 10 and H.has_cue_since(mark_sc, "bgm_stage_b"),
        "any tap on 'stage_clear' must advance to Stage 2 'play' via input_start (atomic requirement 34)"
      )

      -- Clear Stage 10 -> victory -> single tap returns to 'title'
      H.post("test_set_stage", { stage = 10 })
      H.post("viewport_map", DEFAULT_VP)
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 1.0 }, "scroll Stage 10 to Overmind")
      H.collect_powerup("red", nil, "ensure L2/L3")
      H.collect_powerup("red", nil, "ensure L3")
      local r_vic = H.defeat_active_boss({ max_seconds = 75.0, allow_continue = true, re_equip_red_l3 = true }, "defeat Overmind")
      if r_vic.screen ~= "victory" then
        r_vic = H.advance_until(function(rep) return rep.screen == "victory" end, H.secs(3.0), 3, "await victory") or r_vic
      end
      assert_contract(r_vic.screen == "victory", "expected 'victory' after defeating Stage 10 Overmind")

      local r_title_again = tap_logical(4, 260, 140, 1, 3, DEFAULT_VP, "tap return on victory")
      assert_contract(
        r_title_again.screen == "title",
        "any tap on 'victory' must return to 'title' via input_start (atomic requirement 34), got '"
          .. tostring(r_title_again.screen) .. "'"
      )
    end)

    test("viewport_map converts (sx-ox)/scale and excludes HUD y<24 and letterbox margins from play zones", function()
      local letterbox_vp = { scale = 3, ox = 30, oy = 15 }
      start_play_via_touch(1, letterbox_vp, "AR-34 letterboxed viewport_map")
      H.collect_powerup("red", nil, "L1 Force")

      local mark_outside = H.mark_events()
      -- 1) HUD band: lx=240, ly=12 (y<24 must NOT trigger FIRE)
      tap_logical(1, 240, 12, 2, 2, letterbox_vp, "HUD band tap")
      -- 2) Left letterbox margin: lx=-5, ly=100
      tap_logical(2, -5, 100, 2, 2, letterbox_vp, "left letterbox tap")
      -- 3) Right letterbox margin: lx=325, ly=100
      tap_logical(3, 325, 100, 2, 2, letterbox_vp, "right letterbox tap")
      -- 4) Upper letterbox margin: lx=240, ly=205
      local r_after_margins = tap_logical(4, 240, 205, 2, 2, letterbox_vp, "top letterbox tap")

      assert_contract(
        H.count_cue_since(mark_outside, "shot") == 0
          and not H.has_cue_since(mark_outside, "force_launch")
          and r_after_margins.force.state == "attached_front"
          and r_after_margins.screen == "play",
        "HUD band (y<24) and letterbox margins outside logical 0..320 x 24..200 must not trigger play controls (design section 4 addendum)"
      )

      -- Mapped FIRE (lx=200, ly=40 -> sx=630, sy=135) and FORCE (lx=200, ly=140 -> sx=630, sy=435)
      local mark_in = H.mark_events()
      tap_logical(5, 200, 40, 1, 2, letterbox_vp, "mapped FIRE tap")
      assert_contract(
        H.count_cue_since(mark_in, "shot") == 1,
        "mapped screen coordinates inside 192<=lx<=320, 24<=ly<112 must trigger FIRE under offset viewport_map"
      )

      local r_force = tap_logical(6, 200, 140, 1, 2, letterbox_vp, "mapped FORCE tap")
      assert_contract(
        H.has_cue_since(mark_in, "force_launch")
          and (r_force.force.state == "launching" or r_force.force.state == "detached"),
        "mapped screen coordinates inside 192<=lx<=320, 112<=ly<=200 must trigger FORCE under offset viewport_map"
      )
    end)

    test("left MOVE zone (0<=x<192, 24<=y<=200) moves ship 1:1 by relative finger delta without snap-on-press and stops on release", function()
      -- 1) No snap-to-finger on press: Lance starts at (64, 112); pressing at lx=150 without dragging leaves ship.x=64 (~53 launch ticks, not ~27)
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE no snap on press")
      H.collect_powerup("red", nil, "Force for no-snap probe")
      send_touch({ pt(1, 150, 160, true, false, DEFAULT_VP) }, 10, "press MOVE far from ship without drag")
      send_touch({ pt(1, 150, 160, false, true, DEFAULT_VP) }, 2, "release MOVE without drag")
      local ticks_nosnap = H.measure_launch_ticks_from_front(100, "launch probe after stationary MOVE press")
      assert_contract(
        H.near(ticks_nosnap, 53, 4),
        "pressing MOVE at lx=150 without dragging must NOT snap ship from x=64 (~53 Force launch ticks, not 27), got "
          .. tostring(ticks_nosnap)
      )

      -- 2) Exact +60 logical px drag (+180 screen px at scale=3): ship.x moves 64 -> 124 (~35 launch ticks), zero drift after release
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE +60 px relative drag & release stop")
      H.collect_powerup("red", nil, "Force for +60 drag probe")
      send_touch({ pt(1, 80, 112, true, false, DEFAULT_VP) }, 1, "press MOVE at lx=80")
      send_touch({ pt(1, 140, 112, false, false, DEFAULT_VP) }, 2, "drag +60 logical px to lx=140")
      send_touch({ pt(1, 140, 112, false, true, DEFAULT_VP) }, 45, "release MOVE and idle 0.75 s to check zero drift")
      local ticks_plus60 = H.measure_launch_ticks_from_front(100, "launch probe at x=124")
      -- (240 - 124) * 0.3 = 34.8 ticks
      assert_contract(
        H.near(ticks_plus60, 35, 3),
        "dragging MOVE finger +60 logical px from start x=64 and releasing must place ship at x=124 with zero post-release drift (~35 launch ticks), got "
          .. tostring(ticks_plus60)
      )

      -- 3) Multi-step bidirectional drag (+40 px then -60 px = net -20 px -> ship.x = 44 -> ~59 launch ticks)
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE bidirectional net -20 px")
      H.collect_powerup("red", nil, "Force for net -20 probe")
      send_touch({ pt(1, 100, 112, true, false, DEFAULT_VP) }, 1, "press MOVE at lx=100")
      send_touch({ pt(1, 140, 112, false, false, DEFAULT_VP) }, 2, "drag +40 px to lx=140")
      send_touch({ pt(1, 80, 112, false, false, DEFAULT_VP) }, 2, "drag -60 px to lx=80")
      send_touch({ pt(1, 80, 112, false, true, DEFAULT_VP) }, 2, "release MOVE")
      local ticks_minus20 = H.measure_launch_ticks_from_front(100, "launch probe at x=44")
      -- (240 - 44) * 0.3 = 58.8 ticks
      assert_contract(
        H.near(ticks_minus20, 59, 3),
        "bidirectional MOVE drag (+40 then -60 logical px) must move ship by net -20 px to x=44 (~59 launch ticks), got "
          .. tostring(ticks_minus20)
      )

      -- 4) Vertical 1:1 MOVE displacement proved against live enemy lane coordinates in test_spawn_report:
      -- Advance Stage 1 until the first enemy spawns at x in [180, 310]; verify dragging far off-lane misses,
      -- while dragging exact dy = enemy.y - 112 aligns Lance vertically to hit the enemy with vulcan.
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE vertical miss control")
      local r_spawn_miss = H.advance_until(function(rep)
        return rep.enemies and #rep.enemies >= 1 and rep.enemies[1].x >= 180 and rep.enemies[1].x <= 310
      end, H.secs(4.0), 3, "await first enemy for vertical miss probe")
      assert_contract(r_spawn_miss ~= nil and #r_spawn_miss.enemies >= 1, "expected deterministic Stage 1 enemy")
      local e_miss = r_spawn_miss.enemies[1]
      local miss_dy = (e_miss.y >= 112) and -64 or 64
      send_touch({ pt(1, 90, 112, true, false, DEFAULT_VP) }, 1, "press MOVE for off-lane shift")
      send_touch({ pt(1, 90, 112 + miss_dy, false, false, DEFAULT_VP) }, 2, "drag vertically away from enemy")
      send_touch({ pt(1, 90, 112 + miss_dy, false, true, DEFAULT_VP) }, 1, "release MOVE off-lane")
      local mark_miss = H.mark_events()
      tap_logical(2, 240, 60, 1, H.secs(1.10), DEFAULT_VP, "fire vulcan off-lane")
      assert_contract(
        not H.has_cue_since(mark_miss, "enemy_hit") and #H.events_since(mark_miss, "enemy_killed") == 0,
        "vertical MOVE drag away from enemy lane must shift vulcan shot clear of the target"
      )

      -- Now repeat deterministic Stage 1 run and drag exact dy = target_y - 112 to strike the enemy!
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE vertical alignment hit")
      local r_spawn_hit = H.advance_until(function(rep)
        return rep.enemies and #rep.enemies >= 1 and rep.enemies[1].x >= 180 and rep.enemies[1].x <= 310
      end, H.secs(4.0), 3, "await first enemy for vertical hit probe")
      assert_contract(r_spawn_hit ~= nil and #r_spawn_hit.enemies >= 1, "expected deterministic Stage 1 enemy")
      local mark_hit = H.mark_events()
      -- Track the enemy's live Y slightly ahead (3 rapid vulcan taps spaced 4 ticks while matching enemy.y)
      local base_ly = 112
      send_touch({ pt(1, 90, base_ly, true, false, DEFAULT_VP) }, 1, "press MOVE for vertical align")
      local align_dy = math.max(-72, math.min(72, r_spawn_hit.enemies[1].y - 112))
      send_touch({ pt(1, 90, base_ly + align_dy, false, false, DEFAULT_VP) }, 1, "drag exact dy to enemy Y")
      send_touch({ pt(1, 90, base_ly + align_dy, false, true, DEFAULT_VP) }, 1, "release aligned MOVE")
      tap_logical(2, 240, 60, 1, 3, DEFAULT_VP, "aligned vulcan tap 1")
      tap_logical(2, 240, 60, 1, H.secs(1.10), DEFAULT_VP, "aligned vulcan tap 2")
      assert_contract(
        H.has_cue_since(mark_hit, "enemy_hit") or #H.events_since(mark_hit, "enemy_killed") >= 1,
        "1:1 vertical MOVE drag by (enemy.y - 112) must align Lance to strike the enemy (atomic requirement 34)"
      )
    end)

    test("MOVE drag clamps ship centre to x=16..304 and y=32..192 logical pixels", function()
      -- Left clamp x=16: drag -100 px vs -160 px from start x=64 -> both clamp at x=16 (~67 Force launch ticks)
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE left clamp A")
      H.collect_powerup("red", nil, "Force left clamp A")
      send_touch({ pt(1, 170, 112, true, false, DEFAULT_VP) }, 1, "press MOVE")
      send_touch({ pt(1, 70, 112, false, false, DEFAULT_VP) }, 2, "drag -100 px")
      send_touch({ pt(1, 70, 112, false, true, DEFAULT_VP) }, 1, "release MOVE")
      local left_a = H.measure_launch_ticks_from_front(110, "left clamp A launch")

      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE left clamp B")
      H.collect_powerup("red", nil, "Force left clamp B")
      send_touch({ pt(1, 180, 112, true, false, DEFAULT_VP) }, 1, "press MOVE")
      send_touch({ pt(1, 20, 112, false, false, DEFAULT_VP) }, 2, "drag -160 px")
      send_touch({ pt(1, 20, 112, false, true, DEFAULT_VP) }, 1, "release MOVE")
      local left_b = H.measure_launch_ticks_from_front(110, "left clamp B launch")

      assert_contract(
        H.near(left_a, 67, 4) and math.abs(left_a - left_b) <= 1,
        "leftward MOVE drag must clamp ship centre at x=16 (~67 launch ticks), got "
          .. tostring(left_a) .. " vs " .. tostring(left_b)
      )

      -- Right clamp x=304: two +160 px strokes (64 + 320 = 384 -> 304) vs three +160 px strokes
      local function measure_right_touch_clamp(strokes, tag)
        start_play_via_touch(1, DEFAULT_VP, tag)
        H.collect_powerup("red", nil, "Force right clamp")
        for s = 1, strokes do
          send_touch({ pt(1, 16, 112, true, false, DEFAULT_VP) }, 1, tag .. " press " .. tostring(s))
          send_touch({ pt(1, 176, 112, false, false, DEFAULT_VP) }, 2, tag .. " drag +160")
          send_touch({ pt(1, 176, 112, false, true, DEFAULT_VP) }, 1, tag .. " release")
        end
        return measure_launch_ticks_from_right_half(140, tag)
      end

      local right_2 = measure_right_touch_clamp(2, "AR-34 MOVE right clamp 2 strokes")
      local right_3 = measure_right_touch_clamp(3, "AR-34 MOVE right clamp 3 strokes")
      assert_contract(
        right_2 >= 70 and math.abs(right_2 - right_3) <= 1,
        "rightward MOVE drag must clamp ship centre at x=304; launch ticks "
          .. tostring(right_2) .. " vs " .. tostring(right_3)
      )

      -- Upper vertical clamp y=192: inside 2.0 s respawn protection, stroke 1 drags +150 px up
      -- (112+150 -> clamps at 192) and releases; stroke 2 drags -44 px down (192-44 = 148 clear
      -- channel; unclamped 262-44 = 218 would remain out of bounds/in terrain), then waits past
      -- invulnerability expiry ( staying clear of first enemy at y~148 by shooting or checking at 2.15 s).
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE upper clamp y=192")
      H.post("player_hit", { source_id = "qa-touch-top-clamp" })
      local r_top = H.advance(H.secs(1.10), "respawn with 2.0 s invulnerability")
      assert_contract(r_top.lives == 2, "expected 2 lives on respawn")
      send_touch({ pt(1, 90, 40, true, false, DEFAULT_VP) }, 1, "stroke 1 press low in MOVE")
      send_touch({ pt(1, 90, 190, false, false, DEFAULT_VP) }, 2, "stroke 1 drag +150 px to upper clamp y=192")
      send_touch({ pt(1, 90, 190, false, true, DEFAULT_VP) }, 1, "stroke 1 release at y=192 clamp")
      send_touch({ pt(1, 90, 160, true, false, DEFAULT_VP) }, 1, "stroke 2 press")
      send_touch({ pt(1, 90, 116, false, false, DEFAULT_VP) }, 2, "stroke 2 drag -44 px down into safe channel y=148")
      local r_top_after = send_touch({ pt(1, 90, 116, false, true, DEFAULT_VP) }, H.secs(2.15), "survive past 2.0 s invuln expiry")
      assert_contract(
        r_top_after.lives == 2,
        "upward MOVE drag must clamp at y=192 so a subsequent -44 px stroke returns cleanly into safe playfield (atomic requirement 34)"
      )

      -- Lower vertical clamp y=32: stroke 1 drags -150 px down (112-150 -> clamps at 32) and releases;
      -- stroke 2 drags +44 px up (32+44 = 76 safe channel; unclamped -38+44 = 6 would remain out of bounds)
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE lower clamp y=32")
      H.post("player_hit", { source_id = "qa-touch-bot-clamp" })
      local r_bot = H.advance(H.secs(1.10), "respawn with 2.0 s invulnerability")
      assert_contract(r_bot.lives == 2, "expected 2 lives on respawn")
      send_touch({ pt(1, 90, 190, true, false, DEFAULT_VP) }, 1, "stroke 1 press high in MOVE")
      send_touch({ pt(1, 90, 40, false, false, DEFAULT_VP) }, 2, "stroke 1 drag -150 px to lower clamp y=32")
      send_touch({ pt(1, 90, 40, false, true, DEFAULT_VP) }, 1, "stroke 1 release at y=32 clamp")
      send_touch({ pt(1, 90, 60, true, false, DEFAULT_VP) }, 1, "stroke 2 press")
      send_touch({ pt(1, 90, 104, false, false, DEFAULT_VP) }, 2, "stroke 2 drag +44 px up into safe channel y=76")
      local r_bot_after = send_touch({ pt(1, 90, 104, false, true, DEFAULT_VP) }, H.secs(2.15), "survive past 2.0 s invuln expiry")
      assert_contract(
        r_bot_after.lives == 2,
        "downward MOVE drag must clamp at y=32 so a subsequent +44 px stroke returns cleanly into safe playfield (atomic requirement 34)"
      )
    end)

    test("viewport_map change mid-drag rebases active touch anchors without jumping the ship", function()
      start_play_via_touch(1, { scale = 3, ox = 0, oy = 0 }, "AR-34 mid-drag viewport rebase")
      H.collect_powerup("red", nil, "Force for rebase probe")

      -- At scale=3, ox=0: press at sx=300 (lx=100), drag to sx=360 (lx=120 -> +20 px -> ship.x = 84)
      send_touch({ pt_raw(1, 300, 336, true, false) }, 1, "press MOVE at sx=300 (lx=100)")
      send_touch({ pt_raw(1, 360, 336, false, false) }, 2, "drag to sx=360 (lx=120, ship.x=84)")

      -- Resize mid-drag to scale=2, ox=0! Under scale=2, stationary sx=360 maps to lx=180 (+60 px jump if not rebased!)
      H.post("viewport_map", { scale = 2, ox = 0, oy = 0 })
      H.advance(1, "apply mid-drag viewport_map resize")

      -- Stationary finger sample at sx=360, then +20 screen px (+10 logical px at scale=2) to sx=380 -> ship.x = 94
      send_touch({ pt_raw(1, 360, 336, false, false) }, 1, "stationary sample right after resize")
      send_touch({ pt_raw(1, 380, 336, false, false) }, 2, "drag +10 logical px at scale=2 to sx=380")
      send_touch({ pt_raw(1, 380, 336, false, true) }, 2, "release rebased drag")

      local ticks_rebased = H.measure_launch_ticks_from_front(100, "launch probe after mid-drag rebase")
      -- Expected at ship.x = 94: (240 - 94) * 0.3 = 43.8 ticks (~44; un-rebased jump to x=154 would give ~26 ticks)
      assert_contract(
        H.near(ticks_rebased, 44, 4),
        "changing viewport_map mid-drag must rebase active drag anchors without jumping the ship (~44 launch ticks at x=94, not ~26), got "
          .. tostring(ticks_rebased)
      )
    end)

    test("right-lower FIRE zone (192<=x<=320, 24<=y<112) fires vulcan on press, charges tiers 1..3 and releases wave", function()
      start_play_via_touch(1, DEFAULT_VP, "AR-34 FIRE sub-tier tap & hold")

      -- Sub-0.60 s hold (0.45 s = 27 ticks): 1 vulcan shot on press, charge_rise after 0.30 s, zero wave_fire on release
      local mark_sub = H.mark_events()
      send_touch({ pt(1, 240, 60, true, false, DEFAULT_VP) }, 1, "FIRE press")
      assert_contract(
        H.count_cue_since(mark_sub, "shot") == 1,
        "FIRE touch press must emit exactly one vulcan shot immediately (atomic requirement 34)"
      )
      send_touch({ pt(1, 240, 60, false, false, DEFAULT_VP) }, 26, "hold FIRE to 0.45 s")
      assert_contract(
        H.count_cue_since(mark_sub, "shot") == 1 and H.count_cue_since(mark_sub, "charge_rise") == 1,
        "continuous FIRE touch hold must emit zero auto-fire vulcan shots and start charge_rise at 0.30 s"
      )
      send_touch({ pt(1, 240, 60, false, true, DEFAULT_VP) }, 3, "release FIRE below 0.60 s")
      assert_contract(
        not H.has_cue_since(mark_sub, "wave_fire"),
        "releasing FIRE touch below 0.60 s must emit no wave beam"
      )

      -- Full tier progression: 0.25 s (tier 0) -> 0.55 s (tier 0, fraction>0) -> 0.63 s (tier 1) -> 1.13 s (tier 2) -> 1.83 s (tier 3) -> release
      start_play_via_touch(1, DEFAULT_VP, "AR-34 FIRE full wave tiers")
      local mark_all = H.mark_events()
      send_touch({ pt(1, 250, 70, true, false, DEFAULT_VP) }, 15, "hold FIRE 0.25 s")
      send_touch({ pt(1, 250, 70, false, false, DEFAULT_VP) }, 18, "hold FIRE 0.55 s total")
      local sub_ev = H.events_since(mark_all, "wave_charge")
      local max_t0, max_f0 = 0, 0
      for i = 1, #sub_ev do
        if (sub_ev[i].msg.tier or 0) > max_t0 then max_t0 = sub_ev[i].msg.tier end
        if (sub_ev[i].msg.fraction or 0) > max_f0 then max_f0 = sub_ev[i].msg.fraction end
      end
      assert_contract(max_t0 == 0 and max_f0 > 0, "FIRE touch hold between 0.30 s and 0.60 s must raise fraction at tier 0")

      local mark_t1 = H.mark_events()
      send_touch({ pt(1, 250, 70, false, false, DEFAULT_VP) }, 5, "hold FIRE 0.63 s -> Tier 1")
      local ev1 = H.events_since(mark_t1, "wave_charge")
      assert_contract(#ev1 > 0 and ev1[#ev1].msg.tier == 1, "FIRE touch hold at 0.60 s must reach wave tier 1")

      local mark_t2 = H.mark_events()
      send_touch({ pt(1, 250, 70, false, false, DEFAULT_VP) }, 30, "hold FIRE 1.13 s -> Tier 2")
      local ev2 = H.events_since(mark_t2, "wave_charge")
      assert_contract(#ev2 > 0 and ev2[#ev2].msg.tier == 2, "FIRE touch hold at 1.10 s must reach wave tier 2")

      local mark_t3 = H.mark_events()
      send_touch({ pt(1, 250, 70, false, false, DEFAULT_VP) }, 42, "hold FIRE 1.83 s -> Tier 3")
      local ev3 = H.events_since(mark_t3, "wave_charge")
      assert_contract(
        #ev3 > 0 and ev3[#ev3].msg.tier == 3 and H.near(ev3[#ev3].msg.fraction, 1.0, 0.05),
        "FIRE touch hold at 1.80 s must reach wave tier 3 with fraction=1.0"
      )

      local mark_rel = H.mark_events()
      send_touch({ pt(1, 250, 70, false, true, DEFAULT_VP) }, 3, "release Tier-3 touch wave")
      local ev_reset = H.events_since(mark_rel, "wave_charge")
      assert_contract(
        H.has_cue_since(mark_rel, "wave_fire")
          and #ev_reset > 0
          and ev_reset[#ev_reset].msg.tier == 0
          and H.near(ev_reset[#ev_reset].msg.fraction, 0.0, 0.01),
        "releasing Tier-3 FIRE touch must launch wave_fire and reset BEAM gauge to 0"
      )
    end)

    test("zone ownership is captured on press until release so crossing zone boundaries creates no extra edges", function()
      -- 1) Press in FIRE (240, 80), slide into FORCE (240, 150) and MOVE (100, 150) over 40 ticks (Tier 1), then release:
      --    must NOT launch Force or move ship, and release must still fire the charged Tier-1 wave!
      start_play_via_touch(1, DEFAULT_VP, "AR-34 FIRE capture across FORCE and MOVE")
      H.collect_powerup("red", nil, "Force for boundary capture probe")
      local mark_fire = H.mark_events()
      send_touch({ pt(1, 240, 80, true, false, DEFAULT_VP) }, 10, "press in FIRE")
      send_touch({ pt(1, 240, 150, false, false, DEFAULT_VP) }, 15, "slide across y=112 into FORCE")
      local r_mid = send_touch({ pt(1, 100, 150, false, false, DEFAULT_VP) }, 15, "slide across x=192 into MOVE (0.67 s total)")
      assert_contract(
        H.count_cue_since(mark_fire, "shot") == 1
          and not H.has_cue_since(mark_fire, "force_launch")
          and r_mid.force.state == "attached_front",
        "sliding a captured FIRE touch across FORCE and MOVE boundaries must create no extra fire or Force edges (design section 4 addendum)"
      )
      local mark_rel = H.mark_events()
      send_touch({ pt(1, 100, 150, false, true, DEFAULT_VP) }, 2, "release captured FIRE finger inside MOVE coords")
      assert_contract(
        H.has_cue_since(mark_rel, "wave_fire"),
        "releasing a captured FIRE finger after sliding outside the FIRE zone must still release its charged wave"
      )
      local ticks_still_64 = H.measure_launch_ticks_from_front(100, "verify FIRE slide did not drag ship")
      assert_contract(
        H.near(ticks_still_64, 53, 4),
        "captured FIRE finger sliding into MOVE coordinates must not move the ship from x=64 (~53 launch ticks), got "
          .. tostring(ticks_still_64)
      )

      -- 2) Press in MOVE (140, 96) and drag rightward +80 px across x=192 into FIRE (220, 96) and upward +28 px across y=112 into FORCE (220, 124):
      --    keeps ship.y = 112+28 = 140 clear of ceiling terrain while moving ship.x by +80 px (x=144 -> ~29 launch ticks) without firing vulcan or launching Force!
      start_play_via_touch(1, DEFAULT_VP, "AR-34 MOVE capture across FIRE and FORCE")
      H.collect_powerup("red", nil, "Force for MOVE boundary probe")
      local mark_move = H.mark_events()
      send_touch({ pt(2, 140, 96, true, false, DEFAULT_VP) }, 1, "press in MOVE")
      send_touch({ pt(2, 220, 96, false, false, DEFAULT_VP) }, 2, "drag +80 px across x=192 into FIRE coords")
      local r_mv = send_touch({ pt(2, 220, 124, false, false, DEFAULT_VP) }, 2, "drag +28 px across y=112 into FORCE coords")
      send_touch({ pt(2, 220, 124, false, true, DEFAULT_VP) }, 2, "release MOVE finger")
      assert_contract(
        H.count_cue_since(mark_move, "shot") == 0
          and not H.has_cue_since(mark_move, "force_launch")
          and r_mv.force.state == "attached_front",
        "dragging a captured MOVE finger into FIRE/FORCE coordinates must emit neither vulcan shot nor Force launch"
      )
      local ticks_144 = H.measure_launch_ticks_from_front(100, "verify MOVE drag continued past x=192")
      -- ship.x = 64 + 80 = 144 -> (240 - 144) * 0.3 = 28.8 ticks
      assert_contract(
        H.near(ticks_144, 29, 4),
        "captured MOVE drag crossing x=192 by +80 px must still displace ship to x=144 (~29 launch ticks), got "
          .. tostring(ticks_144)
      )
    end)

    test("right-upper FORCE zone (192<=x<=320, 112<=y<=200) is a no-op when unacquired and launches/recalls once per press", function()
      local r0 = start_play_via_touch(1, DEFAULT_VP, "AR-34 FORCE unacquired & acquired")
      assert_contract(r0.force.level == 0, "fresh run starts with unacquired Force")

      -- Unacquired FORCE tap: force_state unchanged, zero cues
      local state_before = r0.force.state
      local mark_unacq = H.mark_events()
      local r_unacq = tap_logical(1, 240, 150, 3, 3, DEFAULT_VP, "tap FORCE while unacquired")
      local fs_events = H.events_since(mark_unacq, "force_state")
      for i = 1, #fs_events do
        assert_contract(
          fs_events[i].msg.level == 0 and fs_events[i].msg.state == state_before,
          "FORCE touch while unacquired must leave force_state unchanged"
        )
      end
      assert_contract(
        r_unacq.force.level == 0
          and r_unacq.force.state == state_before
          and not H.has_cue_since(mark_unacq, "force_launch")
          and H.count_cue_since(mark_unacq, "shot") == 0,
        "right-upper FORCE tap without Force acquired must be a no-op (atomic requirement 34)"
      )

      -- Acquire L1 Force -> press & hold FORCE for 12 ticks before release -> launches once to x=264 (~53 ticks total)
      H.collect_powerup("red", nil, "acquire L1 Force")
      local mark_launch = H.mark_events()
      send_touch({ pt(2, 240, 150, true, false, DEFAULT_VP) }, 12, "press & hold FORCE")
      send_touch({ pt(2, 240, 150, false, true, DEFAULT_VP) }, 46, "release FORCE and let pod settle at x=264")
      local r_det = H.advance(2, "check detached state")
      assert_contract(
        H.has_cue_since(mark_launch, "force_launch") and r_det.force.state == "detached",
        "FORCE touch press with acquired pod must launch once to 'detached' without recalling on release (atomic requirement 34), got '"
          .. tostring(r_det.force.state) .. "'"
      )

      -- Second FORCE tap recalls detached pod back to ship
      local r_rec = tap_logical(3, 240, 150, 1, 2, DEFAULT_VP, "tap FORCE to recall")
      assert_contract(
        r_rec.force.state == "recalling",
        "second FORCE touch tap on detached pod must enter 'recalling' state, got '" .. tostring(r_rec.force.state) .. "'"
      )
      local r_att = H.advance_until(function(rep)
        return rep.force.state == "attached_front" or rep.force.state == "attached_rear"
      end, 100, 3, "complete touch Force recall")
      assert_contract(
        r_att ~= nil and r_att.force.state == "attached_front",
        "recalled Force must re-attach to ship"
      )
    end)

    test("pause button (x=300..316, y=184..196) takes priority over FORCE and toggles pause, as does a two-finger tap", function()
      start_play_via_touch(1, DEFAULT_VP, "AR-34 pause button & two-finger tap")
      H.collect_powerup("red", nil, "acquire L1 Force to test hit-test priority")
      H.advance(20, "scroll slightly before pause")

      -- 1) Pause button tap at (308, 190) overlaps upper-right quadrant but MUST take priority over FORCE!
      local mark_btn = H.mark_events()
      local r_btn_pause = tap_logical(1, 308, 190, 1, 2, DEFAULT_VP, "tap top-right pause button")
      assert_contract(
        r_btn_pause.screen == "pause"
          and r_btn_pause.force.state == "attached_front"
          and not H.has_cue_since(mark_btn, "force_launch"),
        "top-right pause button (x=300..316, y=184..196) must take hit-test priority over FORCE and enter 'pause' (design section 4 addendum), got screen='"
          .. tostring(r_btn_pause.screen) .. "' force='" .. tostring(r_btn_pause.force.state) .. "'"
      )
      local scroll_paused = r_btn_pause.scroll_px
      local r_frozen = H.advance(60, "advance 1.0 s while touch-paused")
      assert_contract(
        r_frozen.screen == "pause" and H.near(r_frozen.scroll_px, scroll_paused, 0.001),
        "touch pause must freeze simulation through the shared input_pause handler"
      )

      -- Tap pause button again on 'pause' -> resumes 'play'
      local r_btn_resume = tap_logical(1, 308, 190, 1, 2, DEFAULT_VP, "tap pause button to resume")
      assert_contract(
        r_btn_resume.screen == "play" and r_btn_resume.force.state == "attached_front",
        "pause button must remain usable on 'pause' screen to resume 'play' without launching Force, got '"
          .. tostring(r_btn_resume.screen) .. "'"
      )

      -- 2) Simultaneous two-finger tap anywhere toggles play -> pause, and again resumes pause -> play
      send_touch({
        pt(1, 90, 100, true, false, DEFAULT_VP),
        pt(2, 220, 100, true, false, DEFAULT_VP),
      }, 2, "two-finger tap press to pause")
      local r_2f_pause = send_touch({
        pt(1, 90, 100, false, true, DEFAULT_VP),
        pt(2, 220, 100, false, true, DEFAULT_VP),
      }, 2, "two-finger tap release to pause")
      assert_contract(
        r_2f_pause.screen == "pause",
        "simultaneous two-finger tap must send input_pause and enter 'pause' (atomic requirement 34), got '"
          .. tostring(r_2f_pause.screen) .. "'"
      )

      send_touch({
        pt(1, 90, 100, true, false, DEFAULT_VP),
        pt(2, 220, 100, true, false, DEFAULT_VP),
      }, 2, "two-finger tap press to resume")
      local r_2f_resume = send_touch({
        pt(1, 90, 100, false, true, DEFAULT_VP),
        pt(2, 220, 100, false, true, DEFAULT_VP),
      }, 2, "two-finger tap release to resume")
      assert_contract(
        r_2f_resume.screen == "play",
        "simultaneous two-finger tap while paused must resume 'play' (atomic requirement 34), got '"
          .. tostring(r_2f_resume.screen) .. "'"
      )
    end)

    test("independent MOVE drag + FIRE charge two-finger play never pauses and ignores a third concurrent finger", function()
      start_play_via_touch(1, DEFAULT_VP, "AR-34 independent MOVE+FIRE & 3rd finger ignored")
      H.collect_powerup("red", nil, "Force to verify 3rd finger ignored")

      -- Finger 1 begins MOVE drag (+30 px: lx 80 -> 110) before Finger 2 presses FIRE
      send_touch({ pt(1, 80, 112, true, false, DEFAULT_VP) }, 2, "finger 1 press MOVE")
      send_touch({ pt(1, 110, 112, false, false, DEFAULT_VP) }, 8, "finger 1 drag +30 px")

      -- Finger 2 presses FIRE while Finger 1 stays held: must fire vulcan and NOT trigger two-finger pause!
      local mark_multi = H.mark_events()
      local r_both = send_touch({
        pt(1, 110, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, true, false, DEFAULT_VP),
      }, 4, "finger 2 press FIRE while finger 1 holds MOVE")
      assert_contract(
        r_both.screen == "play" and H.count_cue_since(mark_multi, "shot") == 1,
        "independent MOVE drag + FIRE press must remain in 'play' without accidental two-finger pause (design section 4 addendum), got screen='"
          .. tostring(r_both.screen) .. "'"
      )

      -- While fingers 1 and 2 are active, a 3rd concurrent finger taps FORCE (240, 150) and pause button (308, 190): must be ignored!
      local r_3rd_a = send_touch({
        pt(1, 125, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, false, DEFAULT_VP),
        pt(3, 240, 150, true, false, DEFAULT_VP),
      }, 2, "3rd concurrent finger press in FORCE")
      send_touch({
        pt(1, 125, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, false, DEFAULT_VP),
        pt(3, 240, 150, false, true, DEFAULT_VP),
      }, 2, "3rd concurrent finger release in FORCE")
      local r_3rd_b = send_touch({
        pt(1, 140, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, false, DEFAULT_VP),
        pt(4, 308, 190, true, false, DEFAULT_VP),
      }, 2, "3rd concurrent finger press on pause button")
      send_touch({
        pt(1, 140, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, false, DEFAULT_VP),
        pt(4, 308, 190, false, true, DEFAULT_VP),
      }, 30, "3rd finger release + continue holding finger 2 past 0.60 s Tier 1 while finger 1 sits at +60 px")

      assert_contract(
        r_3rd_a.screen == "play"
          and r_3rd_b.screen == "play"
          and r_3rd_b.force.state == "attached_front"
          and not H.has_cue_since(mark_multi, "force_launch"),
        "a third concurrent touch must be completely ignored while MOVE and FIRE fingers are tracked (design section 4 addendum)"
      )

      -- Release Finger 2 (fires Tier-1 wave!) while Finger 1 stays down, then release Finger 1
      local mark_rel2 = H.mark_events()
      send_touch({
        pt(1, 140, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, true, DEFAULT_VP),
      }, 2, "release finger 2 FIRE")
      local r_end = send_touch({
        pt(1, 140, 112, false, true, DEFAULT_VP),
      }, 2, "release finger 1 MOVE")

      assert_contract(
        r_end.screen == "play" and H.has_cue_since(mark_rel2, "wave_fire"),
        "independent multi-touch FIRE finger must charge and release wave_fire while MOVE finger is held"
      )
      local ticks_multi = H.measure_launch_ticks_from_front(100, "verify multi-touch MOVE reached x=124")
      assert_contract(
        H.near(ticks_multi, 35, 3),
        "independent multi-touch MOVE finger must displace ship +60 px to x=124 (~35 launch ticks), got "
          .. tostring(ticks_multi)
      )
    end)

    test("pause and death clear captured fingers without releasing waves, and keyboard commands remain unaffected after touch", function()
      -- 1) Pause cancels held MOVE and Tier-1 FIRE captures; stale post-resume drag/release are ignored
      start_play_via_touch(1, DEFAULT_VP, "AR-34 pause cancels active touch captures")
      H.collect_powerup("red", nil, "Force for pause cancel probe")
      send_touch({ pt(1, 80, 112, true, false, DEFAULT_VP) }, 2, "press MOVE before pause")
      send_touch({
        pt(1, 80, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, true, false, DEFAULT_VP),
      }, H.secs(0.75), "hold MOVE + Tier-1 FIRE before pause")

      -- Pause & resume via command path while fingers were captured
      H.post("input_pause", {})
      H.advance(2, "enter pause")
      local mark_post_pause = H.mark_events()
      H.post("input_pause", {})
      H.advance(2, "resume from pause")

      -- Stale finger 1 drags +80 px without fresh press; stale finger 2 releases cancelled Tier-1 hold
      send_touch({
        pt(1, 160, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, true, DEFAULT_VP),
      }, 3, "stale drag + stale fire release after pause")
      send_touch({ pt(1, 160, 112, false, true, DEFAULT_VP) }, 2, "stale MOVE release")

      assert_contract(
        not H.has_cue_since(mark_post_pause, "wave_fire"),
        "releasing a pause-cancelled touch FIRE hold must NOT launch a wave beam (design section 4 addendum)"
      )
      local ticks_after_pause_stale = H.measure_launch_ticks_from_front(100, "verify stale MOVE after pause ignored")
      assert_contract(
        H.near(ticks_after_pause_stale, 53, 4),
        "stale MOVE finger movement after pause/resume must be ignored until a fresh press (~53 launch ticks at x=64), got "
          .. tostring(ticks_after_pause_stale)
      )

      -- 2) Death cancels held MOVE and Tier-1 FIRE captures; stale release/drag after respawn are ignored
      start_play_via_touch(1, DEFAULT_VP, "AR-34 death cancels active touch captures")
      H.collect_powerup("red", nil, "Force retained at L1 on death")
      send_touch({ pt(1, 80, 112, true, false, DEFAULT_VP) }, 2, "press MOVE before death")
      send_touch({
        pt(1, 100, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, true, false, DEFAULT_VP),
      }, H.secs(0.75), "hold MOVE + Tier-1 FIRE before death")

      local mark_die = H.mark_events()
      H.post("player_hit", { source_id = "qa-touch-cancel-death" })
      H.advance(3, "lethal hit cancels touch captures")
      send_touch({
        pt(1, 100, 112, false, false, DEFAULT_VP),
        pt(2, 240, 60, false, true, DEFAULT_VP),
      }, H.secs(1.15), "stale fire release across 1.0 s death respawn")
      assert_contract(
        not H.has_cue_since(mark_die, "wave_fire"),
        "releasing a death-cancelled touch FIRE hold must NOT launch a wave beam"
      )
      -- After respawn at x=64, stale finger 1 moves +80 px without fresh press -> must be ignored!
      send_touch({ pt(1, 180, 112, false, false, DEFAULT_VP) }, 2, "stale MOVE drag after respawn")
      send_touch({ pt(1, 180, 112, false, true, DEFAULT_VP) }, 2, "stale MOVE release after respawn")

      -- 3) Keyboard / shared command path remains completely unaffected after touch use:
      --    move right 0.50 s at 80 px/s (+40 px: x=64 -> x=104), charge & fire Tier-1 wave, pause/resume, and Force launch (~41 ticks)!
      H.move_for(1, 0, 30, "keyboard move right +40 px to x=104 after touch use")
      local mark_kb = H.mark_events()
      H.hold_and_release_fire(H.secs(0.68), 3, "keyboard Tier-1 wave after touch use")
      assert_contract(
        H.count_cue_since(mark_kb, "shot") == 1 and H.has_cue_since(mark_kb, "wave_fire"),
        "keyboard fire edge and wave charging must remain unaffected after touch controls are activated"
      )
      H.post("input_pause", {})
      local r_kb_p = H.advance(2, "keyboard pause after touch")
      H.post("input_pause", {})
      local r_kb_res = H.advance(2, "keyboard resume after touch")
      assert_contract(
        r_kb_p.screen == "pause" and r_kb_res.screen == "play",
        "keyboard pause toggle must remain unaffected after touch use"
      )
      local ticks_kb_104 = H.measure_launch_ticks_from_front(100, "keyboard Force launch from x=104")
      -- If stale death finger had moved ship +80 px to x=144 (+40 kb = 184 > 160), launch would go left (~46+ ticks);
      -- at exact x=104 (stale drag ignored + 40 px keyboard move): (240 - 104) * 0.3 = 40.8 ticks!
      assert_contract(
        H.near(ticks_kb_104, 41, 4),
        "stale post-death drag must be ignored and keyboard movement must move ship to x=104 (~41 launch ticks), got "
          .. tostring(ticks_kb_104)
      )
    end)
  end)
end
