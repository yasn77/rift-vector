-- test/t_05_economy_death_score.lua -- Carrier 12 s drop schedule, death and
-- checkpoint respawn, Force L1 retention + 2 s invulnerability, Continue economy,
-- kill scoring & (stage, spawn_id) deduplication, boss/no-miss bonuses, and
-- sys.save hi-score persistence & corrupt-file resilience (Atomic Requirements 17..23).

local H = require "test.harness"
local G = require "test.gdd_data"

return function()
  describe("Carrier economy, death/checkpoint, continue, scoring and hi-score persistence", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("carriers arrive every 12 s of scrolling, drop red/blue/bit/yellow/missile/speed in order and convert capped speed to blue crystal", function()
      for slot = 1, #G.CARRIER_DROPS do
        local expected_kind = G.CARRIER_DROPS[slot]
        local target_s = 12 * slot
        H.start_play(1, "AR-17 carrier slot " .. tostring(slot))
        -- Equip L1 shield + 1 bit (keeping bits < 2 and speed < 3 so neither bit nor speed converts prematurely)
        H.collect_powerup("red", nil, "prep shield")
        H.collect_powerup("bit", nil, "prep 1 bit")
        if target_s > 2.5 then
          H.pilot_ticks(H.secs(target_s - 2.2), { shoot = true }, "pilot near " .. tostring(target_s) .. " s")
        end
        H.pilot_ticks(H.secs(0.7), { shoot = false }, "quiet approach to " .. tostring(target_s) .. " s carrier")

        local r_car = H.advance_until(function(rep)
          return #H.find_enemies(rep, "carrier") > 0
        end, H.secs(3.5), 4, "await carrier at " .. tostring(target_s) .. " s")
        assert_contract(
          r_car ~= nil,
          "a guaranteed carrier must arrive at " .. tostring(target_s) .. " s of scrolling (atomic requirement 17)"
        )
        local carrier = H.find_enemies(r_car, "carrier")[1]
        assert_contract(carrier ~= nil and carrier.hp <= 2, "carrier must spawn with 2 HP")

        -- Align Lance Y with carrier, destroy 2-HP carrier and weave +/-14 px across its 16 px hop band to catch the 24 px/s pickup
        local dy = carrier.y - 112
        if math.abs(dy) > 3 then
          H.move_for(0, dy > 0 and 1 or -1, H.secs(math.abs(dy) / 80.0), "align Y to carrier")
        end
        local mark = H.mark_events()
        for _ = 1, 4 do
          H.tap_fire(4, "shoot 2-HP carrier")
        end
        H.move_for(1, 0, H.secs(1.10), "intercept dropped pickup")
        for _ = 1, 10 do
          H.move_for(0, 1, 10, "hop band up")
          if #H.events_since(mark, "powerup_collected") > 0 then break end
          H.move_for(0, -1, 20, "hop band down")
          if #H.events_since(mark, "powerup_collected") > 0 then break end
          H.move_for(0, 1, 10, "hop band centre")
          if #H.events_since(mark, "powerup_collected") > 0 then break end
        end

        local drops = H.events_since(mark, "powerup_collected")
        assert_contract(
          #drops > 0 and drops[1].msg.kind == expected_kind,
          "carrier at " .. tostring(target_s) .. " s must drop '" .. expected_kind
            .. "' (atomic requirement 17), got '" .. tostring(drops[1] and drops[1].msg.kind) .. "'"
        )
      end

      -- Capped speed conversion rule (design section 4: a capped speed pickup becomes a blue crystal):
      H.start_play(1, "AR-16/17 capped speed -> blue crystal at 72 s")
      H.collect_powerup("red", nil, "L1 red")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      H.pilot_ticks(H.secs(69.8), { shoot = true }, "pilot near 72 s")
      H.pilot_ticks(H.secs(0.7), { shoot = false }, "approach 72 s carrier")
      local r_c72 = H.advance_until(function(rep) return #H.find_enemies(rep, "carrier") > 0 end, H.secs(3.5), 4, "await 72 s carrier")
      assert_contract(r_c72 ~= nil, "72 s carrier must arrive")
      local c72 = H.find_enemies(r_c72, "carrier")[1]
      local dy72 = c72.y - 112
      if math.abs(dy72) > 3 then
        H.move_for(0, dy72 > 0 and 1 or -1, H.secs(math.abs(dy72) / 128.0), "align Y to 72 s carrier")
      end
      local mark72 = H.mark_events()
      for _ = 1, 4 do H.tap_fire(4, "kill 72 s carrier") end
      H.move_for(1, 0, H.secs(0.80), "step into 72 s drop")
      local r_conv72 = nil
      for _ = 1, 10 do
        r_conv72 = H.move_for(0, 1, 8, "catch 72 s up")
        if #H.events_since(mark72, "powerup_collected") > 0 then break end
        r_conv72 = H.move_for(0, -1, 16, "catch 72 s down")
        if #H.events_since(mark72, "powerup_collected") > 0 then break end
        r_conv72 = H.move_for(0, 1, 8, "catch 72 s centre")
        if #H.events_since(mark72, "powerup_collected") > 0 then break end
      end
      assert_contract(
        r_conv72 ~= nil and r_conv72.force.level == 2 and r_conv72.force.weapon == "blue",
        "when speed is already capped at level 3, the 72 s speed pickup must convert to a blue crystal (raising Force to L2 'blue', design section 4)"
      )
    end)

    test("unshielded hit subtracts 1 life from 3, waits 1.0 s and restarts at scroll 0 or 1152 px checkpoint", function()
      local r0 = H.start_play(1, "AR-18 death & checkpoint")
      assert_contract(r0.lives == 3, "new run must begin with 3 lives (atomic requirement 18), got " .. tostring(r0.lives))

      -- Pilot safely to 20 s (scroll_px=480 < 1152 checkpoint) and take lethal hit
      local r_pre = H.pilot_ticks(H.secs(20.0), { shoot = false }, "scroll to 480 px")
      assert_contract(r_pre.lives == 3 and r_pre.scroll_px > 400 and r_pre.scroll_px < 1152, "must reach 480 px alive pre-checkpoint")
      H.post("player_hit", { source_id = "qa-pre-cp-hit" })
      local r_mid_death = H.advance(H.secs(0.45), "inside 1.0 s death interval")
      assert_contract(
        r_mid_death.lives == 2 and r_mid_death.scroll_px >= 400,
        "death must subtract 1 life and wait 1.0 s before restarting scroll (atomic requirement 18)"
      )
      local r_restarted = H.advance(H.secs(0.70), "finish 1.0 s death interval")
      assert_contract(
        r_restarted.lives == 2 and r_restarted.scroll_px < 20,
        "dying before 1152 px must restart at scroll_px=0 after 1.0 s (atomic requirement 18), got scroll_px="
          .. H.fmt(r_restarted.scroll_px)
      )

      -- Pilot safely past 60% scroll (48.5 s -> scroll_px >= 1152) to reach checkpoint
      local mark_cp = H.mark_events()
      local r_cp = H.pilot_ticks(H.secs(50.0), { shoot = true }, "scroll past 1152 px checkpoint")
      local cp_events = H.events_since(mark_cp, "checkpoint_reached")
      assert_contract(
        #cp_events >= 1 and cp_events[1].msg.scroll_px == 1152 and r_cp.scroll_px >= 1152,
        "crossing 60% scroll (1152 px) must emit checkpoint_reached{stage=1, scroll_px=1152} (atomic requirements 18 & 24)"
      )

      -- Die at ~1440 px (past checkpoint and well past 2.0 s respawn protection): must restart at 1152 px
      H.pilot_ticks(H.secs(10.0), { shoot = true }, "scroll to ~1440 px")
      H.post("player_hit", { source_id = "qa-post-cp-hit" })
      local r_cp_respawn = H.advance(H.secs(1.15), "wait 1.0 s death interval post-checkpoint")
      assert_contract(
        r_cp_respawn.lives == 1 and H.near(r_cp_respawn.scroll_px, 1152, 12),
        "dying after reaching 1152 px must restart at the 1152 px checkpoint (atomic requirement 18), got scroll_px="
          .. H.fmt(r_cp_respawn.scroll_px)
      )
    end)

    test("death retains Force at L1 attached_front vulcan, strips bits/missiles/speed and gives 2.0 s invulnerability", function()
      H.start_play(1, "AR-19 death equipment reset & 2 s blink protection")
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("blue", nil, "L2")
      H.collect_powerup("yellow", nil, "L3 yellow")
      H.collect_powerup("bit", nil, "bit")
      H.collect_powerup("missile", nil, "missile")
      H.collect_powerup("speed", nil, "speed 1")
      local r_full = H.collect_powerup("speed", nil, "speed 2")
      assert_contract(r_full.force.level == 3 and r_full.force.weapon == "yellow", "Force must be L3 yellow before death")

      H.post("player_hit", { source_id = "qa-gear-strip-hit" })
      local r_resp = H.advance(H.secs(1.10), "respawn after 1.0 s")
      assert_contract(
        r_resp.lives == 2
          and r_resp.force.level == 1
          and r_resp.force.state == "attached_front"
          and r_resp.force.weapon == "vulcan",
        "death with acquired Force must retain Force at level=1, state='attached_front', weapon='vulcan' (atomic requirement 19), got level="
          .. tostring(r_resp.force.level) .. " state=" .. tostring(r_resp.force.state)
          .. " weapon=" .. tostring(r_resp.force.weapon)
      )

      -- Hits inside the 2.0 s respawn invulnerability window (~0.5 s and ~1.5 s) are non-lethal:
      H.advance(H.secs(0.45), "0.55 s into protection")
      H.post("player_hit", { source_id = "qa-protected-1" })
      local r_prot1 = H.advance(H.secs(0.95), "1.50 s into protection")
      H.post("player_hit", { source_id = "qa-protected-2" })
      local r_prot2 = H.advance(4, "check still alive")
      assert_contract(
        r_prot1.lives == 2 and r_prot2.lives == 2,
        "2.0 s respawn invulnerability must ignore lethal hits during the protection window (atomic requirement 19)"
      )

      -- Speed was stripped back to level 0 (80 px/s -> 43 launch ticks from x=16 + 1.0 s right):
      H.move_for(-1, 0, H.secs(0.80), "clamp left")
      H.move_for(1, 0, 60, "move right 1.0 s after speed reset")
      local post_death_ticks = H.measure_launch_ticks_from_front(120, "speed reset check")
      assert_contract(
        H.near(post_death_ticks, 43, 3),
        "death must strip speed upgrades back to level 0 (80 px/s, ~43 launch ticks), got " .. tostring(post_death_ticks)
      )

      -- Past 2.0 s after respawn, protection has expired and player_hit kills again:
      H.advance(H.secs(0.60), "ensure >2.0 s elapsed since respawn")
      H.post("player_hit", { source_id = "qa-unprotected-again" })
      local r_vulnerable = H.advance(4, "hit after 2.0 s window")
      assert_contract(
        r_vulnerable.lives == 1,
        "after 2.0 s respawn invulnerability expires, unshielded collision must subtract a life again (atomic requirement 19)"
      )
    end)

    test("continue from game_over restores 3 lives at checkpoint, resets score & ledger to 0 and preserves hi-score & Force L1", function()
      H.start_play(1, "AR-20 continue economy")
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("blue", nil, "L2")
      local ledger_sid = H.uid("cont-ledger-carrier")
      H.post("enemy_killed", { spawn_id = ledger_sid, kind = "carrier", stage = 1 })
      H.post("enemy_killed", { spawn_id = H.uid("cont-carrier"), kind = "carrier", stage = 1 })
      local r_scored = H.pilot_ticks(H.secs(49.0), { shoot = false }, "reach 1152 checkpoint with score >= 1000")
      assert_contract(r_scored.score >= 1000 and r_scored.scroll_px >= 1152, "must hold score >= 1000 past checkpoint")
      local hi_before_gameover = H.read_saved_hi_score()

      -- Lose all 3 lives (waiting past 1.0 s death + 2.0 s invulnerability between hits)
      H.post("player_hit", { source_id = "qa-go-1" })
      H.advance(H.secs(3.30), "death 1 + protection expiry")
      H.post("player_hit", { source_id = "qa-go-2" })
      H.advance(H.secs(3.30), "death 2 + protection expiry")
      local mark_go = H.mark_events()
      H.post("player_hit", { source_id = "qa-go-3" })
      local r_go = H.advance_until(function(rep)
        return rep.screen == "game_over"
      end, H.secs(2.0), 4, "enter game_over at 0 lives")
      assert_contract(
        r_go ~= nil and r_go.screen == "game_over" and #H.events_since(mark_go, "game_over") >= 1,
        "losing the 3rd life must emit game_over and switch screen to 'game_over' (atomic requirements 18 & 20)"
      )

      -- Continue via Enter (input_start)
      H.post("input_start", {})
      local r_cont = H.advance(2, "continue run")
      local hi_after_continue = H.read_saved_hi_score()
      assert_contract(
        r_cont.screen == "play"
          and r_cont.lives == 3
          and r_cont.score == 0
          and H.near(r_cont.scroll_px, 1152, 12)
          and r_cont.force.level == 1
          and r_cont.force.state == "attached_front"
          and r_cont.force.weapon == "vulcan",
        "continue must enter 'play' at last checkpoint (1152 px) with lives=3, score=0 and Force L1 front vulcan (atomic requirement 20)"
      )
      assert_contract(
        hi_before_gameover ~= nil and hi_after_continue == hi_before_gameover,
        "continue must preserve saved hi_score while resetting current score to 0 (atomic requirements 20 & 23)"
      )

      -- Stage spawn reward ledger resets on continue (design section 4: "On continue reset current score, lives to three and stage spawn reward ledger")
      H.post("enemy_killed", { spawn_id = ledger_sid, kind = "carrier", stage = 1 })
      local r_reearn = H.advance(1, "re-earn pre-continue spawn_id")
      assert_contract(
        r_reearn.score == 500,
        "continue must reset the stage spawn reward ledger so spawns award points in the new score run (design section 4), got "
          .. tostring(r_reearn.score)
      )
    end)

    test("enemy kills award exact table points, ignore caller score and deduplicate (stage, spawn_id) across checkpoint replay", function()
      local r = H.start_play(1, "AR-21 point table & dedup")
      assert_contract(r.score == 0, "fresh run starts at score 0")

      local ordered_kinds = {
        { "drone", 100 },
        { "fighter", 200 },
        { "carrier", 500 },
        { "turret", 300 },
        { "worm_segment", 150 },
        { "mine", 50 },
        { "dop", 250 },
        { "crawler", 200 },
      }

      local expected_total = 0
      for i = 1, #ordered_kinds do
        local kind = ordered_kinds[i][1]
        local pts = ordered_kinds[i][2]
        local sid = "qa-table-" .. kind
        -- Pass bogus caller score/points fields; controller must ignore them and compute from kind!
        H.post("enemy_killed", { spawn_id = sid, kind = kind, stage = 1, score = 99999, amount = 99999 })
        r = H.advance(1, "score " .. kind)
        expected_total = expected_total + pts
        assert_contract(
          r.score == expected_total,
          "killing '" .. kind .. "' must award exactly " .. tostring(pts)
            .. " points (ignoring caller-supplied score, atomic requirement 21); expected total "
            .. tostring(expected_total) .. ", got " .. tostring(r.score)
        )

        -- Duplicate (stage=1, spawn_id=sid) in same run awards 0
        H.post("enemy_killed", { spawn_id = sid, kind = kind, stage = 1 })
        r = H.advance(1, "duplicate " .. kind)
        assert_contract(
          r.score == expected_total,
          "duplicate kill of same (stage, spawn_id) must award 0 points (atomic requirement 21)"
        )
      end

      -- Checkpoint replay deduplication: reach 1152 px, kill a spawn, die & respawn at 1152 px, kill same spawn again -> +0
      H.pilot_ticks(H.secs(49.0), { shoot = false }, "reach checkpoint")
      local score_at_cp = H.advance(1, "probe cp score").score
      H.post("enemy_killed", { spawn_id = "s1-cp-farm-target", kind = "carrier", stage = 1 })
      r = H.advance(1, "first kill past checkpoint")
      expected_total = score_at_cp + 500
      assert_contract(r.score == expected_total, "first kill of s1-cp-farm-target awards 500")

      H.post("player_hit", { source_id = "qa-cp-replay-die" })
      H.advance(H.secs(1.15), "respawn at checkpoint")
      H.post("enemy_killed", { spawn_id = "s1-cp-farm-target", kind = "carrier", stage = 1 })
      r = H.advance(1, "replay kill of same spawn_id after death")
      assert_contract(
        r.score == expected_total,
        "re-killing the same (stage, spawn_id) after checkpoint death replay must award 0 points to prevent farming (atomic requirement 21)"
      )
    end)

    test("boss defeat awards 5000+1000*stage and deathless stage clear adds 10000 no-miss bonus (forfeited on death or continue)", function()
      -- Deathless Stage 2 clear: boss award = 5000 + 2000 = 7000, no-miss = 10000 -> +17000
      H.start_play(2, "AR-22 deathless Stage 2 clear")
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("red", nil, "L2")
      H.collect_powerup("red", nil, "L3")
      H.collect_powerup("bit", nil, "bit 1")
      H.collect_powerup("bit", nil, "bit 2")
      local r_lock = H.pilot_to_boss({ shoot = true, allow_continue = false, quiet_tail_s = 1.0 }, "scroll Stage 2 to Oculocyst")
      assert_contract(r_lock.lives == 3, "Stage 2 pilot must reach Oculocyst with zero deaths for no-miss test")
      local score_before_boss = r_lock.score
      local mark_clear = H.mark_events()
      local r_clear = H.defeat_active_boss({ max_seconds = 55.0, allow_continue = false, re_equip_red_l3 = false }, "defeat Oculocyst no-miss")
      local boss_ev = H.events_since(mark_clear, "boss_defeated")
      local clear_ev = H.events_since(mark_clear, "stage_clear")
      assert_contract(
        #boss_ev == 1 and boss_ev[1].msg.stage == 2 and #clear_ev == 1 and clear_ev[1].msg.stage == 2,
        "defeating Stage 2 boss must emit boss_defeated{stage=2} and stage_clear{stage=2} exactly once"
      )
      local delta_nomiss = r_clear.score - score_before_boss
      assert_contract(
        delta_nomiss >= 17000,
        "deathless Stage 2 boss clear must award 7000 (5000+1000*2) + 10000 no-miss = 17000 points (atomic requirement 22), got +"
          .. tostring(delta_nomiss)
      )

      -- Stage 2 clear WITH one prior death: awards 7000 boss points, NO 10000 no-miss bonus!
      H.start_play(2, "AR-22 Stage 2 clear after 1 death")
      H.post("player_hit", { source_id = "qa-forfeit-nomiss" })
      H.advance(H.secs(1.20), "respawn after death on Stage 2")
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("red", nil, "L2")
      H.collect_powerup("red", nil, "L3")
      H.collect_powerup("bit", nil, "bit 1")
      H.collect_powerup("bit", nil, "bit 2")
      local r_lock_miss = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 1.0 }, "scroll Stage 2 to Oculocyst after death")
      H.collect_powerup("red", nil, "ensure L3")
      H.collect_powerup("red", nil, "ensure L3")
      local score_before_miss = r_lock_miss.score
      local r_clear_miss = H.defeat_active_boss({ max_seconds = 55.0, allow_continue = true, re_equip_red_l3 = true }, "defeat Oculocyst after death")
      local delta_miss = r_clear_miss.score - score_before_miss
      assert_contract(
        delta_miss >= 7000 and delta_miss < 17000,
        "clearing Stage 2 after a death must award 7000 boss bonus WITHOUT the 10000 no-miss bonus (atomic requirement 22), got +"
          .. tostring(delta_miss)
      )
    end)

    test("hi-score restores on startup, saves immediately via sys.save on increase and ignores death/continue/corrupt saves", function()
      H.start_play(1, "AR-23 hi-score persistence")
      local initial_disk_hi = H.read_saved_hi_score() or 0

      -- Scoring below current hi-score (e.g. 100 pts when seeded hi >= 350) must NOT reduce saved hi-score:
      H.post("enemy_killed", { spawn_id = H.uid("small-drone"), kind = "drone", stage = 1 })
      local r_low = H.advance(1, "score 100 below seeded hi")
      assert_contract(r_low.score == 100, "expected score 100")
      local after_low_hi = H.read_saved_hi_score() or 0
      assert_contract(
        after_low_hi >= H.SEEDED_HI and after_low_hi >= initial_disk_hi,
        "saved hi-score seeded before startup (" .. tostring(H.SEEDED_HI)
          .. ") must be restored and never overwritten by a lower score (atomic requirement 23)"
      )

      -- Raise current score strictly above after_low_hi; controller must sys.save immediately:
      local target_hi = after_low_hi + 1500
      while r_low.score < target_hi do
        H.post("enemy_killed", { spawn_id = H.uid("hi-push"), kind = "carrier", stage = 1 })
        r_low = H.advance(1, "push score above hi")
      end
      local saved_new_hi = H.read_saved_hi_score()
      assert_contract(
        saved_new_hi == r_low.score,
        "exceeding hi-score must immediately persist new hi_score=" .. tostring(r_low.score)
          .. " via sys.save in 'rift-vector' directory (atomic requirement 23), read back " .. tostring(saved_new_hi)
      )

      -- Corrupt the on-disk save files with malformed bytes and negative values; controller must never
      -- crash or overwrite its valid in-memory high score with corrupt data:
      H.write_all_saves_raw("\000\255malformed-save-payload")
      H.post("player_hit", { source_id = "qa-corrupt-save-death" })
      H.advance(H.secs(1.15), "survive death with malformed save on disk")
      H.write_all_saves_table({ hi_score = -999 })
      H.reset_to_title("reload/reset with negative hi_score table on disk")
      H.start_play(1, "play after corrupt save")
      -- Earning another higher score above saved_new_hi writes a clean integer >= saved_new_hi + 500
      local r_post = H.advance(1, "fresh run")
      while r_post.score < saved_new_hi + 500 do
        H.post("enemy_killed", { spawn_id = H.uid("hi-recover"), kind = "carrier", stage = 1 })
        r_post = H.advance(1, "push above prior in-memory hi")
      end
      assert_contract(
        H.read_saved_hi_score() == r_post.score,
        "controller must recover cleanly from malformed/negative save files and persist valid higher integer hi-scores (atomic requirement 23)"
      )
    end)
  end)
end
