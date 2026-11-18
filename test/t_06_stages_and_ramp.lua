-- test/t_06_stages_and_ramp.lua -- Ten-stage scroll schedule (1920 px at 24 px/s,
-- 60% checkpoint at 1152 px, boss scroll lock) and gentle difficulty ramp across
-- stages 1..10 (spawn cadence 2.40->1.50 s, bullet speed 36->63 px/s, boss HP
-- 120->300, caps <=8 ordinary enemies and <=10 hostile bullets; Atomic Requirements 24 & 25).

local H = require "test.harness"
local G = require "test.gdd_data"

return function()
  describe("Ten-stage scrolling, checkpoints, boss locks and gentle difficulty ramp", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("stages 1..10 each scroll 1920 px at 24 px/s, fire checkpoint at 1152 px and lock until boss defeat", function()
      for i = 1, #G.STAGES do
        local st = G.STAGES[i]
        local r0 = H.start_play(st.stage, "AR-24 stage " .. tostring(st.stage))
        assert_contract(
          H.near(r0.scroll_px, 0, 1.0),
          "Stage " .. tostring(st.stage) .. " must begin at scroll_px=0"
        )
        -- Equip front Force L3 + 2 Bits and actively pilot so enemy fire never interrupts scroll-rate measurement
        H.collect_powerup("red", nil, "L1")
        H.collect_powerup("red", nil, "L2")
        H.collect_powerup("red", nil, "L3")
        H.collect_powerup("bit", nil, "bit 1")
        H.collect_powerup("bit", nil, "bit 2")

        -- Note: 5 ticks already elapsed from 5 powerup collections (5 * 0.4 px = 2.0 px).
        -- Pilot remaining 1195 ticks to reach exact 20.00 s (1200 ticks = 480.0 px):
        local r20 = H.pilot_ticks(H.secs(20.0) - 5, { shoot = true }, "Stage " .. tostring(st.stage) .. " 20 s")
        assert_contract(
          H.near(r20.scroll_px, 480.0, 3.0),
          "Stage " .. tostring(st.stage) .. " must scroll at 24 px/s (480 px at 20 s, atomic requirement 24), got "
            .. H.fmt(r20.scroll_px)
        )

        -- 48 s total @ 24 px/s = 1152 px (60% checkpoint)
        local mark_cp = H.mark_events()
        local r49 = H.pilot_ticks(H.secs(29.0), { shoot = true }, "Stage " .. tostring(st.stage) .. " 49 s checkpoint")
        local cps = H.events_since(mark_cp, "checkpoint_reached")
        assert_contract(
          #cps >= 1 and cps[1].msg.stage == st.stage and cps[1].msg.scroll_px == 1152,
          "Stage " .. tostring(st.stage) .. " must emit checkpoint_reached{stage="
            .. tostring(st.stage) .. ", scroll_px=1152} at 60% scroll (atomic requirement 24)"
        )
        assert_contract(r49.boss == nil, "Boss must not engage before 1920 px lock")

        -- 80 s total @ 24 px/s = 1920 px boss lock; advancing another 5 s without shooting must stay locked at 1920 px on 'play'
        local r80 = H.pilot_ticks(H.secs(29.5), { shoot = true }, "Stage " .. tostring(st.stage) .. " 78.5 s")
        r80 = H.pilot_ticks(H.secs(2.0), { shoot = false }, "Stage " .. tostring(st.stage) .. " 80.5 s lock")
        local r85 = H.pilot_ticks(H.secs(5.0), { shoot = false }, "Stage " .. tostring(st.stage) .. " 85.5 s still locked")
        assert_contract(
          H.near(r80.scroll_px, 1920.0, 2.0)
            and H.near(r85.scroll_px, 1920.0, 2.0)
            and r85.screen == "play"
            and r85.boss ~= nil,
          "Stage " .. tostring(st.stage) .. " must lock scroll at 1920 px with active boss and never advance until boss is defeated (atomic requirement 24)"
        )
      end
    end)

    test("gentle ramp scales spawn interval (2.40->1.50 s), bullet threat (36->63 px/s), boss HP (120->300) and enforces <=8 enemies / <=10 bullets", function()
      local stage_seen_ids = {}
      local max_enemies_seen = 0
      local max_bullets_seen = 0
      local boss_hps = {}

      for i = 1, #G.STAGES do
        local st = G.STAGES[i]
        H.start_play(st.stage, "AR-25 ramp stage " .. tostring(st.stage))
        -- Equip shield + 2 bits and dodge WITHOUT shooting so Lance stays alive while natural spawns accumulate
        H.collect_powerup("blue", nil, "shield")
        H.collect_powerup("bit", nil, "bit 1")
        H.collect_powerup("bit", nil, "bit 2")
        local seen = {}
        local seen_count = 0

        -- Sample every 0.50 s (30 ticks) over first 24.0 s of stage scrolling
        for _ = 1, 48 do
          local r = H.pilot_ticks(30, { shoot = false }, "sample stage " .. tostring(st.stage))
          local ordinary_count = #(r.enemies or {})
          if ordinary_count > max_enemies_seen then
            max_enemies_seen = ordinary_count
          end
          if (r.hostile_bullets or 0) > max_bullets_seen then
            max_bullets_seen = r.hostile_bullets
          end
          assert_contract(
            ordinary_count <= 8,
            "Stage " .. tostring(st.stage) .. " exceeded cap of 8 simultaneous ordinary enemies (atomic requirement 25): got "
              .. tostring(ordinary_count)
          )
          assert_contract(
            (r.hostile_bullets or 0) <= 10,
            "Stage " .. tostring(st.stage) .. " exceeded cap of 10 simultaneous hostile bullets (atomic requirement 25): got "
              .. tostring(r.hostile_bullets)
          )
          for e = 1, ordinary_count do
            local sid = r.enemies[e].spawn_id
            if sid and not seen[sid] then
              seen[sid] = true
              seen_count = seen_count + 1
            end
          end
        end
        stage_seen_ids[st.stage] = seen_count

        -- Pilot remaining scroll cleanly to boss lock with 2.0 s quiet tail so initial boss HP is untouched
        local r_boss = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "lock boss stage " .. tostring(st.stage))
        assert_contract(
          r_boss.boss ~= nil and r_boss.boss.hp == st.boss_hp,
          "Stage " .. tostring(st.stage) .. " (" .. st.boss_name .. ") must have initial HP="
            .. tostring(st.boss_hp) .. " (atomic requirement 25), got "
            .. tostring(r_boss.boss and r_boss.boss.hp)
        )
        boss_hps[st.stage] = r_boss.boss.hp

        for _ = 1, 12 do
          local rb = H.pilot_ticks(30, { shoot = false }, "sample boss bullets stage " .. tostring(st.stage))
          assert_contract(
            (rb.hostile_bullets or 0) <= 10,
            "Boss fight on Stage " .. tostring(st.stage) .. " exceeded cap of 10 simultaneous hostile bullets: got "
              .. tostring(rb.hostile_bullets)
          )
        end
      end

      assert_contract(
        stage_seen_ids[10] > stage_seen_ids[1],
        "base spawn interval must tighten from 2.40 s (Stage 1) to 1.50 s (Stage 10), yielding more distinct spawns in 24 s on Stage 10 ("
          .. tostring(stage_seen_ids[10]) .. ") than Stage 1 (" .. tostring(stage_seen_ids[1]) .. ") (atomic requirement 25)"
      )
      assert_contract(
        boss_hps[1] == 120 and boss_hps[10] == 300,
        "boss HP must ramp monotonically from 120 (Stage 1) to 300 (Stage 10) (atomic requirement 25)"
      )
    end)
  end)
end
