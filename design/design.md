# Rift Vector — design of record

## 1. Concept

Pilot the RV-7 **Lance**, dodge deliberate Vorn Swarm formations, charge piercing waves and reposition an indestructible Force to clear ten horizontal stages and defeat the Vorn Overmind. Kills, boss bonuses and no-miss clears build a persisted hi-score; unlimited continues keep the campaign approachable but reset the current score. This is original IP with an Amiga-era R-Type influence, never copied Irem artwork, melodies or enemy designs.

## 2. Phase graph

The studio design DAG below is normative; the orchestrator's existing plan uses operational subdivisions and remains orchestrator-owned.

| Phase | Name | Owner role | Depends on | Verifiable gate |
| --- | --- | --- | --- | --- |
| 1 | Intent and contracts | planner | concept | Fully populated typed `GameDesignSpec`; `emit-constants` exit 0 |
| 2 | Sprite and tile production | executor (`sprite-artist`) | 1 | `verify-sprites`: zero findings for all 48 requests |
| 3 | Audio production | executor (`sound-designer`) | 1 | `verify-audio`: zero findings for all 22 cues |
| 4 | Gameplay logic and GUI | executor (`code-monkey`) | 2 + 3 | `defold_compile`: `ok: true`, empty diagnostics |
| 5 | Blind behavioural tests | executor (`defold-qa-architect`) | 4 | `defold_test_run`: `failed: 0`, exit 0 |
| 6 | Tier-2 review and bundle | reviewer (`defold-reviewer`) | 5 | Both Tier-2 stages pass and every declared target runs |

Graph: **1 → (2 ∥ 3) → 4 → 5 → 6**. Art and audio use disjoint directories in separate worktrees. Blind QA authors immutable red contracts concurrently with 2/3 in a third worktree; the green gate waits for 4. Executors use available `defold_project_init`, `defold_mutate_resource`, `defold_project_settings`, `defold_compile`, `defold_test_run`, `defold_bundle` and `defold_docs_search`, never raw-editing embedded resource strings in `.collection` or `.go` files.

## 3. Spec fields

`assets/gdd/game.json` is the closed-schema machine contract; this document supplies numerical runtime and stage detail that its schema does not encode separately.

| Field | Value / unit |
| --- | --- |
| `title`, `slug`, `profile` | Rift Vector; `rift-vector`; `2d_pixel` |
| `resolution` | 320×200 logical px; window 960×600 px; nearest-neighbour, integer upscale with letterboxing |
| `palette_hex` | 16 colours: black/deep space, three greys, green, three reds, two oranges, two blues, yellow, two flesh tones; exact hex values in JSON |
| `input_actions` | Eight actions: four movement axes, fire, force, start, pause; bindings below |
| `message_ids` | 18 identifiers, payloads below; bot and keyboard share one command path |
| `collision_groups` | Eight symmetric masks in JSON; bits share `force_pod`, with ram damage disabled for bits |
| `screens` | `title`, `play`, `pause`, `stage_clear`, `game_over`, `victory` |
| `atomic_requirements` | 32 independently assertable sentences; timing comparisons use simulation time with one 60 Hz tick tolerance |
| `sprites` | 48 requests, one animation each; 8×8 to 128×96 px; strips 128×16 px; every pivot `center`; frame rates 8/10/12/16 fps as declared |
| `audio_cues` | 22 cues: 13 effects, six music loops, three non-looping jingles; route `parametric_synth`; 44,100 Hz, cooldown 0.06 s |
| `platforms` | `x86_64-linux`: OpenGL + Vulkan, `main/game.appmanifest`; `wasm-web`: WebGL, manifest null |
| `art_direction` | Original 16-bit Amiga-era biomechanical pixel art, Giger-influenced horror-mechanical detail; 14-colour subset; cohesion floor **70.0/100**; primitive gameplay art forbidden |

**Composition and coordinates.** Bottom-left origin; HUD y=0..24, playfield y=24..200. Lance starts at (64,112); centre bounds x=16..304, y=32..192; collision hull 20×8 px. Terrain bands occupy y=24..40 and y=184..200, with stage intrusions leaving at least 64 px clear vertical passage. HUD uses two 8 px text rows at y=4 and 14: first `1P` score at x=4 and `HI` at x=160; second lives at x=4, `BEAM` at x=64, gauge x=96..160, stage at x=240. Scores are nine decimal digits, saturating at 999999999. GUI text uses the scaffold font nearest-filtered; all HUD text fits its assigned band. Foreground order: stars, terrain, enemies, projectiles, ship/Force/bits, effects, HUD. Black space keeps attack silhouettes legible.

**Art invariants.** All dimensions and authored anchors use the studio 8-pixel grid, snapped downward; each clip has one shared joint palette lock. Internal pixel detailing remains 1 px. Binary alpha, 10–88% opaque coverage and a transparent outer border apply even to tile strips. Tile strips are sliced into eight 16×16 cells in their declared order; deliberate dark mortar seams are non-colliding. Facing is a flip, never another authored set: `sprite.set_hflip("#sprite", true)` for left, `false` for right; Lance stays right-facing, with rear weapons flipped independently. Red enemies read against riveted grey structures; top-left hard rim lights unify matte metal and wet organic cores. No untextured, unshaded boxes, spheres, flat colour blocks or debug meshes ship as gameplay art.

**Motion contract.** Position, rotation and scale motion use `go.animate` with explicit playback/easing, not hand-written per-frame position integration. On input-vector change, cancel the affected position tweens and animate x/y to the appropriate clamped boundary with `PLAYBACK_ONCE_FORWARD`, `EASING_LINEAR`, duration axis distance / normalized axis speed; zero axes cancel and hold. Speed is 80+16×speed-level px/s, diagonal-normalized. Recompute remaining tweens after pause. Ordinary enemies cross x=344→−24 with linear once-forward duration 368/48 s; vertical formation motion is y=anchor+24 px, loop-pingpong, in-out-sine, 1.4 s each leg. Carrier hop is y=anchor+16 px, loop-pingpong, in-out-sine, 0.6 s each leg. Foreground scroll x=0→−1920 px, once-forward linear, 80 s; stars loop-forward linear over 320 px at 4/8/12 px/s in three depth layers. Force launch/recall/follow use once-forward linear target tweens, durations distance/200 or distance/160 s; retarget only when the ship target changes. Bits follow ship transform as children. Boss lobe orbit rotation.z targets 360 degrees, loop-forward linear, 6 s; core visual scale targets 1.0625, loop-pingpong in-out-sine, 0.4 s. Missiles steer rotation at at most 180 degrees/s and retarget short linear position tweens every 0.05 s; angle changes also use explicit linear once-forward rotation tweens. Projectile speed: vulcan 240, waves 280, lasers 220, missiles 160 px/s; each flight tween ends at its world boundary, with duration distance/speed. Cinematic screen transitions fade GUI alpha once-forward linear over 0.25 s; pause itself is immediate.

## 4. Assets

### Visual inventory

Names below are `asset_id.animation`; counts are authored frames, not seconds. All multi-frame art changes pose **in place**, with stable body anchors, not whole-body translation or frozen dither.

| Family | Identifiers and frame counts |
| --- | --- |
| Lance and support | `ship.fly` 4; `force_lv1.pulse`, `force_lv2.pulse`, `force_lv3.pulse`, `bit.orbit` 2 each |
| Projectiles | `player_shot.fly` 1; `wave_beam.surge`, `laser_red.surge`, `laser_blue.surge`, `laser_yellow.surge`, `missile.fly`, `enemy_orb.pulse` 2 each; `enemy_shot.fly` 1 |
| Ordinary enemies | `drone.fly`, `carrier.hop`, `fighter.fly`, `worm_segment.writhe`, `turret.aim`, `crawler.crawl`, `mine.arm`, `dop.guard` 2 each |
| Pickups | `crystal_red.pulse`, `crystal_blue.pulse`, `crystal_yellow.pulse`, `pickup_bit.pulse`, `pickup_speed.pulse`, `pickup_missile.pulse` 2 each |
| Effects | `explosion_small.burst`, `explosion_big.burst` 4 each |
| Bosses | `boss_01_ribmaw.attack` 4; `boss_02_oculocyst.attack` 4; `boss_03_iron_vesper.attack` 2; `boss_04_trifold.attack`, `boss_05_bellmite.attack`, `boss_06_piston_worm.attack`, `boss_07_dop_regent.attack`, `boss_08_hatch_warden.attack`, `boss_09_guarded_core.attack`, `boss_10_overmind.attack` 4 each; `boss_core.pulse` 2 |
| Environment | `tileset_metal.strip`, `tileset_flesh.strip`, `tileset_ruins.strip`, `tileset_core.strip` 1 each; `star_spark.glint` 1 |
| GUI | `hud_panel.panel`, `beam_gauge.bar`, `life_icon.icon` 1 each |

Use **small star sprites**, 18 instances across three depth layers, not a sparse full-screen image. Metal/flesh/ruins/core strips each provide plate/body, pipe/rib, vent/sac, cable/vein, upper lip, lower lip, inner corner and endcap variants. Large bosses reuse `turret`, `worm_segment`, `dop`, `mine` and `boss_core` parts. Iron Vesper's repeated 128×96 hull sections span the scrolling stage; its final engine section uses the same art. Trifold's lobe parts are atlas subregions of its own sheet, not additional requests.

### Ten-stage schedule

Each stage scrolls 1920 px at 24 px/s (80 s), then locks for its boss; checkpoint at 1152 px (48 s). Boss clocks reset on death. Column Δspawn is the base ordinary formation interval, distinct from guaranteed 12 s carriers; a formation contains 1–3 enemies with 0.2 s entry spacing. Bullets use the listed base speed; aimed shots lock direction at emission. Caps: eight ordinary enemies, ten hostile bullets, one aimed volley per second, with overflow deferred. No aimed spawn within 48 px of Lance. Every damaging boss move has a ≥0.60 s visible tell.

| # / stage | Theme / tileset | Gimmick; enemy mix | Boss: attack pattern; weak point | Δspawn / bullet / HP |
| --- | --- | --- | --- | --- |
| 1 — Breach Wake | Outer dock / metal | Wide gaps, tutorial carrier; drone, fighter, turret | **Ribmaw**: tail sweep then chest laser; chest opens 2.5 s every 6 s | 2.40 s / 36 px/s / 120 |
| 2 — Living Throat | Flesh cave / flesh | Pulsing ribs leave 80 px channel; worm, drone, crawler | **Oculocyst**: two worm chains then aimed spores; eye opens 2.4 s every 6 s | 2.30 s / 39 px/s / 140 |
| 3 — Vesper Broadside | Whole-stage battleship / metal | Destructible deck turrets, rear engine approach; turret, fighter, mine | **Iron Vesper**: rear fan then engine exhaust; rear bay opens 2.3 s every 6 s, encouraging rear Force; unpowered Lance can fly behind it | 2.20 s / 42 px/s / 160 |
| 4 — Broken Compiler | Ruined assembly / ruins | Alternating top/bottom entry; fighter, crawler, drone | **Trifold Compiler**: splits into three 6 s orbiting lobes, staggered single shots; hub exposed 2.2 s every 6 s | 2.10 s / 45 px/s / 180 |
| 5 — Bell Nursery | Cell chambers / flesh | Mine cells drift through broad lanes; mine, worm, drone | **Bellmite Matron**: six 2-HP shell cells shed sequentially, then slow spore fans; centre exposed 2.2 s every 6 s after shell clearance | 2.00 s / 48 px/s / 200 |
| 6 — Transit Artery | Hydraulic tunnel / metal | Telegraphing pistons alternate lanes; crawler, turret, worm | **Transit Piston**: retracts, lunges along one marked lane, then vents; throat valve exposed 2.1 s every 6 s | 1.90 s / 51 px/s / 220 |
| 7 — Mirror Brood | Clone foundry / ruins | Pairs of front-core clones; dop, fighter, drone | **Dop Regent**: commands four 3-HP dop clones, recalls survivors before next cycle; front crown core opens 2.0 s every 6 s | 1.80 s / 54 px/s / 240 |
| 8 — Falling Cathedral | Cargo vault / ruins | Ceiling debris uses mine art and marked fall lanes; turret, mine, crawler | **Hatch Warden**: drops three debris pieces, pauses, exposes hatch furnace 1.9 s every 6 s | 1.70 s / 57 px/s / 260 |
| 9 — Citadel Heart | Guarded reactor / core | Mixed rehearsed formations, two safe lanes; dop, worm, turret | **Citadel Heart**: rotating guard fan then straight core beam; central iris opens 1.8 s every 6 s | 1.60 s / 60 px/s / 280 |
| 10 — Rift Sovereign | Neural rift / core | Reprises of prior lane tells, no new input; fighter, dop, mine | **Vorn Overmind**: HP 300→151 alternating heart volleys, HP ≤150 crown opens and one marked lane sweep; neural eye exposed 1.8 s every 6 s in both phases | 1.50 s / 63 px/s / 300 |

Boss HP excludes optional destructible parts; reaching zero ends the encounter regardless of surviving parts. Stage-3 turrets during scrolling are ordinary scored targets, not an early boss-completion condition. Stage 10 uses `bgm_stage_c` during scrolling; final-boss music begins at its lock.

### Weapons, economy and scoring

**Fire edge contract:** a press immediately gives one vulcan shot; repeated distinct taps repeat that shot, never a three-shot burst. A held press emits no more vulcan: charging begins at 0.30 s, total hold 0.60/1.10/1.80 s selects tier 1/2/3, release launches the highest reached tier or nothing below tier 1. Full charge stays capped. Attached lasers, detached patterns, red bits and equipped missiles trigger on the same press edge only; charge release adds only the wave. Simultaneous Z/Space form one logical action: first down presses, last up releases. OS repeat is ignored. Death/pause/screen change cancels the action and charge without firing. Require all held keys released before a new press on resume.

| Attack | Damage and lifetime |
| --- | --- |
| Vulcan / detached Force bullet / bit bolt | 1 per target hit; consumed on first hit; 2 s maximum |
| Wave tiers 1/2/3 | 8/20/48 per target once; height 8/16/24 px, visible scale matches collision; 2 s maximum; pierces enemies, not terrain |
| Red | Two strands, each 1/2/3 damage at Force L1/L2/L3; max-level helix is a symmetric ±4 px sine offset, 0.4 s loop-pingpong in-out-sine visual tween |
| Blue | Three beams, each 1/2/3 damage by Force level; at most two terrain reflections, 1.2 s lifetime; 0.1 s same-target hit cooldown |
| Yellow | Two plumes, each 1/2/3 damage per 0.2 s contact tick; axis-aligned terrain-boundary crawl at 80 px/s; expire at 0.8 s or an open edge |
| Missile | Two missiles, 3 damage each; shared 0.8 s press-edge cooldown, 2 s lifetime; travel straight if no live target |
| Force ram | 4 damage per enemy per 0.25 s contact; orb never takes damage, stops at terrain; bits do no ram damage |

Force radius 6 px; ship-side attachment offsets ±24 px. Launch passes enemies and settles on the opposite half at x=264/56, with 16 px midpoint hysteresis to prevent oscillation; Y target is clamped to 40..184. Recall can attach from either side by contact, using sign of pod.x−ship.x. Once acquired but without a colour after death, attached Force emits one 1-damage bolt per press; detached level patterns remain available. Ordinary HP: drone 1, fighter 2, carrier 2, turret 4, worm segment 2, crawler 3, mine 1, dop 3 (front-core vulnerable hemisphere only). Wave tier 3 clears a three-fighter formation. Boss cores accept all player attacks, including vulcan, only while exposed.

Guaranteed carriers arrive every 12 scrolling seconds with drops red, blue, bit, yellow, missile, speed at 12/24/36/48/60/72 s; schedule repeats each stage. Carrier hops between two authored lanes, never terrain. Pickups drift left at 24 px/s and expire on exit; if bits are already full, a bit becomes a red crystal, and a capped speed pickup becomes a blue crystal. This yields three early crystals for Force progression without random starvation.

Three lives count the current ship. On death wait 1.0 s, then restart the reached checkpoint (start until 60%, mid-stage thereafter); at zero lives show game over and wait for unlimited Enter continues. A previously acquired Force returns front-attached at L1; colour, bits, missiles and speed reset. Respawn protects for 2.0 s with a 10 Hz blink. Scroll enemies, pickups and bosses reset from deterministic stage data; no-miss eligibility remains lost. On continue reset current score, lives to three and stage spawn reward ledger; hi-score remains. New stages retain equipment and remaining lives; there are no extra-life thresholds.

| Scored target / event | Points |
| --- | ---: |
| drone | 100 |
| fighter / crawler | 200 |
| carrier | 500 |
| turret | 300 |
| worm segment | 150 |
| mine | 50 |
| dop | 250 |
| Boss, stage n | 5000 + 1000×n |
| Stage no-miss | 10000 |

Award kills only once per deterministic `(stage, spawn_id)` in a score run to prevent checkpoint farming; boss summons also have cycle-indexed identifiers. No-miss means no death since first entering that stage, including deaths before a continue. Optional shell cells/guards yield no points. Save hi-score immediately upon increase with `sys.save` in the `rift-vector` save directory, key `hi_score`; load only a finite non-negative integer, default zero on corrupt/missing data, and never overwrite a valid in-memory high value with corrupt data. Web persistence uses the engine's browser-backed save storage on the same origin.

### Input and messages

Keys on both targets: arrows/WASD movement; Z/Space fire; X/Left-Shift Force; Enter start/confirm/continue; P pause. Keyboard input and the blind bot call identical handlers. Bot messages target the gameplay controller at `/game#controller`, available on title and throughout play; displacement persists until superseded by `input_move`. Opposite keys cancel; normalize non-zero diagonals. No input changes simulation while paused except pause itself; start and movement then have no gameplay effect.

| Message | Payload and interpretation |
| --- | --- |
| `input_move` | `{dx:number, dy:number}` each −1..1, positive right/up, normalize magnitude above 1; `{0,0}` stops |
| `input_fire_press`, `input_fire_release` | `{}`; edges only, repeated press while held ignored |
| `input_force` | `{}`; attached→launch, detached/launching→recall, recalling→no-op, unacquired→no-op |
| `input_start` | `{}`; title→new run, stage_clear→next stage, game_over→continue, victory→title; ignored during play |
| `input_pause` | `{}`; play↔pause; clears pending input and charge |
| `player_hit` | `{source_id:string}`; lethal only without respawn protection |
| `enemy_killed` | `{spawn_id:string, kind:string, stage:number}`; controller computes points, never trusts caller-supplied score |
| `score_add` | `{amount:integer, reason:string, award_id:string}`; internal controller-only deduplicated award |
| `powerup_collected` | `{kind:string, spawn_id:string}`; kind `red`, `blue`, `yellow`, `bit`, `speed`, `missile` |
| `stage_clear`, `boss_defeated` | `{stage:integer}`; boss message authorizes clear exactly once |
| `game_over` | `{stage:integer, score:integer}` |
| `wave_charge` | `{tier:integer, fraction:number}`; tier 0..3, fraction 0..1 measured across total 1.8 s hold |
| `force_state` | `{state:string, level:integer, weapon:string}`; states attached_front/attached_rear/launching/detached/recalling; weapon vulcan/red/blue/yellow |
| `checkpoint_reached` | `{stage:integer, scroll_px:1152}` |
| `audio_request` | `{cue_id:string}`; mixer applies cue/group policy |
| `screen_changed` | `{screen:string}` from the six declared screens |

`STUDIO_TELEMETRY` carries **ONLY** `bot_input`, `audio_play`, `audio_cooldown_suppressed`, `audio_unlock`, `audio_unlock_skipped`, `audio_rms`, `audio_reset`, emitted through the shipped studio runtime schemas. Gameplay messages are not telemetry events. Suite summaries use **deftest**, never this channel; the bot finishes through the system exit message with explicit success/failure code. Capture bot-driven input, actual audio playback and RMS plus non-empty PNG frames. Web real Enter gesture unlocks audio; synthetic bot input alone must not claim a user unlock.

### Audio inventory

| Cue identifiers | Presets / intent |
| --- | --- |
| `shot`, `wave_fire` | laser; short dry zap versus broad descending lance |
| `charge_rise`, `pickup_power` | powerup; rising charge versus brief support chime |
| `enemy_hit`, `boss_alert` | hit; dry tick versus low warning impact |
| `explosion_small`, `explosion_big`, `player_die` | explosion; increasing noise body, distinct death tail |
| `pickup_crystal` | pickup; clear pitched crystal bell |
| `force_attach`, `ui_select` | select; metallic latch versus soft confirmation |
| `force_launch` | jump; upward FM flick with short noise edge |
| `bgm_title` | powerup; 8 bars, 100 BPM, D minor |
| `bgm_stage_a` | laser; 16 bars, 120 BPM, D minor; stages 1/4/7 |
| `bgm_stage_b` | hit; 16 bars, 132 BPM, G harmonic minor; stages 2/5/8 |
| `bgm_stage_c` | jump; 16 bars, 126 BPM, A Phrygian; stages 3/6/9/10 |
| `bgm_boss`, `bgm_final_boss` | hit / explosion; 8 bars at 140 / 148 BPM, D Phrygian / D harmonic minor |
| `jingle_stage_clear`, `jingle_game_over`, `jingle_victory` | coin / hit / coin; non-looping 2 bars at 120, 2 at 90, 4 at 110 BPM |

All music is original seeded FM+PSG-style composition in 4/4; `synth_spec` supplies mode and dramatic character, not an instruction to render one preset impulse as an entire song. Sound designer records distinct seeds for all 13 SFX preset/seed pairs. Master SFX to PCM_16 WAV, music loops to bar-exact Ogg Vorbis; jingles to non-looping PCM_16 WAV at their declared bar length. Mix gains: bgm 0.45, sfx 0.8, ui 0.8; maximum eight SFX voices with death/alert priority over shot. Charge starts once at 0.30 s and stops on release/death/pause; bar loops have no unintended gaps, with the tool's short edge taper documented. Pause ducks BGM to 0.15 and stops charge. Stage-clear/game-over/victory stop BGM and play their own cue once; title resumes its own loop.

## 5. Acceptance

- **Phase 1:** the two design files agree, every closed-schema field is populated, and `emit-constants` validates the JSON with exit 0 without any executor changing creative intent.
- **Phase 2:** `verify-sprites` reports zero findings for all 48 requests, with authored in-place poses, shared clip palettes, intact borders and no primitive shipping art.
- **Phase 3:** `verify-audio` reports zero findings across all 22 mastered cues, with six bar-exact loops, distinct SFX seeds and the declared FM/PSG composition character.
- **Phase 4:** structured Defold 1.14.1 compilation returns `ok: true` with empty diagnostics for integrated art, audio, gameplay, HUD and the wired Linux manifest.
- **Phase 5:** immutable blind tests pass all 32 atomic requirements and stage-specific patterns with `failed: 0` and exit 0, including edge-time fire semantics, save restart, all ten bosses and continue economy.
- **Phase 6:** factual Stage-2a inspection quotes captured frames, Stage-2b `verify-tier2` passes with cohesion ≥70 and no failure route, the reviewer approves, telemetry verification has zero findings, and both target-runtime proofs below pass.
- **Linux target:** bundle `x86_64-linux`, wire `[native_extension] app_manifest = /main/game.appmanifest` to `main/game.appmanifest`, verify compiled `.spc` contains GLSL 330 and SPIR-V variants, then run that bundle separately with explicitly selected Vulkan and OpenGL under xvfb, recording the selected adapter, allowed telemetry, non-empty captured gameplay PNG and scripted clean exit 0 for each backend.
- **Web target:** bundle `wasm-web` with WebGL and no manifest, verify `index.html`, a `.wasm` module and `game.arcd` exist, serve the bundle over local HTTP, and use a real browser to load index, observe successful engine/Wasm initialization without console or network errors, press Enter to unlock/start, drive the same bot messages, capture allowed telemetry and a non-empty gameplay PNG, and record successful suite completion before closing the page.

Screenshots must show actual textured/shaded authored gameplay, not just title/blank canvas. Missing runtime access is a surfaced blocked gate, never an assumed pass. ACI files (`design/**`, `assets/gdd/**`, animation timing) are planner-owned: executors fix failed assets by regeneration, or return a design change request naming field, observation and proposed value; no raw-editing intent to satisfy a gate.

## 6. Assumptions and risks

- **Production capacity:** 48 clips is a large batch; reuse boss part clips and stage strips as specified, without removing ten distinct bosses. If wrong, cost is longer art production and repeat verification, not silently reduced scope.
- **GPU capacity:** about 2.7 GB free VRAM may require model offload; a local `pixelArtDiffusionXL_spriteShaper` checkpoint is installed. If generation cannot fit, cost is slower tiled/offloaded production or a planner-approved model substitution, never shipping fallback blocks.
- **Frame consistency:** generative multi-frame output can drift or fake motion with translation. Stable anchors, in-place articulated prompts and joint palette lock are mandatory; cost if wrong is regenerated sheets and a delayed art gate.
- **Audio deviation:** original seeded FM/PSG multi-stem BGM is an approved custom-rendering deviation behind `parametric_synth`; the shipped one-shot presets alone cannot compose these loops. Cost if unavailable is explicit audio production work or a planner change request, not repeated SFX labelled music.
- **Checkpoint interpretation:** use last reached checkpoint, start before 60%, midpoint afterwards; recommendation avoids skipping early teaching sections. Cost if a different interpretation was intended is respawn/test revision; campaign and scoring remain unchanged.
- **Force-side interpretation:** detached holding position is opposite the player's half, with contact choosing attachment side; this resolves the concept's spatial ambiguity without extra controls. Cost if it reads poorly is a planner-owned tuning change to hysteresis/settle position.
- **Gentle ramp:** capped enemies/bullets and ≥0.60 s tells are the casual-accessibility budget; cost if too harsh is planner-approved stage timing/HP tuning and regenerated QA expectations, not changes to authored art.
- **Hi-score storage:** browser saves require an unchanged origin and available persistent storage; blocked/cleared storage costs persistence and must surface a save warning while retaining the in-memory score.
- **Native runtime:** Vulkan needs a functioning ICD under xvfb as well as both compiled shader variants; cost if unavailable is a blocked Linux acceptance run on this host and a required capable runner.
- **Plan numbering:** existing orchestration groups asset/test authoring differently from the studio's six normative gates; cost if confused is scheduling errors, prevented by dependency/gate mapping rather than rewriting the orchestrator-owned plan.
