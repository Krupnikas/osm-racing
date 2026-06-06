# Volga GAZ-3110 — verification checklist

Pipeline: `docs/CAR_INTEGRATION_PIPELINE.md` · `car_id = volga_gaz3110`
Status: PASS — live MCP drive (139 m upright, RWD) + night light shots + NPC data.

Legend: ✅ pass · ⚠️ partial · ❌ fail

## Player (GEVP)
| # | Check | Status | Evidence |
|---|---|---|---|
| 1 | Imports cleanly | ✅ | uid `cvly86acuewey`, 8,415 verts |
| 2 | Scale (~4.88 m) | ✅ | already real scale ×1.0084 |
| 3 | Orientation (front leads) | ✅ | native +Z, rotated 180°; drove 139 m, vel·fwd +8.70 |
| 4 | Real model wheels | ✅ | separate corner wheels grouped by CarWheelRig (stray emblem dropped) |
| 5 | Wheels spin | ✅ | LIVE: containers on all 4 GEVP nodes; rear spin Δ large |
| 6 | Front wheels steer | ✅ | rigged onto GEVP steering nodes |
| 7 | Grounded | ✅ | LIVE up.y 1.00; `volga_gaz3110_front.png` (slightly tall, period-correct) |
| 8 | Headlights on front blocks | ✅ | `volga_gaz3110_night_front.png` — front lamp lit + beam |
| 9 | Taillights on rear blocks | ✅ | `volga_gaz3110_night_rear.png` — Light3 glow (brake) |
| 10 | Brake brighten | ✅ | Light3 emission + brake spot raised at brake_input>0.1 |
| 11 | Recolor paint only | ✅ | targets `BodyColor`; White; chrome/dark/lamps untouched |
| 12 | Drivetrain (RWD) | ✅ | `front_torque_split = 0.0`; drove 139 m |

## NPC
| # | Check | Status | Evidence |
|---|---|---|---|
| N1 | Spawns as NPC | ✅ | `npc_volga_scene` + 4% weight (common) |
| N2 | Scale/orientation (+Z) | ✅ | no rotation |
| N3 | Wheels rotate | ✅ | 4 `wheelmesh_*` per instance |
| N4 | Grounded | ✅ | LIVE 3× up.y 1.00 |
| N5 | Headlights/taillights | ✅ | LIVE night: 4 lit lights each; `volga_gaz3110_npc_colors.png` |
| N6 | Colors vary per instance | ✅ | LIVE: Anthracite / Cyclone / Buran (per-instance `BodyColor` override) |

## Metadata
| # | Check | Status | Evidence |
|---|---|---|---|
| M1 | CARS + DISPLAY_STATS | ✅ | accel .45 / speed .50 / handling .50; torque 640 / RWD |
| M2 | Price | ✅ | 130 000 |
| M3 | Spec line | ✅ | `2000 · 2.3L · 150 HP · RWD · 1400 KG` |
| M4 | NPC weight | ✅ | 4 % common |
| M5 | Report written | ✅ | `volga_gaz3110_integration_report.md` |
