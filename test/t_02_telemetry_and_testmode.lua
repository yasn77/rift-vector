-- test/t_02_telemetry_and_testmode.lua -- Bot driver telemetry contract,
-- audio cue triggers, charge-audio stop rules and test_mode determinism
-- (Atomic Requirements 32 & 33, Role sections 3 & 5).

local H = require "test.harness"
local G = require "test.gdd_data"
local driver = require "bot_driver"

local function capture_prints(fn)
  local captured = {}
  local real_print = _G.print
  _G.print = function(...)
    local parts = {}
    local count = select("#", ...)
    for i = 1, count do
      parts[i] = tostring(select(i, ...))
    end
    captured[#captured + 1] = table.concat(parts, "\t")
  end
  local ok, err = pcall(fn)
  _G.print = real_print
  if not ok then
    error(err)
  end
  return captured
end

return function()
  describe("Telemetry discipline, audio requests and test_mode contract", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("bot_driver deterministic Park-Miller stream, silent sequence and scripted showcase", function()
      local bot_silent = driver.new({ seed = 424242 })
      local bot_live = driver.new({ seed = 424242 })
      local total = 680

      local silent_actions
      local silent_logs = capture_prints(function()
        silent_actions = driver.sequence(bot_silent, total)
      end)
      assert_contract(
        #silent_logs == 0,
        "bot_driver.sequence must emit zero STUDIO_TELEMETRY lines (anti-flooding contract), emitted "
          .. tostring(#silent_logs)
      )
      assert_contract(
        #silent_actions == total,
        "bot_driver.sequence must return the requested frame count"
      )

      local live_actions = {}
      local saw_start = false
      local saw_force_count = 0
      local max_fire_hold = 0
      local holding_fire = false
      local current_hold = 0

      local live_logs = capture_prints(function()
        for i = 1, total do
          local act, frame = driver.next(bot_live)
          assert_contract(frame == i, "bot_driver.next frame counter must be 1-based sequential")
          live_actions[i] = act
          if act == "start" then
            saw_start = true
          elseif act == "force" then
            saw_force_count = saw_force_count + 1
          elseif act == "fire_press" then
            holding_fire = true
            current_hold = 0
          elseif act == "fire_release" then
            if holding_fire and current_hold > max_fire_hold then
              max_fire_hold = current_hold
            end
            holding_fire = false
            current_hold = 0
          end
          if holding_fire then
            current_hold = current_hold + 1
          end
        end
      end)

      assert_contract(#live_logs == total, "bot_driver.next must emit exactly one telemetry line per frame")
      for i = 1, total do
        assert_contract(
          live_actions[i] == silent_actions[i],
          "bot_driver.sequence and bot_driver.next must advance the identical Park-Miller stream at frame " .. tostring(i)
        )
      end
      assert_contract(saw_start, "scripted bot session must begin with 'start'")
      assert_contract(
        max_fire_hold >= 108,
        "scripted bot session must hold fire for >=108 frames (1.80 s Tier-3 wave charge), max_hold=" .. tostring(max_fire_hold)
      )
      assert_contract(
        saw_force_count >= 2,
        "scripted bot session must exercise Force launch and recall (>=2 'force' edges)"
      )
      assert_contract(
        driver.scripted_done(bot_live),
        "bot_driver.scripted_done must become true after the scripted showcase completes"
      )

      driver.reset(bot_live)
      local replay = driver.sequence(bot_live, 25)
      for i = 1, 25 do
        assert_contract(
          replay[i] == silent_actions[i],
          "bot_driver.reset must restore exact frame-by-frame reproducibility from seed"
        )
      end
    end)

    test("bot_driver STUDIO_TELEMETRY JSON schema, control-character quoting and message mapping", function()
      local quoted = driver.quote('cue\t"alpha"\\beta\r\n' .. string.char(1))
      assert_contract(
        quoted == '"cue\\t\\"alpha\\"\\\\beta\\r\\n\\u0001"',
        "bot_driver.quote must escape quotes, backslashes and control characters, got: " .. tostring(quoted)
      )

      local bot = driver.new({ seed = 7 })
      local logs = capture_prints(function()
        for _ = 1, 30 do
          driver.next(bot)
        end
      end)

      for i = 1, #logs do
        local line = logs[i]
        assert_contract(
          string.sub(line, 1, 18) == "STUDIO_TELEMETRY {" and string.sub(line, -1) == "}",
          "every telemetry line must match 'STUDIO_TELEMETRY {...}', got: " .. tostring(line)
        )
        assert_contract(
          string.find(line, "\n", 1, true) == nil and string.find(line, "\r", 1, true) == nil,
          "telemetry line must be strictly single-line"
        )
        assert_contract(
          string.find(line, '"event":"bot_input"', 1, true) ~= nil,
          "bot_driver may ONLY emit bot_input on STUDIO_TELEMETRY (atomic requirement 32), got: " .. tostring(line)
        )
        assert_contract(
          string.find(line, '"frame":' .. tostring(i) .. ",", 1, true) ~= nil,
          "bot_input frame field must be a JSON integer, not a string: " .. tostring(line)
        )
      end

      local valid_msgs = {}
      for i = 1, #G.MESSAGE_IDS do
        valid_msgs[G.MESSAGE_IDS[i]] = true
      end
      for i = 1, #driver.ACTIONS do
        local act = driver.ACTIONS[i]
        local id, payload = driver.message(act)
        assert_contract(
          valid_msgs[id] == true and type(payload) == "table",
          "bot_driver action '" .. tostring(act) .. "' must map to a declared message_id"
        )
      end
    end)

    test("test_mode advances ONLY via test_advance, halts wall-clock updates and emits numeric test_spawn_report", function()
      local r0 = H.start_play(1, "AR-33 test_mode stepping")
      assert_contract(
        type(r0.scroll_px) == "number"
          and type(r0.enemies) == "table"
          and type(r0.hostile_bullets) == "number"
          and type(r0.score) == "number"
          and type(r0.lives) == "number"
          and type(r0.screen) == "string"
          and type(r0.force) == "table",
        "test_spawn_report must expose numeric scroll_px, hostile_bullets, score, lives, table enemies/force and string screen (atomic requirement 33)"
      )

      local r1 = H.advance(60, "advance 1.0 s")
      assert_contract(
        H.near(r1.scroll_px, 24.0, 1.0),
        "60 ticks (1.0 s) in test_mode must scroll 24.0 px (24 px/s), got " .. H.fmt(r1.scroll_px)
      )

      -- Sleep 20 real wall-clock frames without test_advance; simulation must stay frozen.
      H.sleep_frames(20)
      local r2 = H.advance(1, "post-sleep 1-tick probe")
      assert_contract(
        H.near(r2.scroll_px - r1.scroll_px, 24.0 / 60.0, 0.6),
        "in test_mode simulation must NOT advance during wall-clock update frames (atomic requirement 33); "
          .. "expected +0.40 px for 1 tick, got +" .. H.fmt(r2.scroll_px - r1.scroll_px)
      )
    end)

    test("test_mode produces deterministic enemy spawns across repeated runs", function()
      H.start_play(1, "AR-33 determinism run A")
      local r_a = H.advance(300, "run A 5.0 s")
      assert_contract(
        #r_a.enemies >= 1,
        "Stage 1 must have spawned at least one deterministic enemy formation by 5.0 s (delta_spawn=2.40 s)"
      )

      H.start_play(1, "AR-33 determinism run B")
      local r_b = H.advance(300, "run B 5.0 s")
      assert_contract(
        H.near(r_a.scroll_px, r_b.scroll_px, 0.01) and #r_a.enemies == #r_b.enemies,
        "seeded test_mode runs must yield identical scroll_px and enemy counts at tick 300"
      )
      for i = 1, #r_a.enemies do
        local ea, eb = r_a.enemies[i], r_b.enemies[i]
        assert_contract(
          ea.spawn_id == eb.spawn_id
            and ea.kind == eb.kind
            and H.near(ea.x, eb.x, 0.01)
            and H.near(ea.y, eb.y, 0.01)
            and ea.hp == eb.hp,
          "enemy #" .. tostring(i) .. " must match deterministically across test_mode runs"
        )
      end
    end)

    test("audio_request cues follow stage/boss music schedule, charge audio stops on release/pause/death and STUDIO_TELEMETRY allows only 7 events", function()
      local ALLOWED_TELEMETRY = {
        bot_input = true,
        audio_play = true,
        audio_cooldown_suppressed = true,
        audio_unlock = true,
        audio_unlock_skipped = true,
        audio_rms = true,
        audio_reset = true,
      }
      local observed_telemetry = {}
      local real_print = _G.print
      _G.print = function(...)
        local parts = {}
        local n = select("#", ...)
        for i = 1, n do
          parts[i] = tostring(select(i, ...))
        end
        local line = table.concat(parts, "\t")
        if string.sub(line, 1, 17) == "STUDIO_TELEMETRY " then
          observed_telemetry[#observed_telemetry + 1] = line
        end
        real_print(...)
      end

      local ok_run, run_err = pcall(function()
        local _, mark_s1 = H.start_play(nil, "AR-32 stage 1 bgm")
        assert_contract(
          H.has_cue_since(mark_s1, "bgm_stage_a"),
          "entering Stage 1 play must request bgm_stage_a (design section 4, audio inventory)"
        )

        local mark_s2 = H.mark_events()
        H.post("test_set_stage", { stage = 2 })
        H.advance(2, "stage 2 bgm")
        assert_contract(
          H.has_cue_since(mark_s2, "bgm_stage_b"),
          "Stage 2 must request bgm_stage_b"
        )
        local mark_s2_boss = H.mark_events()
        H.pilot_to_boss({ shoot = false, allow_continue = true }, "stage 2 boss lock")
        assert_contract(
          H.has_cue_since(mark_s2_boss, "bgm_boss"),
          "ordinary stage boss lock must request bgm_boss (design section 4)"
        )

        local mark_s10 = H.mark_events()
        H.post("test_set_stage", { stage = 10 })
        H.advance(2, "stage 10 scroll bgm")
        assert_contract(
          H.has_cue_since(mark_s10, "bgm_stage_c"),
          "Stage 10 scrolling must use bgm_stage_c before boss lock (design section 4)"
        )
        local mark_lock = H.mark_events()
        H.pilot_to_boss({ shoot = false, allow_continue = true }, "stage 10 boss lock")
        assert_contract(
          H.has_cue_since(mark_lock, "bgm_final_boss"),
          "Stage 10 boss lock must start bgm_final_boss"
        )

        -- 1. Charge audio starts once at 0.30 s and stops cleanly on sub-tier release without wave_fire.
        H.start_play(1, "AR-32 charge stop on release")
        local mark_rel_c = H.mark_events()
        H.post("input_fire_press", {})
        H.advance(H.secs(0.40), "hold past 0.30 s")
        assert_contract(
          H.count_cue_since(mark_rel_c, "charge_rise") == 1,
          "continuous hold past 0.30 s must trigger charge_rise once"
        )
        local mark_after_rise = H.mark_events()
        H.post("input_fire_release", {})
        H.advance(H.secs(0.40), "release at 0.40 s stops charge")
        assert_contract(
          H.count_cue_since(mark_after_rise, "charge_rise") == 0 and not H.has_cue_since(mark_after_rise, "wave_fire"),
          "releasing held fire must stop charge audio without extra charge_rise or sub-0.60 s wave_fire (atomic requirement 32)"
        )

        -- 2. Charge audio stops and held wave cancels on pause.
        H.start_play(1, "AR-32 charge stop on pause")
        H.post("input_fire_press", {})
        H.advance(H.secs(0.75), "reach Tier 1 before pause")
        local mark_pause = H.mark_events()
        H.post("input_pause", {})
        H.advance(2, "pause cancels charge")
        H.post("input_pause", {})
        H.advance(2, "resume from pause")
        H.post("input_fire_release", {})
        H.advance(2, "release after pause")
        assert_contract(
          not H.has_cue_since(mark_pause, "wave_fire"),
          "pause must stop charge audio and cancel held wave so release emits no wave_fire (atomic requirements 27 & 32)"
        )

        -- 3. Charge audio stops and held wave cancels on death.
        H.start_play(1, "AR-32 charge stop on death")
        H.post("input_fire_press", {})
        H.advance(H.secs(0.75), "reach Tier 1 before death")
        local mark_die = H.mark_events()
        H.post("player_hit", { source_id = "qa-charge-death" })
        H.advance(4, "death cancels charge")
        H.post("input_fire_release", {})
        H.advance(4, "release during death")
        assert_contract(
          H.has_cue_since(mark_die, "player_die") and not H.has_cue_since(mark_die, "wave_fire"),
          "death must stop charge audio and cancel held wave without firing wave_fire (atomic requirement 32)"
        )
      end)
      _G.print = real_print
      if not ok_run then
        error(run_err)
      end

      for i = 1, #observed_telemetry do
        local line = observed_telemetry[i]
        local ev = string.match(line, '"event"%s*:%s*"([^"]+)"')
        assert_contract(
          ev ~= nil and ALLOWED_TELEMETRY[ev] == true,
          "only the seven allowed STUDIO_TELEMETRY event types may enter that channel (atomic requirement 32), got: "
            .. tostring(line)
        )
      end
    end)
  end)
end
