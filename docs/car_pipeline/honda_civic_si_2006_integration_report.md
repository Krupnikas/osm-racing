# Honda Civic Si 2006 — integration report

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md`
Status: integrated and headless-validated in this pass; existing runtime screenshots are present.

## Summary

| Field | Value |
|---|---|
| Source file | `~/Desktop/OSM material/2006_honda_civic_si.glb` |
| Imported model | `res://car/models/honda_civic_si/honda_civic_si.glb` |
| `car_id` | `honda_civic_si_2006` |
| Display name | Honda Civic Si |
| Target length | ~4.44 m |
| Model vertices | 31,988 |
| Model organization | by material, merged wheel meshes |
| Native forward | +Z |
| Player forward | -Z, model rotated 180 degrees via negative X/Z scene scale |
| NPC forward | +Z, model not rotated |
| Player scene | `res://addons/gevp/scenes/honda_civic_si_car.tscn` |
| NPC scene | `res://traffic/npc_honda_civic_si.tscn` |

## Measurements

Analyzer: `tools/car_model_analyzer.gd`, target length `4.44`.

| Measurement | Value |
|---|---|
| Original real-vertex AABB | size `(0.019, 0.014, 0.044)`, center `(0.000, 0.005, -0.000)` |
| Analyzer scale factor | `100.6321` |
| Scene scale | `101.0854` |
| Scaled dimensions | about `4.46 m L x 1.95 m W x 1.42 m H` |
| Collision shape | `1.72 x 0.90 x 3.95 m`, origin `y=0.55` |
| Wheel radius | `0.312 m` |
| Wheelbase | `2.678 m` |
| Track width | `~1.53 m` |
| Player wheel corners | FL/FR `(±0.757, 0.43, -1.339)`, RL/RR `(±0.771, 0.43, 1.339)` |
| NPC wheel corners | FL/FR `(±0.757, 0.55, 1.339)`, RL/RR `(±0.771, 0.55, -1.339)` |

## Materials and Color

Body paint material is `capaint`; `chassis` is body-like but left alone. The setup scripts recolor only `capaint`.

Player default color is Rallye Red: `#B61920`.

Available mapped colors:
- Taffeta White `#F2F1E8`
- Alabaster Silver Metallic `#BFC0BB`
- Galaxy Gray Metallic `#55565A`
- Nighthawk Black Pearl `#090A12`
- Rallye Red `#B61920`
- Habanero Red Pearl `#9D2D1D`
- Fiji Blue Pearl `#174E9A`

NPC color is selected per instance from a weighted list. Because NPC meshes are merged and cached, color is applied as a per-instance `surface_override_material` on `MergedMesh`.

## Wheels

Wheel geometry is merged by material (`tyre`, `rim`, `calipers`; brake disc material is named `disk`). The integration uses `tools/car_wheel_rig.gd` to split wheels by XZ quadrant and recenter each quadrant so wheels spin in place.

Player path:
- `car/honda_civic_si_setup.gd` builds the wheel rig.
- Four `wheel_*` containers are reparented onto the nearest GEVP `wheel_node`.
- This gives real model wheels suspension travel, spin, and front steer.

NPC path:
- `car/honda_civic_si_npc_setup.gd` builds the wheel rig synchronously before the first `await`.
- Split wheel child meshes are named `wheelmesh_*`.
- `traffic/npc_car.gd` merges the body and collects wheel meshes for `_update_wheel_rotation()`.

## Lights

Player lights are created in `car/honda_civic_si_setup.gd`.

| Light | Position | Notes |
|---|---|---|
| Headlights | `(±0.62, 0.70, -1.92)` | front = player -Z, spot range 32 m |
| Taillights / brake | `(±0.60, 0.86, 1.98)` | rear = player +Z, red glass emission + brake spotlights |

NPC lights are registered in `night_mode/npc_car_lights.gd` as `HONDA_CIVIC`, detected by node name `CivicModel`.

| Light | Position | Notes |
|---|---|---|
| Headlights | `(±0.62, 0.70, 1.90)` | front = NPC +Z |
| Taillights | `(±0.60, 0.82, -1.95)` | rear = NPC -Z |
| Reverse light | `(0, 0.60, -1.98)` | rear center |

## Registry Changes

| File | Change |
|---|---|
| `settings/car_settings.gd` | `CARS` entry + `DISPLAY_STATS` |
| `career/career_state.gd` | price `420000` |
| `ui/car_selection.gd` | spec line `2006 · 2.0L · 197 HP · FWD · 1270 KG` |
| `traffic/traffic_manager.gd` | `npc_civic_scene`, preload, warmup, 2% spawn weight |
| `night_mode/npc_car_lights.gd` | model enum, detection, light positions |

Stats:
- accel `0.76`
- speed `0.78`
- handling `0.80`
- torque `760`
- max rpm `8000`
- final drive `4.76`
- gears `[3.27, 2.13, 1.52, 1.15, 0.92, 0.74]`

## Evidence

Screenshots:
- `screenshots/cars/honda_civic_si_2006_front.png` — day, front (grille/headlights, paint, grounding)
- `screenshots/cars/honda_civic_si_2006_rear.png` — day, rear
- `screenshots/cars/honda_civic_si_2006_night_front.png` — night, headlights + forward beam
- `screenshots/cars/honda_civic_si_2006_night_rear.png` — night, taillights glowing (brake applied)
- `screenshots/cars/honda_civic_si_2006_npc_colors.png` — 3 NPCs, distinct per-instance colours, grounded
- `screenshots/cars/honda_civic_si_2006_npc_night.png` — NPCs at night, taillights on
- `screenshots/cars/honda_civic_si_2006_npc_night_front.png` — NPCs at night from the front, headlights on
- `screenshots/cars/honda_civic_si_2006_npc_topdown.png` — top-down, light sources within body footprint

Validation run in this pass:

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/tmp_validate_honda_civic.gd
HONDA_CIVIC_VALIDATE_OK
```

The temporary validation script instantiated both scenes, waited for setup, and checked:
- player model wheels are reparented under all four GEVP wheel nodes
- NPC `MergedMesh` exists
- split NPC wheel meshes exist
- no Civic setup script errors remain

## Fixes Made While Resuming

- `car/honda_civic_si_setup.gd`: guarded `get_tree().current_scene` in `_process()` so showroom/headless contexts do not crash before a current scene exists.
- `traffic/npc_car.gd`: guarded `_connect_to_night_mode()` for the same null-current-scene case when instantiating NPC scenes in isolation.

## Live MCP runtime verification (full drive pass)

Played `res://main.tscn`, swapped the player car to the Civic via
`CarSpawner.replace_player_car` (after renaming the player node to `Car`), and verified
live:

| Check | Result |
|---|---|
| Player swap | model = `CivicModel`, stats applied (torque 760, rpm 8000) |
| Wheel rig (player) | all 4 GEVP wheel nodes received a reparented model-wheel container (L/R swap is from the 180° model rotation; nearest-node matching snaps each to the correct physical corner) |
| **Drive / orientation** | drove **87.1 m**, stayed **upright the whole time (up.y = 1.00)**, front-wheel spin Δ **812 rad** |
| Grounding | reset upright on road (road_y ≈ 116), up.y 1.00, sits seated, no float/sink |
| Headlights (night) | both lit on front lamp blocks, forward beam pool on asphalt — `..._night_front.png` |
| Taillights (night) | both glow red on rear lamp blocks, brighten under brake — `..._night_rear.png` |
| NPC colours | 3 instances → 3 distinct per-instance albedos: Rallye Red `(0.714,0.098,0.125)`, Alabaster Silver `(0.749,0.753,0.733)`, Galaxy Gray `(0.333,0.337,0.353)` |
| NPC grounding/wheels | all up.y 1.00, `MergedMesh` present, 4 `wheelmesh_*` each |
| NPC lights (night) | `NPCHeadlightL/R` + `NPCTaillightL/R` visible, reverse off |
| **Light-source boundary** | top-down + data: all 5 NPC light nodes report `inside_body=true` vs body footprint x±0.97 / z±2.23 (headlights x±0.62/z+1.90, taillights x±0.60/z−1.95, reverse z−1.98). The red ground pools are the omni taillights' projection, not out-of-bounds sources. |

> **One-off tumble (resolved):** on the very first swap the Civic inherited the previous
> moving player car's transform and a throttle-pinned test drove it over a curb → it
> flipped onto its roof (up.y −0.999). Resetting it upright, it drove 87 m staying
> upright. This was a test artifact, **not** a config fault (chassis/collision/wheels
> mirror the proven Focus ST template).

## Risks / Follow-up

- Manual MCP driving **was** rerun (see table above) — orientation, wheel spin, grounding,
  head/tail lights, and NPC colour variety confirmed live in `res://main.tscn`.
- Showroom tunnel preview not separately captured this pass (the car is registered in
  `CarSettings.CARS`, which the selection UI auto-discovers); capture if desired.
- If more Civic tuning is done, re-check front-wheel visual steer and brake-light delta
  while driving.
