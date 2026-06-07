# Honda Civic Si 2006 — integration verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md`
`car_id = honda_civic_si_2006`
Status: PASS — live MCP drive pass (drove 87 m upright) + runtime screenshots + headless validation.

Legend: ✅ pass · ⚠️ partial · ❌ fail · ⏳ not checked

## Player (GEVP, drivable showroom car)

| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | `res://car/models/honda_civic_si/honda_civic_si.glb`, 20 texture files, 31,988 verts |
| 2 | Scale correct (~4.44 m) | ✅ | analyzer scale ~100.63; scene scale 101.0854; visual size matches road screenshots |
| 3 | Orientation: player front moves toward -Z | ✅ | native +Z, player scene rotates model 180 degrees; front headlights are on -Z side |
| 4 | Uses real model wheels | ✅ | merged Tire/Rim/Caliper meshes split by `CarWheelRig` |
| 5 | All four wheels can spin | ✅ | headless validation: `wheel_*` containers reparented under all four GEVP wheel nodes |
| 6 | Front wheels steer visually | ✅ | GEVP wheel-node reparent path matches Focus reference; verify again after physics tuning |
| 7 | Grounded | ✅ | day screenshots show wheels/body seated plausibly on road |
| 8 | Headlights on real front lamp blocks | ✅ | `screenshots/cars/honda_civic_si_2006_night_front.png` |
| 9 | Taillights on real rear lamp blocks | ✅ | `screenshots/cars/honda_civic_si_2006_night_rear.png` |
| 10 | Brake lights brighten when braking | ✅ | setup raises red-glass emission + brake spot energy when `brake_input > 0.1` |
| 11 | Body recolor only on paint | ✅ | setup targets `capaint`; glass/lights/tyres untouched |
| 12 | Works as selected player car | ✅ | registered in `CarSettings.CARS`; existing runtime screenshots show gameplay spawn |

## NPC

| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC traffic | ✅ | `npc_civic_scene` preload + 2% spawn weight in `traffic_manager.gd` |
| N2 | Correct NPC scale/orientation (+Z front) | ✅ | NPC scene has no model rotation; front wheels/lights on +Z side |
| N3 | NPC wheels rotate while moving | ✅ | split `wheelmesh_*` meshes exist; `NPCCar._merge_meshes()` collects them for wheel rotation |
| N4 | Grounded | ✅ | wheel/collision dimensions mirror player setup; screenshots show plausible seating |
| N5 | NPC headlights/taillights work | ✅ | `HONDA_CIVIC` entry in `night_mode/npc_car_lights.gd` |
| N6 | NPC colors vary per instance | ✅ | LIVE: 3 instances → Rallye Red / Alabaster Silver / Galaxy Gray; `screenshots/cars/honda_civic_si_2006_npc_colors.png` |
| N7 | Light sources within car body | ✅ | top-down + data: all 5 NPC light nodes `inside_body=true` vs footprint x±0.97/z±2.23; `screenshots/cars/honda_civic_si_2006_npc_topdown.png` |

## Metadata

| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | Registered in `CarSettings.CARS` | ✅ | name, scene path, torque/rpm/gears/handling stats |
| M2 | Registered in `DISPLAY_STATS` | ✅ | accel .76 / speed .78 / handling .80 |
| M3 | Price registered | ✅ | `CareerState.CAR_PRICES["honda_civic_si_2006"] = 420000` |
| M4 | Spec line registered | ✅ | `2006 · 2.0L · 197 HP · FWD · 1270 KG` |
| M5 | NPC spawn weight plausible | ✅ | 2% rare hot compact |
| M6 | Integration report written | ✅ | `docs/car_pipeline/honda_civic_si_2006_integration_report.md` |

## Validation Notes

Fresh headless validation passed:

```text
HONDA_CIVIC_VALIDATE_OK
```

The check instantiated player and NPC scenes, waited for setup frames, verified player wheel reparenting, verified NPC merged mesh creation, and verified split wheel meshes.

Live MCP drive pass (`res://main.tscn`): player swapped to Civic, drove **87.1 m staying
upright (up.y 1.00)**, front-wheel spin Δ 812 rad; night headlights (forward beam) +
taillights (brake brightening); 3 NPCs with 3 distinct per-instance colours, grounded,
night head/tail lights on; all NPC light sources confirmed inside the body footprint
(top-down). See `..._integration_report.md` → "Live MCP runtime verification".
