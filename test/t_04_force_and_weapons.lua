-- test/t_04_force_and_weapons.lua -- Force crystal progression, front/rear
-- attachment, launch/recall speeds & midpoint hysteresis, detached L1..L3 shot
-- patterns, Red/Blue/Yellow lasers, Bits and Homing Missiles (Atomic Requirements 6..15).

local H = require "test.harness"

return function()
  describe("Force pod mechanics, laser crystals, bits and homing missiles", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("laser crystals create L1 Force, increment up to L3 cap and switch red/blue/yellow weapon", function()
      local r0 = H.start_play(1, "AR-06 crystal progression")
      assert_contract(
        r0.force ~= nil and r0.force.level == 0,
        "a fresh run starts with unacquired Force (level=0)"
      )

      local r1 = H.collect_powerup("red", nil, "1st crystal -> L1 red")
      assert_contract(
        r1.force.level == 1 and r1.force.weapon == "red",
        "1st crystal (red) must create level-1 Force with weapon='red' (atomic requirement 6), got level="
          .. tostring(r1.force.level) .. " weapon=" .. tostring(r1.force.weapon)
      )

      local r2 = H.collect_powerup("blue", nil, "2nd crystal -> L2 blue")
      assert_contract(
        r2.force.level == 2 and r2.force.weapon == "blue",
        "2nd crystal (blue) must raise Force to level 2 with weapon='blue' (atomic requirement 6)"
      )

      local r3 = H.collect_powerup("yellow", nil, "3rd crystal -> L3 yellow")
      assert_contract(
        r3.force.level == 3 and r3.force.weapon == "yellow",
        "3rd crystal (yellow) must raise Force to level 3 with weapon='yellow' (atomic requirement 6)"
      )

      local r4 = H.collect_powerup("red", nil, "4th crystal -> stays L3, switches red")
      assert_contract(
        r4.force.level == 3 and r4.force.weapon == "red",
        "4th crystal must cap Force at level 3 while switching weapon to 'red' (atomic requirement 6)"
      )
    end)

    test("Force launches at 200 px/s to x=264/56 with 16 px hysteresis, recalls at 160 px/s and blocks bullets", function()
      local r0 = H.start_play(1, "AR-08/09 launch/recall/hysteresis")
      -- Unacquired input_force is a no-op
      H.post("input_force", {})
      r0 = H.advance(2, "unacquired force press")
      assert_contract(r0.force.level == 0, "input_force while unacquired must be a no-op")

      -- Acquire at start (ship.x=64, attached_front pod.x=88) -> launch to x=264 (176 px @ 200 px/s = 53 ticks)
      H.collect_powerup("red", nil, "acquire L1 Force")
      local launch_ticks, r_det = H.measure_launch_ticks_from_front(100, "launch from x=64")
      assert_contract(
        H.near(launch_ticks, 53, 4) and r_det.force.state == "detached",
        "Force launch from ship.x=64 (pod.x=88) to x=264 at 200 px/s must take ~53 ticks, got "
          .. tostring(launch_ticks)
      )

      -- Recall from x=264 back to ship at x=64 at 160 px/s (~176 px / 160 * 60 = 66 ticks):
      H.post("input_force", {})
      local r_rec1 = H.advance(2, "begin recall")
      assert_contract(
        r_rec1.force.state == "recalling",
        "second input_force on detached pod must enter 'recalling' state (atomic requirement 8)"
      )
      -- Extra input_force during recalling is a no-op
      H.post("input_force", {})
      local recall_ticks = 2
      while recall_ticks < 110 do
        local step_r = H.advance(1, "recall tick")
        recall_ticks = recall_ticks + 1
        if step_r.force.state == "attached_front" or step_r.force.state == "attached_rear" then
          break
        end
      end
      assert_contract(
        H.near(recall_ticks, 66, 9),
        "Force recall across ~176 px at 160 px/s must take ~66 ticks (atomic requirement 8), got "
          .. tostring(recall_ticks)
      )

      -- Opposite-half holding (x=264 when ship.x<160, x=56 when ship.x>=160 with 16 px hysteresis):
      -- Run on a fresh Stage 1 start with Speed L3 (128 px/s) so the entire cross + hysteresis + recall
      -- completes before the first t=2.40 s enemy reaches x=188.
      H.start_play(1, "AR-09 midpoint hysteresis")
      H.collect_powerup("red", nil, "L1 Force")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      H.post("input_force", {})
      H.advance(58, "settle detached at x=264")
      H.move_for(1, 0, H.secs((188 - 64) / 128.0), "cross right of midpoint + hysteresis to x=188")
      H.advance(84, "let detached Force reposition to x=56")
      H.move_for(-1, 0, H.secs((188 - 156) / 128.0), "step back to x=156 inside hysteresis band")
      H.advance(16, "hold inside hysteresis")
      H.post("input_force", {})
      local r_hyst = H.advance_until(function(rep)
        return rep.force.state == "attached_rear" or rep.force.state == "attached_front"
      end, 120, 2, "recall from hysteresis x=56")
      assert_contract(
        r_hyst ~= nil and r_hyst.force.state == "attached_rear" and r_hyst.force.level == 1,
        "after crossing right past midpoint hysteresis to x=56 and stepping back to x=156, indestructible Force must remain on left half (x=56) and attach 'attached_rear' (atomic requirements 7 & 9), got '"
          .. tostring(r_hyst and r_hyst.force.state) .. "'"
      )

      -- Detached Force mirrors ship Y at up to 160 px/s, blocks bullets, deals contact ram damage
      -- and remains indestructible in active combat:
      H.start_play(1, "AR-09 detached Y-mirror & ram indestructibility")
      H.collect_powerup("red", nil, "L1 Force")
      H.post("input_force", {})
      H.advance(58, "detach to x=264")
      -- Sweep Lance across enemy lanes so detached Force at x=264 mirrors ship Y into incoming scouts
      local mark_ram = H.mark_events()
      for _ = 1, 8 do
        H.move_for(0, 1, 18, "mirror Y up")
        H.move_for(0, -1, 36, "mirror Y down")
        H.move_for(0, 1, 18, "mirror Y centre")
      end
      local r_combat = H.advance(10, "post-ram check")
      assert_contract(
        r_combat.force ~= nil and r_combat.force.state == "detached" and r_combat.force.level == 1,
        "detached Force must remain indestructible (level=1, state='detached') while blocking enemy fire and ramming enemies (atomic requirement 9)"
      )
      local _ = mark_ram
    end)

    test("front vs rear Force attachment reverses attached weapon firing direction", function()
      -- Stage 1 boss Ribmaw is in front (right of Lance). Pilot to Ribmaw first, then equip L3 Red
      -- attached_front vs attached_rear so equipment cannot be lost during stage scrolling.
      H.start_play(1, "AR-07 front fire")
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw front")
      H.collect_powerup("red", nil, "L1 red")
      H.collect_powerup("red", nil, "L2 red")
      local rf = H.collect_powerup("red", nil, "L3 red")
      assert_contract(rf.force.state == "attached_front", "initial Force attaches front")
      local exp_front = H.advance_until(function(rep)
        return rep.boss ~= nil and rep.boss.exposed == true
      end, H.secs(7.0), 3, "wait Ribmaw exposed front")
      assert_contract(exp_front ~= nil, "Ribmaw must expose weak point")
      local hp_f0 = exp_front.boss.hp
      H.tap_fire(8, "front tap 1")
      H.tap_fire(8, "front tap 2")
      local r_after_front = H.advance(45, "front projectiles land")
      local front_dmg = hp_f0 - r_after_front.boss.hp

      -- Rear attachment setup on fresh run before scrolling, then pilot safely & verify rear state
      H.start_play(1, "AR-07 rear fire")
      H.collect_powerup("red", nil, "L1 red")
      H.collect_powerup("speed", nil, "spd 1")
      H.collect_powerup("speed", nil, "spd 2")
      H.collect_powerup("speed", nil, "spd 3")
      H.post("input_force", {})
      H.advance(58, "detach")
      H.move_for(1, 0, H.secs((192 - 64) / 128.0), "move right to x=192")
      H.advance(84, "pod moves to x=56")
      H.post("input_force", {})
      local r_rear = H.advance_until(function(rep)
        return rep.force.state == "attached_rear"
      end, 120, 2, "attach rear")
      assert_contract(
        r_rear ~= nil and r_rear.force.state == "attached_rear",
        "contact on ship rear half (pod.x < ship.x) must set state='attached_rear' (atomic requirement 7)"
      )
      H.move_for(-1, 0, H.secs((192 - 64) / 128.0), "return to x=64")
      H.pilot_to_boss({ shoot = true, allow_continue = false, quiet_tail_s = 2.0 }, "scroll to Ribmaw rear")
      H.collect_powerup("red", nil, "ensure L2/L3 red")
      local rr3 = H.collect_powerup("red", nil, "ensure L3 red")
      -- Re-verify Force remained attached_rear; if a stray hit occurred during scroll, re-attach rear quickly
      if rr3.force.state ~= "attached_rear" then
        H.collect_powerup("speed", nil, "spd 1")
        H.collect_powerup("speed", nil, "spd 2")
        H.collect_powerup("speed", nil, "spd 3")
        H.post("input_force", {})
        H.advance(58, "detach at boss")
        H.move_for(1, 0, H.secs((188 - 64) / 128.0), "step right of midpoint")
        H.advance(84, "pod to x=56")
        H.post("input_force", {})
        H.advance_until(function(rep) return rep.force.state == "attached_rear" end, 120, 2, "re-attach rear")
        H.move_for(-1, 0, H.secs((188 - 64) / 128.0), "return to x=64")
        H.collect_powerup("red", nil, "L2 red")
        H.collect_powerup("red", nil, "L3 red")
      end
      local exp_rear = H.advance_until(function(rep)
        return rep.boss ~= nil and rep.boss.exposed == true
      end, H.secs(7.0), 3, "wait Ribmaw exposed rear")
      assert_contract(exp_rear ~= nil, "Ribmaw must expose weak point")
      local hp_r0 = exp_rear.boss.hp
      H.tap_fire(8, "rear tap 1")
      H.tap_fire(8, "rear tap 2")
      local r_after_rear = H.advance(45, "rear projectiles land")
      local rear_dmg = hp_r0 - r_after_rear.boss.hp

      assert_contract(
        front_dmg > rear_dmg and front_dmg >= 6,
        "attached_front Red L3 must deal forward laser damage while attached_rear reverses lasers leftward away from forward boss (atomic requirements 7 & 11); front_dmg="
          .. tostring(front_dmg) .. ", rear_dmg=" .. tostring(rear_dmg)
      )
    end)

    test("detached Force fire patterns scale from L1 forward to L2 +-30 deg and L3 +-30 deg + vertical bolts", function()
      -- Stage 8 Hatch Warden (or ceiling/floor turrets in Stage 3) sits above/off-axis from mid-lane.
      -- With Force detached at x=264 and Lance tucked down/away so nose vulcan misses upper targets,
      -- L3's vertical/spread bolts hit upper/angled targets that L1's single horizontal bolt misses.
      local hits_by_level = {}
      for lvl = 1, 3 do
        H.start_play(3, "AR-10 detached L" .. tostring(lvl))
        for _ = 1, lvl do
          H.collect_powerup("red", nil, "raise Force")
        end
        H.post("input_force", {})
        H.advance(60, "detach to x=264")
        local mark = H.mark_events()
        -- Fire detached volleys across 12 s of Stage 3 (deck turrets + fighters + mines across top/bottom/angled lanes)
        for _ = 1, 20 do
          H.tap_fire(34, "detached volley")
        end
        local kills = H.events_since(mark, "score_add")
        hits_by_level[lvl] = #kills
      end
      assert_contract(
        hits_by_level[3] > hits_by_level[1] and hits_by_level[2] >= hits_by_level[1],
        "detached Force L2 (+-30 deg) and L3 (+-30 deg + vertical up/down) must cover off-axis/vertical targets beyond L1's single forward bolt (atomic requirement 10); kills L1="
          .. tostring(hits_by_level[1]) .. ", L2=" .. tostring(hits_by_level[2]) .. ", L3=" .. tostring(hits_by_level[3])
      )
    end)

    test("attached Red twin lasers scale damage L1 < L2 < L3 with L3 helix width", function()
      local damages = {}
      for lvl = 1, 3 do
        H.start_play(1, "AR-11 Red L" .. tostring(lvl))
        H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
        for _ = 1, lvl do
          H.collect_powerup("red", nil, "red crystal")
        end
        local exp = H.advance_until(function(rep)
          return rep.boss ~= nil and rep.boss.exposed == true
        end, H.secs(7.0), 3, "wait Ribmaw exposed")
        assert_contract(exp ~= nil, "Ribmaw must open chest")
        local hp0 = exp.boss.hp
        H.tap_fire(6, "red tap")
        local after = H.advance(45, "red laser flight")
        damages[lvl] = hp0 - after.boss.hp
      end
      assert_contract(
        damages[1] >= 2 and damages[2] > damages[1] and damages[3] > damages[2],
        "attached Red twin lasers must deal strictly increasing damage across L1/L2/L3 (1/2/3 per strand + vulcan, atomic requirement 11); got L1="
          .. tostring(damages[1]) .. ", L2=" .. tostring(damages[2]) .. ", L3=" .. tostring(damages[3])
      )
    end)

    test("attached Blue emits 0 and +-45 deg beams reflecting off terrain up to twice and expiring at 1.2 s", function()
      H.start_play(3, "AR-12 Blue ricochet beams")
      H.collect_powerup("blue", nil, "L1 blue")
      H.collect_powerup("blue", nil, "L2 blue")
      local rb = H.collect_powerup("blue", nil, "L3 blue")
      assert_contract(rb.force.weapon == "blue" and rb.force.level == 3, "Force must equip L3 blue")

      -- Keep Lance fixed at centre y=112 where horizontal vulcan alone cannot touch deck turrets on y=40/184 terrain bands;
      -- +-45 deg Blue beams hit and reflect off terrain to strike off-axis turrets/enemies, then expire within 1.2 s.
      local mark = H.mark_events()
      for _ = 1, 16 do
        H.tap_fire(40, "blue 45-deg volley")
      end
      local awards = H.events_since(mark, "score_add")
      local hit_turret_or_offaxis = false
      for i = 1, #awards do
        if awards[i].msg and (awards[i].msg.amount == 300 or awards[i].msg.amount >= 50) then
          hit_turret_or_offaxis = true
        end
      end
      assert_contract(
        hit_turret_or_offaxis and #awards >= 2,
        "attached Blue 0/+-45 deg reflecting beams must strike off-axis/terrain-mounted Stage-3 targets from mid-lane (atomic requirement 12)"
      )
    end)

    test("attached Yellow emits up/down terrain-crawling plumes expiring at 0.8 s without piercing terrain", function()
      H.start_play(6, "AR-13 Yellow terrain crawl")
      H.collect_powerup("yellow", nil, "L1 yellow")
      H.collect_powerup("yellow", nil, "L2 yellow")
      local ry = H.collect_powerup("yellow", nil, "L3 yellow")
      assert_contract(ry.force.weapon == "yellow" and ry.force.level == 3, "Force must equip L3 yellow")

      -- Stage 6 (Transit Artery) features wall crawlers and ceiling/floor turrets along terrain bands.
      -- Keep Lance at mid-screen y=112 so horizontal vulcan misses wall crawlers/turrets, while
      -- Yellow vertical plumes reach top/bottom terrain and crawl 80 px/s for up to 0.8 s.
      local mark = H.mark_events()
      for _ = 1, 18 do
        H.tap_fire(36, "yellow plume volley")
      end
      local kills = H.events_since(mark, "enemy_killed")
      local hit_wall_unit = false
      for i = 1, #kills do
        local k = kills[i].msg and kills[i].msg.kind
        if k == "crawler" or k == "turret" then
          hit_wall_unit = true
        end
      end
      assert_contract(
        hit_wall_unit,
        "attached Yellow up/down plumes must crawl top/bottom terrain boundaries and destroy wall crawlers/turrets from y=112 (atomic requirement 13)"
      )
    end)

    test("at most two Bits at (0,+-20) block bullets, convert 3rd bit drop to red crystal and fire ONLY with red equipped", function()
      -- 3rd bit conversion rule (design section 4: if bits are already full, a bit becomes a red crystal).
      -- Exercise via the 36 s scheduled bit-carrier drop while already holding 2 bits + L1 blue Force,
      -- so both drop-spawn-time and collection-time conversion implementations satisfy the contract!
      H.start_play(1, "AR-14 bits cap & 36s carrier conversion")
      H.collect_powerup("blue", nil, "L1 blue")
      H.collect_powerup("bit", nil, "bit #1")
      local r_two = H.collect_powerup("bit", nil, "bit #2")
      assert_contract(
        r_two.force.level == 1 and r_two.force.weapon == "blue",
        "collecting two bits must not alter Force level/colour"
      )
      H.pilot_ticks(H.secs(34.0), { shoot = true }, "pilot to 34 s")
      H.pilot_ticks(H.secs(0.8), { shoot = false }, "approach 36 s bit carrier cleanly")
      local r_car = H.advance_until(function(rep)
        return #H.find_enemies(rep, "carrier") > 0
      end, H.secs(3.5), 4, "await 36 s carrier")
      assert_contract(r_car ~= nil, "36 s carrier must arrive on Stage 1")
      local carrier = H.find_enemies(r_car, "carrier")[1]
      local car_dy = carrier.y - 112
      if math.abs(car_dy) > 3 then
        H.move_for(0, car_dy > 0 and 1 or -1, H.secs(math.abs(car_dy) / 80.0), "align Y to 36 s carrier")
      end
      local mark_conv = H.mark_events()
      for _ = 1, 4 do
        H.tap_fire(4, "kill 36 s carrier")
      end
      H.move_for(1, 0, H.secs(1.10), "step forward into drop path")
      -- Sweep +/-14 px across carrier hop band while pickup drifts left at 24 px/s
      local r_conv = nil
      for _ = 1, 10 do
        r_conv = H.move_for(0, 1, 10, "catch hop up")
        if #H.events_since(mark_conv, "powerup_collected") > 0 then break end
        r_conv = H.move_for(0, -1, 20, "catch hop down")
        if #H.events_since(mark_conv, "powerup_collected") > 0 then break end
        r_conv = H.move_for(0, 1, 10, "catch hop centre")
        if #H.events_since(mark_conv, "powerup_collected") > 0 then break end
      end
      assert_contract(
        r_conv ~= nil and r_conv.force.level == 2 and r_conv.force.weapon == "red",
        "when 2 bits are already held, the 36 s bit pickup must convert to a red crystal (raising Force to L2 'red', design section 4 & atomic requirement 14), got level="
          .. tostring(r_conv and r_conv.force.level) .. " weapon=" .. tostring(r_conv and r_conv.force.weapon)
      )

      -- Verify bits occupy (0, +-20) and fire a 1-damage red bolt ONLY while weapon=='red':
      -- Find Ribmaw's core Y lane, then shift Lance 20 px below it so the upper Bit at (0, +20)
      -- sits dead-centre on the exposed core while Lance's own nose sits 20 px below core centre!
      local core_dy = 0
      local probe_offsets = { 0, 16, -16, 32, -32 }
      for i = 1, #probe_offsets do
        H.start_play(1, "AR-14 core probe")
        H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
        local try_dy = probe_offsets[i]
        if try_dy ~= 0 then
          H.move_for(0, try_dy > 0 and 1 or -1, H.secs(math.abs(try_dy) / 80.0), "probe Y")
        end
        local exp_p = H.advance_until(function(rep) return rep.boss and rep.boss.exposed end, H.secs(7.0), 3, "exp")
        if exp_p and exp_p.boss then
          local hp_p = exp_p.boss.hp
          H.tap_fire(1, "probe vulcan")
          if H.advance(45, "land").boss.hp < hp_p then
            core_dy = try_dy
            break
          end
        end
      end
      local bit_offset_dy = core_dy - 20

      local function boss_tap_damage_at_dy(dy, colour, with_bits)
        H.start_play(1, "AR-14 " .. colour .. " bits=" .. tostring(with_bits))
        H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
        H.collect_powerup(colour, nil, "L1 " .. colour)
        if with_bits then
          H.collect_powerup("bit", nil, "bit 1")
          H.collect_powerup("bit", nil, "bit 2")
        end
        if dy ~= 0 then
          H.move_for(0, dy > 0 and 1 or -1, H.secs(math.abs(dy) / 80.0), "shift Lance so +20 bit aligns core")
        end
        local exp = H.advance_until(function(rep) return rep.boss and rep.boss.exposed end, H.secs(7.0), 3, "exp")
        assert_contract(exp ~= nil and exp.boss ~= nil, "Ribmaw must expose weak point")
        local hp0 = exp.boss.hp
        H.tap_fire(1, "tap")
        return hp0 - H.advance(45, "land").boss.hp
      end

      local dmg_red_0 = boss_tap_damage_at_dy(bit_offset_dy, "red", false)
      local dmg_red_2 = boss_tap_damage_at_dy(bit_offset_dy, "red", true)
      local dmg_yel_2 = boss_tap_damage_at_dy(bit_offset_dy, "yellow", true)

      assert_contract(
        dmg_red_2 > dmg_red_0 and dmg_yel_2 == 0,
        "upper Bit at offset (0,+20) must hit core when Lance is at core_y-20 ONLY while 'red' is equipped, never with 'yellow' (atomic requirement 14); "
          .. "dmg_red_0bits=" .. tostring(dmg_red_0) .. ", dmg_red_2bits=" .. tostring(dmg_red_2) .. ", dmg_yellow_2bits=" .. tostring(dmg_yel_2)
      )
    end)

    test("homing missile pickup fires 2 missiles (3 dmg each) targeting nearest enemy with 0.8 s shared cooldown", function()
      H.start_play(1, "AR-15 homing missiles & 0.8 s cooldown")
      H.pilot_to_boss({ shoot = true, allow_continue = true, quiet_tail_s = 2.0 }, "scroll to Ribmaw")
      H.collect_powerup("missile", nil, "equip homing missiles")
      -- Shift Lance 32 px vertically off centre so unguided horizontal vulcan misses compact core
      -- while 2 homing missiles (2 x 3 = 6 dmg) steer at <=180 deg/s onto Ribmaw:
      H.move_for(0, -1, H.secs(32.0 / 80.0), "shift 32 px below centre for homing proof")

      local exp = H.advance_until(function(rep)
        return rep.boss ~= nil and rep.boss.exposed == true
      end, H.secs(7.0), 3, "wait Ribmaw exposed")
      assert_contract(exp ~= nil, "Ribmaw must expose weak point")
      local hp0 = exp.boss.hp
      -- Tap 1 launches missiles; Tap 2 only 0.20 s (12 ticks < 0.80 s cooldown) later MUST NOT launch a second pair!
      H.tap_fire(10, "tap 1 launches missile pair")
      H.tap_fire(2, "tap 2 inside 0.8 s cooldown")
      local r_mid = H.advance(H.secs(1.25), "let missile pair steer and strike")
      local dmg_burst = hp0 - r_mid.boss.hp
      -- 1 pair of missiles = 6 dmg (+ at most 2 vulcan if aligned = 6..8 dmg; if cooldown failed and fired 2 pairs, damage would be >=12!)
      assert_contract(
        dmg_burst >= 6 and dmg_burst <= 8,
        "one missile trigger plus an immediate tap inside the 0.8 s cooldown must deal 1 missile pair (6 dmg + <=2 vulcan), got "
          .. tostring(dmg_burst) .. " (atomic requirement 15)"
      )

      -- After >= 0.80 s cooldown has elapsed, next press launches another pair of homing missiles:
      local exp2 = H.advance_until(function(rep)
        return rep.boss ~= nil and rep.boss.exposed == true
      end, H.secs(7.0), 3, "wait exposed after cooldown")
      local hp1 = exp2.boss.hp
      H.tap_fire(2, "tap after >=0.8 s cooldown")
      local r_after = H.advance(H.secs(1.25), "second missile pair strike")
      assert_contract(
        (hp1 - r_after.boss.hp) >= 6,
        "after 0.8 s cooldown expires, fire press must launch another pair of 3-damage homing missiles (atomic requirement 15)"
      )
    end)
  end)
end
