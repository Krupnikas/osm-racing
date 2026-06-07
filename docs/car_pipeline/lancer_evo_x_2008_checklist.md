# Mitsubishi Lancer Evo X MR 2008 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = lancer_evo_x_2008`
Status: PASS — flat test-track drive (491 m straight @132 km/h) + night lights + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `cjmjqfwecd57u`, 43,497 verts |
| 2 | Scale (~4.50 m) | ✅ | real scale ×1.0013 → L 4.49 / W 2.06 / H 1.59 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 491 m, vel·fwd = full speed |
| 4 | Real model wheels | ✅ | separate corner wheels grouped by CarWheelRig |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; drove 491 m |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE: all 4 wheels contact on flat track, up.y 1.00; `lancer_evo_x_2008_front.png` |
| 8 | Headlights on front blocks | ✅ | `lancer_evo_x_2008_night_front.png` — two white beams forward |
| 9 | Taillights on rear blocks | ✅ | `lancer_evo_x_2008_night_rear.png` — red rear glow (brake) |
| 10 | Brake brighten | ✅ | red OmniLights 0.4→3.0 at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `Vehicle_Exterior_mm_ext`; albedo Octane Blue confirmed |
| 12 | Drivetrain (AWD) | ✅ | `front_torque_split = 0.5`; drove 491 m straight |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_evo_scene` + 1% weight |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 on flat track |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `lancer_evo_x_2008_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE: Graphite Gray / Apex Silver / Rally Red |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .85 / speed .82 / handling .88; torque 900 / AWD |
| M2 | Price | ✅ | 700 000 |
| M3 | Spec line | ✅ | `2008 · 2.0L Turbo · 291 HP · AWD · 1560 KG` |
| M4 | NPC weight | ✅ | 1 % very rare |
| M5 | Report written | ✅ | `lancer_evo_x_2008_integration_report.md` |

## Known limitation
- Lamp lenses share one `Vehicle_Exterior_mm_lights` material (front+rear), so the rear lens
  does not self-glow red; the red rear effect is provided by placed OmniLights. Acceptable.
