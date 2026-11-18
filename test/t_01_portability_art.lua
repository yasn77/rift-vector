-- test/t_01_portability_art.lua -- Blind portability, manifest, platform-target
-- and art-direction red contracts (Role section 4a, Atomic Requirements 30 & 31).

local H = require "test.harness"
local G = require "test.gdd_data"
local driver = require "bot_driver"

return function()
  describe("Portability and art-direction contracts", function()
    before(function()
      H.use_assert(assert_contract)
    end)

    test("PlatformTarget[x86_64-linux].appmanifest_path is wired in game.project", function()
      local target = G.PLATFORMS[1]
      local configured = sys.get_config_string("native_extension.app_manifest")
      assert_contract(
        configured == target.config_manifest_path,
        "PlatformTarget('" .. target.platform .. "').appmanifest_path requires "
          .. "[native_extension] app_manifest = " .. target.config_manifest_path
          .. " in game.project, got '" .. tostring(configured) .. "'"
      )
    end)

    test("PlatformTarget[x86_64-linux].backends enables OpenGL and Vulkan in game.appmanifest", function()
      local raw = sys.load_resource("/main/game.appmanifest")
      assert_contract(
        type(raw) == "string" and #raw > 0,
        "PlatformTarget('x86_64-linux').backends=['opengl','vulkan'] requires "
          .. "/main/game.appmanifest declared in [project] custom_resources and readable via sys.load_resource"
      )
      assert_contract(
        string.find(raw, "GraphicsAdapterOpenGL", 1, true) ~= nil,
        "PlatformTarget('x86_64-linux').backends requires GraphicsAdapterOpenGL in /main/game.appmanifest"
      )
      assert_contract(
        string.find(raw, "GraphicsAdapterVulkan", 1, true) ~= nil,
        "PlatformTarget('x86_64-linux').backends requires GraphicsAdapterVulkan in /main/game.appmanifest"
      )
      assert_contract(
        string.find(raw, "x86_64-linux", 1, true) ~= nil,
        "PlatformTarget('x86_64-linux') requires x86_64-linux in /main/game.appmanifest context.includes"
      )
    end)

    test("PlatformTarget[x86_64-linux] runtime acceptance: display aspect, resources and dual-backend manifest", function()
      local w = tonumber(sys.get_config_string("display.width") or "0") or 0
      local h = tonumber(sys.get_config_string("display.height") or "0") or 0
      local valid_aspect = (w == G.LOGICAL_W and h == G.LOGICAL_H)
        or (w == G.WINDOW_W and h == G.WINDOW_H)
      assert_contract(
        valid_aspect,
        "PlatformTarget('x86_64-linux') requires 320x200 logical or 960x600 integer-upscaled 16:10 display in game.project, got "
          .. tostring(w) .. "x" .. tostring(h)
      )
      local custom = sys.get_config_string("project.custom_resources") or ""
      assert_contract(
        string.find(custom, "/main/game.appmanifest", 1, true) ~= nil
          and string.find(custom, "/assets/sprites/manifest.json", 1, true) ~= nil
          and string.find(custom, "/assets/audio/audio_manifest.json", 1, true) ~= nil,
        "PlatformTarget('x86_64-linux') blind-test resource contract requires [project] custom_resources "
          .. "to list /main/game.appmanifest, /assets/sprites/manifest.json and /assets/audio/audio_manifest.json, got '"
          .. tostring(custom) .. "'"
      )
      local report = H.start_play(1, "x86_64-linux acceptance")
      assert_contract(
        report.screen == "play",
        "PlatformTarget('x86_64-linux') acceptance requires gameplay controller to enter 'play' via shared input messages"
      )
    end)

    test("PlatformTarget[wasm-web] runtime acceptance: WebGL config, manifest exclusion and shared bot controls", function()
      local scale_mode = sys.get_config_string("html5.scale_mode")
      assert_contract(
        type(scale_mode) == "string" and scale_mode ~= "",
        "PlatformTarget('wasm-web').backends=['webgl'] requires [html5] configuration in game.project"
      )
      local raw_manifest = sys.load_resource("/main/game.appmanifest")
      assert_contract(
        type(raw_manifest) == "string" and string.find(raw_manifest, "wasm-web", 1, true) ~= nil,
        "PlatformTarget('wasm-web').appmanifest_path=null requires /main/game.appmanifest to exclude wasm-web so WebGL builds stay clean"
      )
      for i = 1, #driver.ACTIONS do
        local msg_id, payload = driver.message(driver.ACTIONS[i])
        assert_contract(
          type(msg_id) == "string" and type(payload) == "table",
          "PlatformTarget('wasm-web') requires every bot_driver action to map onto a published controller message"
        )
      end
      local report = H.start_play(1, "wasm-web acceptance")
      assert_contract(
        report.screen == "play",
        "PlatformTarget('wasm-web') acceptance requires identical bot-message start into 'play'"
      )
    end)

    test("ArtDirectionSpec sprite manifest declares all 48 compiled sprite entries", function()
      local raw = sys.load_resource("/assets/sprites/manifest.json")
      assert_contract(
        type(raw) == "string" and #raw > 0,
        "ArtDirectionSpec / sprites contract requires /assets/sprites/manifest.json readable via sys.load_resource"
      )
      assert_contract(
        string.find(raw, '"schema"', 1, true) ~= nil and string.find(raw, ".png", 1, true) ~= nil,
        "ArtDirectionSpec requires /assets/sprites/manifest.json to carry schema=1 and compiled .png paths"
      )
      local missing = {}
      for i = 1, #G.SPRITES do
        local id = G.SPRITES[i]
        local quoted = '"' .. id .. '"'
        if string.find(raw, quoted, 1, true) == nil then
          missing[#missing + 1] = id
        end
      end
      assert_contract(
        #missing == 0,
        "ArtDirectionSpec requires all 48 sprite asset_ids in /assets/sprites/manifest.json; missing ("
          .. tostring(#missing) .. "): " .. table.concat(missing, ", ")
      )
    end)

    test("Audio cue manifest declares all 22 mastered cues", function()
      local raw = sys.load_resource("/assets/audio/audio_manifest.json")
      assert_contract(
        type(raw) == "string" and #raw > 0,
        "audio_cues contract requires /assets/audio/audio_manifest.json readable via sys.load_resource"
      )
      local missing = {}
      for i = 1, #G.AUDIO_CUES do
        local cue = G.AUDIO_CUES[i]
        if string.find(raw, '"' .. cue .. '"', 1, true) == nil then
          missing[#missing + 1] = cue
        end
      end
      assert_contract(
        #missing == 0,
        "audio_cues contract requires all 22 cue_ids in /assets/audio/audio_manifest.json; missing ("
          .. tostring(#missing) .. "): " .. table.concat(missing, ", ")
      )
    end)

    test("ArtDirectionSpec enforces nearest-neighbour filtering, compiled atlases and zero primitive placeholders", function()
      local min_f = sys.get_config_string("graphics.default_texture_min_filter")
      local mag_f = sys.get_config_string("graphics.default_texture_mag_filter")
      assert_contract(
        min_f == "nearest" and mag_f == "nearest",
        "ArtDirectionSpec (2d_pixel nearest-neighbour display, atomic requirement 31) requires "
          .. "graphics.default_texture_min_filter='nearest' and default_texture_mag_filter='nearest', got min='"
          .. tostring(min_f) .. "', mag='" .. tostring(mag_f) .. "'"
      )

      local scene = H.collect_scene_files("/main/main.collection")
      local scene_blob = scene.all_text
      assert_contract(
        type(scene_blob) == "string" and #scene_blob > 0,
        "ArtDirectionSpec check requires main/main.collection scene definition"
      )

      local binds_real_2d_art = string.find(scene_blob, ".atlas", 1, true) ~= nil
        or string.find(scene_blob, ".tilesource", 1, true) ~= nil
      assert_contract(
        binds_real_2d_art,
        "ArtDirectionSpec (cohesion_floor=70.0, allow_primitive_placeholders=false) requires shipped collections/GOs "
          .. "to bind compiled .atlas/.tilesource art rather than an unarted scaffold"
      )

      local primitives = { "cube.dae", "sphere.dae", "quad.dae", "cone.dae", "cylinder.dae" }
      for i = 1, #primitives do
        assert_contract(
          string.find(scene_blob, primitives[i], 1, true) == nil,
          "ArtDirectionSpec.allow_primitive_placeholders=false forbids primitive mesh placeholder '"
            .. primitives[i] .. "' in shipped collections"
        )
      end
    end)
  end)
end
