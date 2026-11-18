-- test/t_07_bosses_all_ten.lua -- Individual red behavioural contracts for all
-- 10 stage bosses via test_set_stage + test_advance: initial HP, >=0.60 s attack
-- telegraph, ~6.0 s exposure cycle, weak-point-only damage (0 damage while closed),
-- unpowered vulcan defeatability (no collected weapon required), boss_defeated
-- emission, and Stage-10 Overmind two-phase transition at HP <= 150 (Atomic Requirement 29).

local H = require "test.harness"
local G = require "test.gdd_data"

-- Ensure Lance is back at boss scroll lock (1920 px) if an unpowered hit triggered
-- a checkpoint respawn at 1152 px or game_over during an unpowered boss probe.
local function ensure_at_boss_unpowered(label)
  local r = H.advance(1, label)
  if r.screen == "game_over" then
    H.post("input_start", {})
    r = H.advance(2, label .. " continue")
  end
  if r.screen == "play" and r.boss == nil and (r.scroll_px or 0) < 1918.0 then
    r = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, label .. " return to boss")
  end
  return r
end

local function verify_boss_contract(st)
  local label = "Stage " .. tostring(st.stage) .. " " .. st.boss_name
  local r0 = H.start_play(st.stage, label)
  assert_contract(r0.force.level == 0, label .. ": test starts unpowered (Force level 0)")

  -- Pilot unpowered to scroll lock at 1920 px with a 2.0 s quiet tail so zero bullets are in flight
  local r_lock = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, label .. " scroll to boss lock")
  assert_contract(
    r_lock ~= nil and r_lock.boss ~= nil and r_lock.boss.hp == st.boss_hp,
    label .. " must engage at scroll lock with initial HP=" .. tostring(st.boss_hp)
      .. " (design section 4 & atomic requirement 29), got "
      .. tostring(r_lock and r_lock.boss and r_lock.boss.hp)
  )

  -- 1. Attack telegraph >= 0.60 s (33 ticks = 0.55 s without instant hit at boss lock start)
  local lives_at_lock = r_lock.lives
  local r_tell = H.advance(33, label .. " 0.55 s telegraph check")
  assert_contract(
    r_tell.lives == lives_at_lock,
    label .. " must telegraph damaging moves for >= 0.60 s without an instant hit on lock (atomic requirement 29)"
  )

  -- 2. Exposure cycle (~6.0 s) & weak-point immunity while exposed == false:
  -- Wait for a closed phase first
  local r_closed = H.advance_until(function(rep)
    return rep.boss ~= nil and rep.boss.exposed == false
  end, H.secs(6.5), 3, label .. " find closed phase")
  assert_contract(
    r_closed ~= nil and r_closed.boss ~= nil and r_closed.boss.exposed == false,
    label .. " must have a protected/closed phase (exposed=false) in its 6 s cycle"
  )

  -- Wait for closed->open transition (on Stage 5 Bellmite, shed/clear six 2-HP shell cells first!)
  local r_opened = nil
  if st.stage == 5 then
    local tries = 0
    while tries < 20 and not (r_opened and r_opened.boss and r_opened.boss.exposed) do
      ensure_at_boss_unpowered(label)
      r_opened = H.full_vertical_sweep(60, label .. " clear Bellmite 2-HP shell cells")
      if not (r_opened and r_opened.boss and r_opened.boss.exposed) then
        local probe_open = H.advance_until(function(rep)
          return rep.boss ~= nil and rep.boss.exposed == true
        end, H.secs(2.0), 2, label .. " check Bellmite open")
        if probe_open then
          r_opened = probe_open
        end
      end
      tries = tries + 1
    end
  else
    r_opened = H.advance_until(function(rep)
      return rep.boss ~= nil and rep.boss.exposed == true
    end, H.secs(13.0), 2, label .. " await weak-point opening")
  end
  assert_contract(
    r_opened ~= nil and r_opened.boss ~= nil and r_opened.boss.exposed == true,
    label .. " must open its weak point (exposed=true) on its ~6 s schedule (atomic requirement 29)"
  )

  -- Measure open duration when starting from a clean closed->open transition:
  -- To guarantee we measure a complete opening from its first tick, wait for close then next open!
  local r_after_first = H.advance_until(function(rep)
    return rep.boss ~= nil and rep.boss.exposed == false
  end, H.secs(5.5), 2, label .. " await close before timed window")
  if r_after_first == nil then
    ensure_at_boss_unpowered(label)
    r_after_first = H.advance_until(function(rep)
      return rep.boss ~= nil and rep.boss.exposed == false
    end, H.secs(6.5), 2, label .. " recover closed window")
  end
  assert_contract(r_after_first ~= nil and r_after_first.boss ~= nil, label .. " must close weak point after opening")

  -- Immediately at the start of the ~3.5..4.2 s closed window, fire unpowered vulcan;
  -- boss HP must NOT decrease while exposed == false!
  local hp_closed_start = r_after_first.boss.hp
  H.tap_fire(4, label .. " closed shot 1")
  H.tap_fire(4, label .. " closed shot 2")
  local r_still_closed = H.advance(28, label .. " projectiles hit closed armour")
  if r_still_closed.boss and r_still_closed.boss.exposed == false then
    assert_contract(
      r_still_closed.boss.hp == hp_closed_start,
      label .. " must take 0 HP damage while boss.exposed==false (weak-point-only contract), HP went "
        .. tostring(hp_closed_start) .. " -> " .. tostring(r_still_closed.boss.hp)
    )
  end

  -- Measure full clean rising-to-falling exposure duration against st.expose_s:
  ensure_at_boss_unpowered(label)
  local r_clean_open = H.advance_until(function(rep)
    return rep.boss ~= nil and rep.boss.exposed == true
  end, H.secs(12.5), 2, label .. " await clean opening edge")
  assert_contract(r_clean_open ~= nil and r_clean_open.boss ~= nil, label .. " weak point must re-open on 6 s cycle")

  local open_ticks = 0
  local r_reclosed = r_clean_open
  while open_ticks < H.secs(5.0) and r_reclosed.boss and r_reclosed.boss.exposed do
    r_reclosed = H.advance(2, label .. " measure open window")
    open_ticks = open_ticks + 2
  end
  if r_reclosed.boss ~= nil then
    assert_contract(
      r_reclosed.boss.exposed == false
        and open_ticks >= H.secs(st.expose_s - 0.45)
        and open_ticks <= H.secs(st.expose_s + 0.55),
      label .. " weak-point opening must match stage table (~" .. H.fmt(st.expose_s)
        .. " s every 6 s, atomic requirement 29), measured " .. H.fmt(open_ticks / 60.0) .. " s"
    )
  end

  -- 3. Unpowered vulcan damages exposed core across full y=56..168 sweep (no collected weapon required, AR-29):
  local x_trials = st.stage == 3 and { 0, 96, -40 } or { 0 }
  local dealt_unpowered = false
  for tx = 1, #x_trials do
    local r_ready = ensure_at_boss_unpowered(label)
    if x_trials[tx] ~= 0 then
      local dx = x_trials[tx] > 0 and 1 or -1
      r_ready = H.move_for(dx, 0, H.secs(math.abs(x_trials[tx]) / 80.0), label .. " position X for Iron Vesper")
    end
    if st.stage == 5 then
      -- Ensure Bellmite shell cells are cleared if a respawn reset the boss
      for _ = 1, 8 do
        local rb = H.full_vertical_sweep(42, label .. " Bellmite shell sweep")
        if rb.boss and rb.boss.exposed then break end
      end
    end
    local r_exp2 = H.advance_until(function(rep)
      return rep.boss ~= nil and rep.boss.exposed == true
    end, H.secs(8.0), 2, label .. " await opening for unpowered damage")
    if r_exp2 and r_exp2.boss then
      local hp_before_unpowered = r_exp2.boss.hp
      local r_after_unpowered = H.full_vertical_sweep(110, label .. " full-height unpowered vulcan sweep")
      if r_after_unpowered.boss == nil and #H.events_since(0, "boss_defeated") > 0 then
        dealt_unpowered = true
        break
      elseif r_after_unpowered.boss and r_after_unpowered.boss.hp < hp_before_unpowered then
        dealt_unpowered = true
        break
      end
    end
  end
  assert_contract(
    dealt_unpowered,
    label .. " must take HP damage from unpowered vulcan while exposed (no collected weapon required, atomic requirement 29)"
  )

  -- 4. Full defeat emits boss_defeated{stage=N} once (Stage 1 completed 100% unpowered; Stages 2..10 may use Force+Bits for fast completion)
  ensure_at_boss_unpowered(label)
  local mark_defeat = H.mark_events()
  if st.stage > 1 then
    H.collect_powerup("red", nil, "L1")
    H.collect_powerup("red", nil, "L2")
    H.collect_powerup("red", nil, "L3")
    H.collect_powerup("bit", nil, "bit 1")
    H.collect_powerup("bit", nil, "bit 2")
  end
  H.defeat_active_boss({
    max_seconds = st.stage == 1 and 130.0 or 75.0,
    allow_continue = true,
    re_equip_red_l3 = (st.stage > 1),
  }, label .. " full defeat")

  local defeated = H.events_since(mark_defeat, "boss_defeated")
  assert_contract(
    #defeated == 1 and defeated[1].msg.stage == st.stage,
    label .. " defeat must emit boss_defeated{stage=" .. tostring(st.stage) .. "} exactly once"
  )
end

return function()
  describe("All ten stage bosses and Overmind two-phase encounter", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    for i = 1, #G.STAGES do
      local st = G.STAGES[i]
      test(
        string.format(
          "Stage %d boss %s (HP %d, open %.1f s / 6 s): telegraph, weak-point immunity, unpowered damage and defeat",
          st.stage,
          st.boss_name,
          st.boss_hp,
          st.expose_s
        ),
        function()
          verify_boss_contract(st)
        end
      )
    end

    test("Stage 10 Vorn Overmind transitions from Phase 1 (HP 300..151) to Phase 2 at HP <= 150 and enters victory on kill", function()
      H.start_play(10, "Stage 10 Overmind two-phase")
      H.collect_powerup("red", nil, "L1")
      H.collect_powerup("red", nil, "L2")
      H.collect_powerup("red", nil, "L3")
      H.collect_powerup("bit", nil, "bit 1")
      H.collect_powerup("bit", nil, "bit 2")

      local r = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Overmind")
      H.collect_powerup("red", nil, "ensure L2/L3")
      H.collect_powerup("red", nil, "ensure L3")
      assert_contract(
        r.boss ~= nil and r.boss.hp == 300,
        "Vorn Overmind must start Phase 1 at HP=300"
      )

      -- Deal controlled damage down into Phase 2 (0 < HP <= 150) using full-range vertical sweeps
      local p2_report = nil
      local sweep_dir = 1
      local sweep_rem = 36
      for _ = 1, 140 do
        r = H.advance(4, "step towards Phase 2")
        if r.screen == "play" and r.boss == nil and (r.scroll_px or 0) < 1918.0 then
          H.collect_powerup("red", nil, "re-equip L3")
          H.collect_powerup("red", nil, "re-equip L3")
          r = H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 1.0 }, "return to Overmind")
        end
        if r.boss and r.boss.hp <= 150 and r.boss.hp > 0 then
          p2_report = r
          break
        end
        if r.boss and r.boss.exposed then
          H.tap_fire(3, "chip Overmind towards <=150")
        end
        H.move_for(0, sweep_dir, 6, "sweep lane")
        sweep_rem = sweep_rem - 6
        if sweep_rem <= 0 then
          sweep_dir = -sweep_dir
          sweep_rem = 72
        end
      end
      assert_contract(
        p2_report ~= nil and p2_report.boss ~= nil and p2_report.boss.hp <= 150 and p2_report.boss.hp > 0,
        "Vorn Overmind must enter Phase 2 alive at HP <= 150 (design section 4: crown opens + marked lane sweep)"
      )

      -- Verify Phase 2 continues cycling exposed false <-> true on its 6 s schedule
      local saw_closed_p2 = false
      local saw_open_p2 = false
      for _ = 1, 80 do
        local step_p2 = H.pilot_ticks(6, { shoot = false }, "observe Phase 2 exposure cycle")
        if step_p2.boss then
          if step_p2.boss.exposed then
            saw_open_p2 = true
          else
            saw_closed_p2 = true
          end
        end
        if saw_closed_p2 and saw_open_p2 then
          break
        end
      end
      assert_contract(
        saw_closed_p2 and saw_open_p2,
        "Vorn Overmind Phase 2 (HP <= 150) must maintain timed neural-eye exposure cycle (1.8 s every 6 s)"
      )

      -- Finish Phase 2 (HP -> 0) and assert transition into 'victory' screen with final score > 0
      local mark_vic = H.mark_events()
      r = H.defeat_active_boss({ max_seconds = 75.0, allow_continue = true, re_equip_red_l3 = true }, "finish Overmind Phase 2")
      if r.screen ~= "victory" then
        r = H.advance_until(function(rep) return rep.screen == "victory" end, H.secs(3.0), 4, "await victory screen") or r
      end
      assert_contract(
        r.screen == "victory" and r.score >= 15000 and H.has_cue_since(mark_vic, "jingle_victory"),
        "defeating Stage-10 Vorn Overmind must enter 'victory' screen with final score and jingle_victory (atomic requirement 28), got screen='"
          .. tostring(r.screen) .. "' score=" .. tostring(r.score)
      )
    end)
  end)
end
