# Rift Vector

An original horizontal scrolling score-attack shoot-'em-up in the spirit of Irem's 1987
classic **R-Type** — its Force pod, chargeable Wave Cannon and laser-crystal upgrades —
with ten stages, ten bosses, and an Amiga-era biomechanical pixel-art look. All artwork,
music and code in this repository are original; R-Type is the inspiration, not the source.

Built with **Defold 1.14.1** for **Linux x86_64** (OpenGL + Vulkan) and the **web** (WebGL).

## Play

### Linux
```bash
cd dist/linux
./RiftVector.x86_64
```
No installation needed. The binary selects Vulkan when available and falls back to OpenGL.

### Web
Serve `dist/web` over HTTP (any static server) and open `index.html`:
```bash
cd dist/web
python3 -m http.server 8080
# then open http://localhost:8080/
```
Audio unlocks on your first key press (browser policy).

## Controls

| Key | Action |
| --- | --- |
| Arrows / WASD | Move |
| Z or Space (tap) | Vulcan shot |
| Z or Space (hold ≥ 0.3 s, release) | Charge the Wave Cannon — tiers at 0.6 / 1.1 / 1.8 s; the BEAM gauge shows charge |
| X or Left Shift | Launch / recall the Force pod |
| Enter | Start / continue / next stage |
| P | Pause |

## The game

- **Ten stages**, each ending in a boss with a telegraphed attack cycle and an exposed
  weak point. Difficulty ramps gently: spawn density, bullet speed and boss HP rise
  from stage 1 to 10; enemy and bullet counts are capped so patterns stay readable.
- **Force pod**: indestructible. Collect a laser crystal to summon it; further crystals
  raise it to level 3. Attach it front or rear by contact (it shields you and fires your
  laser in that direction), or launch it across the screen as a ram. Detached, it mirrors
  your height and fires spreading bullets.
- **Laser crystals**: red = twin forward lasers (helix at max), blue = reflecting beams,
  yellow = terrain-crawling plumes. The colour you collect last is the weapon you fire.
- **Bits** (up to two) block bullets and fire with the red laser; **missiles** homing;
  **speed-ups** (cap 3). Carrier drones arrive every 12 seconds with a guaranteed drop.
- **Score attack**: kills, boss bonuses and no-miss stage clears build your score; the
  hi-score persists between sessions. Three lives, checkpoint respawns, unlimited
  continues (a continue resets the current score, never the hi-score). Death keeps your
  Force at level 1 but strips crystals, bits, missiles and speed.

## Build from source

Requires the Defold 1.14.1 toolchain (`bob.jar`) and JDK 25, or the
[`defold-mcp`](https://github.com/yasn77/defold-mcp) server.

```bash
# resolve the deftest dependency once
java -jar bob.jar --root . resolve
# compile / test / bundle
java -jar bob.jar --root . build
java -jar bob.jar --root . --variant release --archive build bundle --platform x86_64-linux --bundle-output build/linux
java -jar bob.jar --root . --variant release --archive build bundle --platform wasm-web --bundle-output build/web
```

Asset pipeline (deterministic, gated): `defold-studio emit-constants / compile-sprites /
verify-sprites / synth-sfx / compile-audio / verify-audio / verify-telemetry / verify-tier2`
against `assets/gdd/game.json`. Sprites were generated through a local ComfyUI
pixel-art checkpoint and compiled to palette-locked strips; audio is seeded FM/PSG-style
synthesis mastered to bar-exact loops.

### Blind test suite and bot

```bash
# 50 behavioural checks (deftest), headless
# via defold-mcp: defold_test_run(test_collection="/test/test.collection")
# scripted bot showcase with telemetry:
./RiftVector.x86_64 --config=rift.bot=1
# frozen boss-encounter photo mode (stage 1..10), emits no telemetry:
./RiftVector.x86_64 --config=rift.photo=3
```

## Credits

Inspired by R-Type (Irem, 1987) — the Force, Wave Cannon and laser-crystal design language.
Rift Vector is an original homage: no Irem artwork, music, names or code are used.
Engine: Defold (King). Test framework: deftest (britzl).
